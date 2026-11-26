"""
Hybrid Machine Learning + NLP Classifier for Cabadbaran CitizenSense.

Combines:
1. A TF-IDF (unigrams + bigrams) Multinomial Naive Bayes model trained at startup
   on the 2,030 Cabadbaran City 311 dataset records plus curated Cebuano/Bisaya,
   Tagalog, and English complaint samples.
2. A word-boundary regex NLP engine with negation-window handling and intensifier
   scoring for category, multi-office dispatch, priority, and sentiment.
"""

from __future__ import annotations

import csv
import math
import os
import re
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Tuple

OFFICE_NAMES: Dict[int, str] = {
    1: 'City Engineering Office',
    2: 'City Health Office',
    3: 'City Environment & Natural Resources Office (CENRO)',
    4: 'City Social Welfare & Development Office (CSWDO)',
    5: 'City Disaster Risk Reduction & Management Office (CDRRMO)',
    6: 'City Public Safety Office (PSO)',
    7: "City Mayor's Office",
}

# Category Name -> (category_id, default_office_id, multilingual_keywords)
NLP_CATEGORIES: Dict[str, Tuple[int, int, List[str]]] = {
    'Road & Infrastructure': (1, 1, [
        # Cebuano
        'dalan', 'kalsada', 'karsada', 'guba nga dalan', 'lubak', 'libaong', 'lungag', 'liki',
        'tulay', 'taytayan', 'nahugno', 'natumpag', 'semento', 'aspalto', 'ali sa dalan',
        'giuba nga building', 'giuba', 'building', 'edipisyo', 'giniba', 'demolisyon',
        'konstruksyon', 'bungkag', 'naguba nga edipisyo', 'pagguba', 'tubig sa tubo',
        'buslot nga tubo', 'guba nga tubo', 'walay tubig', 'tubig', 'water supply', 'water leak',
        # Tagalog
        'kalsada', 'daan', 'butas sa daan', 'bitak', 'sira ang kalsada', 'tulay',
        'gumuho', 'poste', 'manhole', 'nakaharang', 'ginibang building', 'sirang tubo',
        'walang tubig', 'tagas ng tubig',
        # English
        'road', 'pothole', 'damaged road', 'broken street', 'cracked pavement', 'bridge',
        'asphalt', 'concrete', 'collapsed', 'repair road', 'sidewalk', 'curb damage',
        'manhole cover', 'excavation', 'infrastructure', 'demolished building',
        'building demolition', 'dilapidated', 'construction complaint', 'building safety',
        'water leak', 'broken pipe', 'water supply', 'water quality', 'plumbing', 'leaking pipe',
        'waiting shed',
    ]),
    'Streetlights & Electricity': (2, 1, [
        # Cebuano
        'suga sa dalan', 'walay suga', 'ngitngit', 'kuryente', 'brownout', 'blackout',
        'poste sa kuryente', 'natumba nga poste', 'alambre', 'putol nga wire', 'nagbitay nga kable',
        'pundido nga suga',
        # Tagalog
        'ilaw sa kalsada', 'walang ilaw', 'madilim', 'kuryente', 'poste ng kuryente',
        'natumbang poste', 'nakabiting wire', 'putol na kawad',
        # English
        'streetlight', 'street light', 'dark street', 'no street light', 'power outage',
        'blackout', 'brownout', 'electric post', 'fallen pole', 'exposed wire',
        'dangling wire', 'transformer', 'electrical hazard', 'short circuit', 'sparking wire',
    ]),
    'Drainage & Flooding': (3, 5, [
        # Cebuano
        'baha', 'lunop', 'niawas ang kanal', 'barado nga kanal', 'barado ang kanal',
        'tubig baha', 'sapa', 'suba', 'landslide', 'dahili sa yuta', 'evacuation',
        'miawas ang sapa', 'kanal',
        # Tagalog
        'baha', 'umaapaw ang kanal', 'baradong drainage', 'baradong kanal', 'bumaha',
        'tubig baha', 'ilog', 'sapa', 'landslide', 'pagguho ng lupa', 'paglikas',
        # English
        'flood', 'flooding', 'flash flood', 'clogged drainage', 'blocked canal',
        'overflowing drain', 'storm drain', 'stagnant water', 'waterlogging',
        'creek overflow', 'landslide', 'drainage', 'canal',
    ]),
    'Garbage & Sanitation': (4, 3, [
        # Cebuano
        'basura', 'hugaw', 'baho', 'wala gihakot nga basura', 'tambak nga basura',
        'dumpsite', 'paglabay ug basura', 'piggery nga baho', 'hugaw sa baboy',
        'baho sa manokan', 'laina sa hangin', 'lainas hangin', 'laina ug hangin',
        'abog', 'hugaw nga hangin', 'abog kaayo', 'polusyon', 'aso', 'baho nga aso',
        'hangin nga baho', 'pwerte ka abog', 'kahoy', 'sanga sa kahoy',
        # Tagalog
        'basura', 'marumi', 'mabaho', 'hindi kinokolekta ang basura', 'tambak na basura',
        'tapon ng basura', 'amoy piggery', 'amoy babuyan', 'amoy manukan', 'kalat',
        'maruming hangin', 'mabahong hangin', 'polusyon sa hangin', 'alikabok', 'maalikabok',
        # English
        'garbage', 'trash', 'waste', 'uncollected garbage', 'missed garbage', 'garbage pile',
        'dumpsite', 'foul odor', 'stinking', 'piggery smell', 'poultry smell',
        'illegal dumping', 'litter', 'air pollution', 'foul air', 'dust pollution',
        'heavy dust', 'smoke', 'toxic air', 'bad air quality', 'open burning',
        'hazardous waste', 'chemical', 'overgrown branches', 'tree hazard', 'park maintenance',
    ]),
    'Health Concerns': (5, 2, [
        # Cebuano
        'sakit', 'hilanat', 'dengue', 'health center', 'tambalanan', 'tambal', 'doktor',
        'nars', 'bakuna', 'iro nga laag', 'napaakan ug iro', 'kagat sa iro', 'rabies',
        'kalibanga', 'pan-os nga pagkaon', 'hilo sa pagkaon', 'ilaga', 'ok-ok', 'lamok',
        # Tagalog
        'sakit', 'lagnat', 'dengue', 'health center', 'ospital', 'gamot', 'doktor',
        'nars', 'bakuna', 'asong gala', 'nakagat ng aso', 'kagat ng aso', 'rabies',
        'pagtatae', 'food poisoning', 'sirang pagkain', 'daga', 'lamok',
        # English
        'health', 'hospital', 'clinic', 'health center', 'medicine', 'dengue', 'fever',
        'disease', 'illness', 'rabies', 'dog bite', 'stray dog', 'stray dogs',
        'food poisoning', 'food safety', 'contamination', 'unsanitary', 'pest', 'rodent',
        'mosquito', 'sanitation', 'public health',
    ]),
    'Peace, Order & Public Safety': (6, 6, [
        # Cebuano
        'kawat', 'kawatan', 'tulis', 'holdap', 'away', 'kagubot', 'sinumbagay', 'dunggab',
        'pusil', 'buto sa pusil', 'droga', 'shabu', 'hubog nga nanggubot', 'estambay', 'hulga',
        # Tagalog
        'magnanakaw', 'holdap', 'nakawan', 'away', 'kaguluhan', 'suntukan', 'saksakan',
        'baril', 'putok ng baril', 'droga', 'shabu', 'lasing na nagwawala', 'estambay', 'banta',
        # English
        'theft', 'robbery', 'burglar', 'fight', 'violence', 'stabbing', 'gunshot',
        'shooting', 'illegal drugs', 'public intoxication', 'drunkard disturbance', 'threat',
        'peace and order', 'vandalism', 'graffiti', 'public drinking', 'lost and found',
    ]),
    'Traffic & Transport': (7, 6, [
        # Cebuano
        'trapiko', 'huot ang kalsada', 'aksidente sa motor', 'nabanggaan', 'disgrasya',
        'illegal parking', 'nagbabag sa dalan', 'tricycle nga paspas', 'counterflow',
        'gi-park', 'nagbabag sa gate',
        # Tagalog
        'trapik', 'traffic', 'aksidente sa motor', 'nabangga', 'disgrasya', 'illegal parking',
        'nakaharang sa daan', 'pasaway na driver', 'counterflow',
        # English
        'traffic', 'traffic congestion', 'vehicle accident', 'motorcycle crash', 'collision',
        'illegal parking', 'blocked driveway', 'abandoned vehicle', 'road obstruction',
        'reckless driving', 'traffic sign', 'signal problem', 'public transport', 'tricycle',
    ]),
    'Social Welfare & Assistance': (8, 4, [
        # Cebuano
        'ayuda', 'tabang pinansyal', 'kabus', 'senior citizen', 'tiguwang', 'pwd',
        'bakol', 'solo parent', 'bata nga giabuso', 'giabandonar nga bata', '4ps',
        'tabang sa lubong', 'makililimos', 'street dwellers',
        # Tagalog
        'ayuda', 'tulong pinansyal', 'mahirap', 'senior citizen', 'matanda', 'pwd',
        'may kapansanan', 'solo parent', 'batang inabuso', '4ps', 'tulong sa libing',
        # English
        'financial assistance', 'ayuda', 'senior citizen', 'pwd', 'disability',
        'solo parent', 'child abuse', 'burial assistance', 'indigent assistance',
        'social welfare', 'street dwellers', 'mendicant', 'day care',
    ]),
    'Noise & Public Nuisance': (9, 6, [
        # Cebuano
        'saba', 'pwerteng sabaha', 'videoke nga saba', 'karaoke sa gabii', 'saba sa silingan',
        'usig sa iro', 'disco sa karsada', 'kusog kaayong speaker', 'tambutso',
        # Tagalog
        'ingay', 'sobrang ingay', 'videoke sa hatinggabi', 'karaoke na maingay',
        'ingay ng kapitbahay', 'tahol ng aso', 'napakalakas na speaker', 'videoke',
        # English
        'noise', 'noise complaint', 'loud music', 'karaoke', 'videoke', 'barking dog',
        'loud speaker', 'public nuisance', 'loud muffler', 'machinery noise',
    ]),
    'Other Concerns': (10, 7, [
        # Cebuano
        'mayor', 'reklamo sa barangay', 'opisyal', 'kapitan', 'pangutana', 'sugyot',
        # Tagalog
        'tanggapan ng mayor', 'reklamo sa barangay', 'kapitan', 'opisyal', 'suhestiyon',
        # English
        'mayor office', 'barangay official', 'general inquiry', 'city hall feedback',
        'other concern', 'illegal vending', 'consumer complaint', 'business complaint',
    ]),
}

_CAT_ID_TO_NAME: Dict[int, str] = {cid: name for name, (cid, _, _) in NLP_CATEGORIES.items()}

# Mapping from CSV complaint_type / agency_code to category name
_CSV_TYPE_TO_CAT: Dict[str, str] = {
    'Water Supply Problem': 'Road & Infrastructure',
    'Water Leak / Broken Pipe': 'Road & Infrastructure',
    'Water Quality': 'Road & Infrastructure',
    'Leaking Pipe / Plumbing': 'Road & Infrastructure',
    'Clogged Drainage / Canal': 'Drainage & Flooding',
    'Streetlight Problem': 'Streetlights & Electricity',
    'Electrical Hazard': 'Streetlights & Electricity',
    'Road Damage': 'Road & Infrastructure',
    'Sidewalk / Curb Damage': 'Road & Infrastructure',
    'Waiting Shed Damage': 'Road & Infrastructure',
    'Construction Complaint': 'Road & Infrastructure',
    'Dilapidated House / Structure': 'Road & Infrastructure',
    'Building Safety Hazard': 'Road & Infrastructure',
    'Illegal Construction / Building Use': 'Road & Infrastructure',
    'Noise - Videoke / Loud Music': 'Noise & Public Nuisance',
    'Noise - Street / Public Area': 'Noise & Public Nuisance',
    'Noise - Business Establishment': 'Noise & Public Nuisance',
    'Noise - Loud Muffler / Vehicle': 'Noise & Public Nuisance',
    'Noise - Construction / Machinery': 'Noise & Public Nuisance',
    'Illegal Parking': 'Traffic & Transport',
    'Blocked Driveway': 'Traffic & Transport',
    'Abandoned Vehicle': 'Traffic & Transport',
    'Traffic Sign / Signal Problem': 'Traffic & Transport',
    'Traffic Violation / Congestion': 'Traffic & Transport',
    'Public Transport Complaint': 'Traffic & Transport',
    'Missed Garbage Collection': 'Garbage & Sanitation',
    'Garbage / Illegal Dumping': 'Garbage & Sanitation',
    'Tree Hazard / Overgrown Branches': 'Garbage & Sanitation',
    'Park / Plaza Maintenance': 'Garbage & Sanitation',
    'Hazardous Waste / Chemical': 'Garbage & Sanitation',
    'Tree Planting Request': 'Garbage & Sanitation',
    'Air Pollution / Open Burning': 'Garbage & Sanitation',
    'Street Dwellers / Mendicant Assistance': 'Social Welfare & Assistance',
    'Day Care Center Concern': 'Social Welfare & Assistance',
    'Unsanitary Conditions': 'Health Concerns',
    'Pest / Rodent / Stray Animals': 'Health Concerns',
    'Food Safety / Sanitation': 'Health Concerns',
    'Animal Cruelty / Stray Dogs': 'Health Concerns',
    'Public Health Concern': 'Health Concerns',
    'Lost and Found Property': 'Peace, Order & Public Safety',
    'Non-Emergency Peace and Order': 'Peace, Order & Public Safety',
    'Illegal Drugs Activity': 'Peace, Order & Public Safety',
    'Vandalism / Graffiti': 'Peace, Order & Public Safety',
    'Public Drinking / Disturbance': 'Peace, Order & Public Safety',
    'Consumer / Business Complaint': 'Other Concerns',
    'Illegal Vending': 'Other Concerns',
}

_NEGATION_WORDS = {
    'no', 'not', 'never', 'without', 'none', "don't", 'dont', "isn't", 'isnt',
    'walay', 'wala', 'dili', 'di', 'walang', 'hindi', 'diay',
}

_INTENSIFIERS = {
    'very', 'extremely', 'severely', 'urgently', 'immediately', 'critical',
    'grabe', 'kaayo', 'pwerte', 'sobra', 'sobrang', 'napaka', 'agad', 'karon',
    'dayon', 'delikado', 'emergency', 'dangerous', 'hazardous',
}

_PRIORITY_RULES: List[Tuple[str, int, List[str]]] = [
    ('critical', 10, [
        'life-threatening', 'trapped', 'collapsed', 'nahugno', 'gumuho', 'severe injury',
        'fire spreading', 'patay', 'dead', 'dying', 'emergency', 'rescue', 'nag-collapse',
        'electrocution', 'nakuryente', 'landslide', 'flash flood', 'shooting', 'stabbing',
        'dunggab', 'pusil', 'saksakan',
    ]),
    ('high', 6, [
        'flood', 'flooding', 'baha', 'lunop', 'exposed wire', 'dangling wire',
        'nagbitay nga kable', 'no electricity', 'walay kuryente', 'accident', 'aksidente',
        'disgrasya', 'injury', 'dangerous', 'delikado', 'overflow', 'miawas', 'dengue',
        'outbreak', 'robbery', 'kawatan', 'holdap', 'fire', 'sunog', 'drug', 'shabu',
        'rabies', 'dog bite', 'kagat sa iro', 'napaakan', 'hazardous waste', 'chemical',
        'building safety', 'electrical hazard', 'no water', 'walay tubig', 'walang tubig',
    ]),
    ('medium', 3, [
        'broken', 'damaged', 'guba', 'sira', 'not working', 'garbage', 'basura', 'noise',
        'saba', 'ingay', 'videoke', 'karaoke', 'leak', 'leaking', 'pothole', 'lubak',
        'butas', 'clogged', 'barado', 'stink', 'baho', 'mabaho', 'dark', 'ngitngit',
        'madilim', 'unsafe', 'reckless', 'uncollected', 'stagnant', 'illegal parking',
        'blocked driveway', 'abandoned vehicle', 'water supply', 'air pollution', 'smoke',
    ]),
]

_NEGATIVE_WORDS = {
    'bad', 'terrible', 'worst', 'angry', 'disgusted', 'frustrated', 'disappointed',
    'horrible', 'awful', 'hate', 'galit', 'bwiset', 'incompetent', 'useless',
    'negligent', 'dangerous', 'unsafe', 'unacceptable', 'complaint', 'reklamo',
    'baho', 'hugaw', 'guba', 'sira', 'mabaho', 'marumi', 'saba', 'ingay', 'grabe',
    'baha', 'flood', 'broken', 'leak', 'clogged', 'uncollected', 'delayed', 'delikado',
    'laina', 'walang', 'walay', 'problema', 'problem', 'hazard', 'urgent',
}

_POSITIVE_WORDS = {
    'thank', 'thanks', 'salamat', 'good', 'great', 'appreciate', 'maayo', 'maganda',
    'helpful', 'resolved', 'fixed', 'clean', 'limpyo', 'malinis', 'safe', 'kind',
    'commend', 'grateful', 'request', 'tree planting', 'inquiry',
}


def _tokenize(text: str) -> List[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _extract_ngrams(tokens: List[str]) -> List[str]:
    grams = list(tokens)
    for i in range(len(tokens) - 1):
        grams.append(f"{tokens[i]}_{tokens[i + 1]}")
    return grams


def _has_negation_before(tokens: List[str], match_start_idx: int, window: int = 3) -> bool:
    start = max(0, match_start_idx - window)
    return any(t in _NEGATION_WORDS for t in tokens[start:match_start_idx])


class HybridComplaintClassifier:
    """
    TF-IDF + Multinomial Naive Bayes classifier trained on Cabadbaran 311 data
    plus multilingual seed samples, combined with rule-based word-boundary NLP.
    """

    def __init__(self) -> None:
        self.classes: List[str] = list(NLP_CATEGORIES.keys())
        self.class_log_prior: Dict[str, float] = {}
        self.feature_log_prob: Dict[str, Dict[str, float]] = {}
        self.default_log_prob: Dict[str, float] = {}
        self.idf: Dict[str, float] = {}
        self.vocab: set[str] = set()
        self.trained_docs = 0

        # Precompile word-boundary regexes for fast, accurate phrase matching
        self._cat_patterns: Dict[str, List[Tuple[str, re.Pattern, int]]] = {}
        for cat_name, (_, _, kws) in NLP_CATEGORIES.items():
            pats = []
            for kw in kws:
                pat = re.compile(r'(?<!\w)' + re.escape(kw.lower()) + r'(?!\w)')
                pats.append((kw, pat, max(1, len(kw.split()))))
            self._cat_patterns[cat_name] = pats

        self._priority_patterns: List[Tuple[str, int, List[Tuple[str, re.Pattern]]]] = []
        for level, weight, kws in _PRIORITY_RULES:
            pats = [(kw, re.compile(r'(?<!\w)' + re.escape(kw.lower()) + r'(?!\w)')) for kw in kws]
            self._priority_patterns.append((level, weight, pats))

        self._train()

    def _gather_training_corpus(self) -> List[Tuple[str, str]]:
        corpus: List[Tuple[str, str]] = []

        # 1. Seed multilingual examples per category (ensures strong Cebuano/Tagalog coverage)
        for cat_name, (_, _, kws) in NLP_CATEGORIES.items():
            # Group keywords into synthetic sentences + individual phrases
            for kw in kws:
                corpus.append((kw, cat_name))
            for i in range(0, len(kws), 4):
                corpus.append((' '.join(kws[i:i + 4]), cat_name))

        # 2. Load real Cabadbaran City 2,030 complaints dataset if present
        csv_candidates = [
            os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cabadbaran_complaints.csv'),
            os.path.join(os.getcwd(), 'BACKEND', 'cabadbaran_complaints.csv'),
            os.path.join(os.getcwd(), 'cabadbaran_complaints.csv'),
        ]
        for csv_path in csv_candidates:
            if os.path.exists(csv_path):
                try:
                    with open(csv_path, 'r', encoding='utf-8', errors='replace') as f:
                        reader = csv.DictReader(f)
                        for row in reader:
                            ctype = (row.get('complaint_type') or '').strip()
                            desc = (row.get('descriptor') or '').strip()
                            loc = (row.get('location_type') or '').strip()
                            cat_name = _CSV_TYPE_TO_CAT.get(ctype)
                            if cat_name:
                                text = f"{ctype} {desc} {loc}".strip()
                                if text:
                                    corpus.append((text, cat_name))
                    break
                except Exception as e:
                    print(f"[ML] Warning reading training CSV {csv_path}: {e}")
        return corpus

    def _train(self) -> None:
        corpus = self._gather_training_corpus()
        self.trained_docs = len(corpus)
        if not corpus:
            return

        doc_freq: Counter[str] = Counter()
        class_doc_counts: Counter[str] = Counter()
        tokenized_docs: List[Tuple[List[str], str]] = []

        for text, label in corpus:
            grams = _extract_ngrams(_tokenize(text))
            if not grams:
                continue
            tokenized_docs.append((grams, label))
            class_doc_counts[label] += 1
            for g in set(grams):
                doc_freq[g] += 1

        total_docs = len(tokenized_docs)
        self.vocab = set(doc_freq.keys())
        vocab_size = max(1, len(self.vocab))

        # Smoothed IDF
        for term, df in doc_freq.items():
            self.idf[term] = math.log((1.0 + total_docs) / (1.0 + df)) + 1.0

        # Accumulate TF-IDF weights per class for Multinomial Naive Bayes
        class_term_tfidf: Dict[str, Dict[str, float]] = defaultdict(lambda: defaultdict(float))
        class_total_tfidf: Dict[str, float] = defaultdict(float)

        for grams, label in tokenized_docs:
            tf = Counter(grams)
            doc_len = len(grams)
            for term, count in tf.items():
                weight = (count / doc_len) * self.idf[term]
                class_term_tfidf[label][term] += weight
                class_total_tfidf[label] += weight

        alpha = 0.5  # Laplace smoothing
        for cls in self.classes:
            cls_docs = class_doc_counts.get(cls, 1)
            self.class_log_prior[cls] = math.log(cls_docs / total_docs)
            denom = class_total_tfidf[cls] + alpha * vocab_size
            self.default_log_prob[cls] = math.log(alpha / denom)
            probs: Dict[str, float] = {}
            for term, w in class_term_tfidf[cls].items():
                probs[term] = math.log((w + alpha) / denom)
            self.feature_log_prob[cls] = probs

    def _ml_predict_proba(self, text: str) -> Dict[str, float]:
        grams = _extract_ngrams(_tokenize(text))
        if not grams or not self.class_log_prior:
            uniform = 1.0 / len(self.classes)
            return {c: uniform for c in self.classes}

        tf = Counter(grams)
        log_scores: Dict[str, float] = {}
        for cls in self.classes:
            score = self.class_log_prior[cls]
            cls_probs = self.feature_log_prob[cls]
            default_lp = self.default_log_prob[cls]
            for term, count in tf.items():
                if term in self.vocab:
                    tfidf_w = count * self.idf.get(term, 1.0)
                    score += tfidf_w * cls_probs.get(term, default_lp)
            log_scores[cls] = score

        # Softmax normalization
        max_lp = max(log_scores.values())
        exp_scores = {c: math.exp(max(-50.0, lp - max_lp)) for c, lp in log_scores.items()}
        total_exp = sum(exp_scores.values()) or 1.0
        return {c: val / total_exp for c, val in exp_scores.items()}

    def classify(self, description: str, category_id: Optional[int] = None) -> dict:
        text = description.lower().strip()
        tokens = _tokenize(text)

        # 1. ML posterior probabilities (TF-IDF + Multinomial Naive Bayes)
        ml_probs = self._ml_predict_proba(text)

        # 2. Word-boundary NLP phrase matching with negation awareness
        nlp_cat_scores: Dict[str, float] = {}
        office_scores: Dict[int, float] = {}
        cat_hits: Dict[str, List[str]] = defaultdict(list)

        for cat_name, pats in self._cat_patterns.items():
            cid, oid, _ = NLP_CATEGORIES[cat_name]
            score = 0.0
            for kw, pat, n_words in pats:
                m = pat.search(text)
                if m:
                    # Check negation before the match
                    prefix_tokens = _tokenize(text[:m.start()])
                    if _has_negation_before(prefix_tokens, len(prefix_tokens)):
                        continue
                    w = 1.0 + (n_words - 1) * 0.8
                    score += w
                    cat_hits[cat_name].append(kw)
            if score > 0:
                nlp_cat_scores[cat_name] = score
                office_scores[oid] = office_scores.get(oid, 0.0) + score

        # 3. Hybrid Ensemble: combine normalized NLP scores + ML probabilities
        max_nlp = max(nlp_cat_scores.values()) if nlp_cat_scores else 0.0
        combined_scores: Dict[str, float] = {}
        for cat_name in self.classes:
            ml_p = ml_probs.get(cat_name, 0.0)
            nlp_norm = (nlp_cat_scores.get(cat_name, 0.0) / max_nlp) if max_nlp > 0 else 0.0
            # Weight NLP phrase match + ML probability
            combined_scores[cat_name] = (0.55 * ml_p) + (0.45 * nlp_norm)

        best_cat = max(combined_scores, key=lambda c: combined_scores[c])
        if max_nlp == 0 and ml_probs.get(best_cat, 0.0) < 0.18:
            best_cat = 'Other Concerns'

        detected_cat_id, detected_office_id, _ = NLP_CATEGORIES[best_cat]
        matched_keywords = cat_hits.get(best_cat, [])

        # Respect explicit user category override while keeping detected_category_id
        final_cat_id = category_id if category_id else detected_cat_id
        final_cat_name = best_cat
        if category_id and category_id in _CAT_ID_TO_NAME:
            final_cat_name = _CAT_ID_TO_NAME[category_id]
            detected_office_id = NLP_CATEGORIES[final_cat_name][1]

        # 4. Multi-Office Dispatch Detection
        for cat_name, prob in ml_probs.items():
            if prob >= 0.22:
                oid = NLP_CATEGORIES[cat_name][1]
                office_scores[oid] = office_scores.get(oid, 0.0) + prob * 2.0

        sorted_office_ids = sorted(office_scores.keys(), key=lambda oid: office_scores[oid], reverse=True)
        if not sorted_office_ids:
            sorted_office_ids = [detected_office_id]

        primary_office_id = detected_office_id
        all_office_ids = [primary_office_id]
        for oid in sorted_office_ids:
            if oid not in all_office_ids and office_scores.get(oid, 0.0) >= 1.2:
                all_office_ids.append(oid)
        co_office_ids = [oid for oid in all_office_ids if oid != primary_office_id]
        office_names = [OFFICE_NAMES.get(oid, f"Office {oid}") for oid in all_office_ids]

        # 5. Priority Detection (with negation & intensifier boost)
        priority_score = 0
        priority = 'low'
        intensifier_hits = sum(1 for t in tokens if t in _INTENSIFIERS)

        for level, weight, pats in self._priority_patterns:
            for kw, pat in pats:
                m = pat.search(text)
                if m:
                    prefix_tokens = _tokenize(text[:m.start()])
                    if _has_negation_before(prefix_tokens, len(prefix_tokens)):
                        continue
                    effective_w = weight + (2 if intensifier_hits > 0 else 0)
                    if effective_w > priority_score:
                        priority_score = effective_w
                        priority = level

        if priority_score >= 10:
            priority = 'critical'
        elif priority_score >= 6:
            priority = 'high'
        elif priority_score >= 3:
            priority = 'medium'
        elif len(tokens) >= 6 and best_cat != 'Other Concerns':
            priority = 'medium'

        # 6. Sentiment Analysis (negation-aware + intensifier-weighted)
        neg_score = 0.0
        pos_score = 0.0
        for idx, tok in enumerate(tokens):
            negated = _has_negation_before(tokens, idx, window=2)
            boost = 1.5 if (idx > 0 and tokens[idx - 1] in _INTENSIFIERS) else 1.0
            if tok in _NEGATIVE_WORDS:
                if negated:
                    pos_score += 0.5
                else:
                    neg_score += boost
            elif tok in _POSITIVE_WORDS:
                if negated:
                    neg_score += 0.8
                else:
                    pos_score += boost

        if neg_score > pos_score:
            sentiment = 'negative'
        elif pos_score > neg_score and priority in ('low', 'medium'):
            sentiment = 'positive'
        else:
            sentiment = 'neutral'

        if priority in ('high', 'critical'):
            sentiment = 'negative'

        # 7. Calibrated Confidence Score
        ml_top_prob = ml_probs.get(best_cat, 0.3)
        kw_hits = len(matched_keywords)
        if len(tokens) < 3:
            confidence = 0.35
        else:
            base_conf = 0.45 * ml_top_prob + 0.35 * min(1.0, kw_hits / 3.0) + 0.20
            confidence = max(0.38, min(0.96, base_conf))

        if category_id and category_id == detected_cat_id:
            confidence = min(0.98, confidence + 0.12)

        category_only = len(text) < 10 and category_id is not None

        return {
            'category': final_cat_name,
            'category_id': final_cat_id,
            'detected_category_id': detected_cat_id,
            'sentiment': sentiment,
            'priority': priority,
            'confidence': round(confidence, 2),
            'office_id': primary_office_id,
            'co_office_ids': co_office_ids,
            'all_office_ids': all_office_ids,
            'office_names': office_names,
            'keywords': matched_keywords[:6],
            'category_only': category_only,
            'ml_probability': round(ml_top_prob, 2),
        }


# Singleton classifier trained once on module import
classifier = HybridComplaintClassifier()
