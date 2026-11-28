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
        # Cebuano / Bisaya
        'dalan', 'kalsada', 'karsada', 'guba nga dalan', 'lubak', 'libaong', 'lungag', 'liki',
        'tulay', 'taytayan', 'nahugno', 'natumpag', 'semento', 'aspalto', 'ali sa dalan',
        'giuba nga building', 'giuba', 'building', 'edipisyo', 'giniba', 'demolisyon',
        'konstruksyon', 'bungkag', 'naguba nga edipisyo', 'pagguba', 'tubig sa tubo',
        'buslot nga tubo', 'guba nga tubo', 'walay tubig', 'tubig', 'walay agas', 'agas',
        'hinay ang agas', 'putol ang tubig', 'nagas', 'nagbuslot', 'lapok sa dalan',
        'lapok', 'dalan nga guba', 'karsada nga lubak', 'abli nga manhole', 'walay tabon',
        'waiting shed', 'bangko sa shed', 'bangketa', 'sidewalk',
        # Tagalog
        'kalsada', 'daan', 'butas sa daan', 'bitak', 'sira ang kalsada', 'tulay',
        'gumuho', 'poste', 'manhole', 'nakaharang', 'ginibang building', 'sirang tubo',
        'walang tubig', 'tagas ng tubig', 'walang tulo', 'mahina ang tubig', 'putol ang tubig',
        'maputik na daan', 'lubak-lubak', 'sirang bangketa', 'sirang tulay', 'bubong ng shed',
        # English
        'road', 'pothole', 'damaged road', 'broken street', 'cracked pavement', 'bridge',
        'asphalt', 'concrete', 'collapsed', 'repair road', 'sidewalk', 'curb damage',
        'manhole cover', 'excavation', 'infrastructure', 'demolished building',
        'building demolition', 'dilapidated', 'construction complaint', 'building safety',
        'water leak', 'broken pipe', 'water supply', 'water quality', 'plumbing', 'leaking pipe',
        'waiting shed', 'no water', 'low water pressure', 'muddy road', 'road repair',
    ]),
    'Streetlights & Electricity': (2, 1, [
        # Cebuano / Bisaya
        'suga sa dalan', 'walay suga', 'ngitngit', 'ngitngit kaayo', 'kuryente', 'brownout', 'blackout',
        'poste sa kuryente', 'natumba nga poste', 'alambre', 'putol nga wire', 'nagbitay nga kable',
        'pundido nga suga', 'pundido', 'walay kuryente', 'nagkidlap-kidlap', 'nag-spark',
        'kuryente nga wire', 'delikado nga wire', 'nahulog nga wire', 'kable sa kuryente',
        # Tagalog
        'ilaw sa kalsada', 'walang ilaw', 'madilim', 'sobrang dilim', 'kuryente', 'poste ng kuryente',
        'natumbang poste', 'nakabiting wire', 'putol na kawad', 'pundi ang ilaw', 'walang kuryente',
        'nag-spark na wire', 'patay-sindi ang ilaw', 'nakalaylay na kable',
        # English
        'streetlight', 'street light', 'dark street', 'no street light', 'power outage',
        'blackout', 'brownout', 'electric post', 'fallen pole', 'exposed wire',
        'dangling wire', 'transformer', 'electrical hazard', 'short circuit', 'sparking wire',
        'broken light', 'flickering light', 'no electricity', 'live wire', 'power line',
    ]),
    'Drainage & Flooding': (3, 5, [
        # Cebuano / Bisaya
        'baha', 'lunop', 'niawas ang kanal', 'barado nga kanal', 'barado ang kanal',
        'tubig baha', 'sapa', 'suba', 'landslide', 'dahili sa yuta', 'evacuation',
        'miawas ang sapa', 'kanal', 'nagbaha', 'baha kaayo', 'puno ang kanal',
        'walay agasanan', 'drainage', 'nibaha', 'tubig sa karsada', 'baha sa balay',
        'nahulog nga yuta', 'nagdahili', 'baha sa barangay',
        # Tagalog
        'baha', 'umaapaw ang kanal', 'baradong drainage', 'baradong kanal', 'bumaha',
        'tubig baha', 'ilog', 'sapa', 'landslide', 'pagguho ng lupa', 'paglikas',
        'binaha', 'mataas ang tubig', 'walang daluyan ng tubig', 'apaw na ilog',
        'nagbabaha', 'baha sa kalsada', 'tubig na hindi umaalis',
        # English
        'flood', 'flooding', 'flash flood', 'clogged drainage', 'blocked canal',
        'overflowing drain', 'storm drain', 'stagnant water', 'waterlogging',
        'creek overflow', 'landslide', 'drainage', 'canal', 'soil erosion', 'mudslide',
        'rising water', 'flooded street', 'blocked culvert',
    ]),
    'Garbage & Sanitation': (4, 3, [
        # Cebuano / Bisaya
        'basura', 'hugaw', 'baho', 'bahoa', 'baho kaayo', 'wala gihakot nga basura', 'tambak nga basura',
        'dumpsite', 'paglabay ug basura', 'piggery nga baho', 'hugaw sa baboy',
        'baho sa manokan', 'laina sa hangin', 'lainas hangin', 'laina ug hangin',
        'abog', 'hugaw nga hangin', 'abog kaayo', 'polusyon', 'aso', 'baho nga aso',
        'hangin nga baho', 'pwerte ka abog', 'kahoy', 'sanga sa kahoy', 'nagkatag nga basura',
        'nagdaob', 'daob', 'aso sa daob', 'walay truck sa basura', 'wala kolektaha',
        'matumba nga kahoy', 'taas nga sagbot', 'kasagbotan',
        # Tagalog
        'basura', 'marumi', 'mabaho', 'sobrang baho', 'hindi kinokolekta ang basura', 'tambak na basura',
        'tapon ng basura', 'amoy piggery', 'amoy babuyan', 'amoy manukan', 'kalat',
        'maruming hangin', 'mabahong hangin', 'polusyon sa hangin', 'alikabok', 'maalikabok',
        'nagsusunog ng basura', 'usok', 'nakakalat na basura', 'putol ng puno', 'matandang puno',
        # English
        'garbage', 'trash', 'waste', 'uncollected garbage', 'missed garbage', 'garbage pile',
        'dumpsite', 'foul odor', 'stinking', 'piggery smell', 'poultry smell',
        'illegal dumping', 'litter', 'air pollution', 'foul air', 'dust pollution',
        'heavy dust', 'smoke', 'toxic air', 'bad air quality', 'open burning',
        'hazardous waste', 'chemical', 'overgrown branches', 'tree hazard', 'park maintenance',
        'burning trash', 'rotting waste', 'bad smell', 'fallen tree',
    ]),
    'Health Concerns': (5, 2, [
        # Cebuano / Bisaya
        'sakit', 'hilanat', 'dengue', 'health center', 'tambalanan', 'tambal', 'doktor',
        'nars', 'bakuna', 'iro nga laag', 'napaakan ug iro', 'kagat sa iro', 'rabies',
        'kalibanga', 'pan-os nga pagkaon', 'hilo sa pagkaon', 'ilaga', 'ok-ok', 'lamok',
        'daghang lamok', 'nanglabay ug hugaw', 'patay nga hayop', 'baho nga patay',
        'suka-kalibanga', 'impeksyon', 'walay tambal', 'klinika', 'ambulansya',
        # Tagalog
        'sakit', 'lagnat', 'dengue', 'health center', 'ospital', 'gamot', 'doktor',
        'nars', 'bakuna', 'asong gala', 'nakagat ng aso', 'kagat ng aso', 'rabies',
        'pagtatae', 'food poisoning', 'sirang pagkain', 'daga', 'lamok', 'ipis',
        'maraming lamok', 'patay na hayop', 'nagsusuka', 'impeksyon', 'walang gamot',
        # English
        'health', 'hospital', 'clinic', 'health center', 'medicine', 'dengue', 'fever',
        'disease', 'illness', 'rabies', 'dog bite', 'stray dog', 'stray dogs',
        'food poisoning', 'food safety', 'contamination', 'unsanitary', 'pest', 'rodent',
        'mosquito', 'sanitation', 'public health', 'dead animal', 'diarrhea', 'outbreak',
    ]),
    'Peace, Order & Public Safety': (6, 6, [
        # Cebuano / Bisaya
        'kawat', 'kawatan', 'tulis', 'holdap', 'away', 'kagubot', 'sinumbagay', 'dunggab',
        'pusil', 'buto sa pusil', 'droga', 'shabu', 'hubog nga nanggubot', 'estambay', 'hulga',
        'nag-away', 'naghubog', 'nanggubot', 'kawat sa balay', 'gi-snatch', 'snatcher',
        'guba nga gate', 'vandalism', 'nagsugal', 'sugal', 'curfew', 'bata nga laag',
        # Tagalog
        'magnanakaw', 'holdap', 'nakawan', 'away', 'kaguluhan', 'suntukan', 'saksakan',
        'baril', 'putok ng baril', 'droga', 'shabu', 'lasing na nagwawala', 'estambay', 'banta',
        'nag-aaway', 'nambubugbog', 'snatcher', 'pasugalan', 'curfew', 'tanod',
        # English
        'theft', 'robbery', 'burglar', 'fight', 'violence', 'stabbing', 'gunshot',
        'shooting', 'illegal drugs', 'public intoxication', 'drunkard disturbance', 'threat',
        'peace and order', 'vandalism', 'graffiti', 'public drinking', 'lost and found',
        'harassment', 'brawl', 'crime', 'snatching', 'trespassing', 'suspicious person',
    ]),
    'Traffic & Transport': (7, 6, [
        # Cebuano / Bisaya
        'trapiko', 'trapik', 'huot ang kalsada', 'aksidente sa motor', 'nabanggaan', 'disgrasya',
        'illegal parking', 'nagbabag sa dalan', 'tricycle nga paspas', 'counterflow',
        'gi-park', 'nagbabag sa gate', 'bangga', 'paspas magpadagan', 'walay traffic light',
        'nag-parking sa dalan', 'habal-habal', 'sikad', 'jeepney', 'overloading',
        # Tagalog
        'trapik', 'traffic', 'aksidente sa motor', 'nabangga', 'disgrasya', 'illegal parking',
        'nakaharang sa daan', 'pasaway na driver', 'counterflow', 'mabilis magpatakbo',
        'nakaparada sa daan', 'banggaan', 'walang traffic light', 'sirang traffic light',
        # English
        'traffic', 'traffic congestion', 'vehicle accident', 'motorcycle crash', 'collision',
        'illegal parking', 'blocked driveway', 'abandoned vehicle', 'road obstruction',
        'reckless driving', 'traffic sign', 'signal problem', 'public transport', 'tricycle',
        'speeding', 'double parking', 'pedestrian lane', 'crosswalk',
    ]),
    'Social Welfare & Assistance': (8, 4, [
        # Cebuano / Bisaya
        'ayuda', 'tabang pinansyal', 'kabus', 'senior citizen', 'tiguwang', 'pwd',
        'bakol', 'solo parent', 'bata nga giabuso', 'giabandonar nga bata', '4ps',
        'tabang sa lubong', 'makililimos', 'street dwellers', 'walay balay', 'tabang sa sakit',
        'medikal nga tabang', 'burial assistance', 'pensyon', 'social pension',
        # Tagalog
        'ayuda', 'tulong pinansyal', 'mahirap', 'senior citizen', 'matanda', 'pwd',
        'may kapansanan', 'solo parent', 'batang inabuso', '4ps', 'tulong sa libing',
        'namamalimos', 'walang tirahan', 'tulong medikal', 'pensyon', 'daycare',
        # English
        'financial assistance', 'ayuda', 'senior citizen', 'pwd', 'disability',
        'solo parent', 'child abuse', 'burial assistance', 'indigent assistance',
        'social welfare', 'street dwellers', 'mendicant', 'day care', 'medical assistance',
        'homeless', 'orphan', 'elderly care', 'relief goods',
    ]),
    'Noise & Public Nuisance': (9, 6, [
        # Cebuano / Bisaya
        'saba', 'saba kaayo', 'pwerteng sabaha', 'videoke nga saba', 'karaoke sa gabii', 'saba sa silingan',
        'usig sa iro', 'disco sa karsada', 'kusog kaayong speaker', 'tambutso',
        'saba ang motor', 'open pipe', 'saba sa tungang gabii', 'nag-videoke', 'sing-along',
        'kusog nga tugtog', 'saba nga construction', 'saba nga manok', 'tuktugaok',
        # Tagalog
        'ingay', 'sobrang ingay', 'maingay', 'videoke sa hatinggabi', 'karaoke na maingay',
        'ingay ng kapitbahay', 'tahol ng aso', 'napakalakas na speaker', 'videoke',
        'maingay na tambutso', 'malakas na tugtog', 'maingay na motor', 'maingay na construction',
        # English
        'noise', 'noise complaint', 'loud music', 'karaoke', 'videoke', 'barking dog',
        'loud speaker', 'public nuisance', 'loud muffler', 'machinery noise',
        'noisy neighbor', 'midnight party', 'loud exhaust', 'disturbance',
    ]),
    'Other Concerns': (10, 7, [
        # Cebuano / Bisaya
        'mayor', 'reklamo sa barangay', 'opisyal', 'kapitan', 'pangutana', 'sugyot',
        'tindero sa dalan', 'illegal nga tindahan', 'serbisyo sa city hall', 'permiso',
        # Tagalog
        'tanggapan ng mayor', 'reklamo sa barangay', 'kapitan', 'opisyal', 'suhestiyon',
        'illegal vendor', 'serbisyo publiko', 'reklamo sa tindahan', 'business permit',
        # English
        'mayor office', 'barangay official', 'general inquiry', 'city hall feedback',
        'other concern', 'illegal vending', 'consumer complaint', 'business complaint',
        'permit', 'public service feedback',
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

# Only explicit positive-inverting negators should flip positive words to negative
# (Cebuano/Tagalog 'walay'/'dili'/'hindi' before a problem word is still negative, not positive!)
_SENTIMENT_NEGATORS = {
    'no', 'not', 'never', "don't", 'dont', "isn't", 'isnt', 'dili', 'di', 'hindi', 'wala',
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
    'ayaw', 'dili', 'hindi', 'wala', 'ngitngit', 'madilim', 'lubak', 'butas',
    'barado', 'kawat', 'kawatan', 'away', 'sakit', 'dengue', 'rabies', 'trapik',
    'traffic', 'aksidente', 'disgrasya', 'brownout', 'blackout', 'pundido', 'pundi',
    'smelly', 'stinking', 'dirty', 'damaged', 'cracked', 'overflowing', 'stagnant',
    'noisy', 'loud', 'reckless', 'harassment', 'threat', 'fail', 'failed', 'error',
    'stuck', 'slow', 'lag', 'lagging', 'bulok', 'walang', 'kulang', 'lisod', 'kapoy',
}

_NEGATIVE_PHRASES = [
    # Cebuano / Bisaya 2-word & sentence phrases
    'ayaw nya', 'ayaw niya', 'ayaw mag', 'dili ma', 'dili lagi', 'dili mo', 'dili gana',
    'dili ko', 'walay tubig', 'walay kuryente', 'walay suga', 'walay agas', 'walay aksyon',
    'walay klaro', 'walay tabon', 'guba na', 'naguba na', 'baho kaayo', 'hugaw kaayo',
    'saba kaayo', 'ngitngit kaayo', 'baha kaayo', 'barado ang kanal', 'nag try ko',
    'pero ayaw', 'wala gi kolekta', 'wala gihakot', 'laina sa hangin', 'pwerte ka',
    # Tagalog 2-word & sentence phrases
    'hindi gumagana', 'hindi ma', 'hindi maayos', 'ayaw mag', 'ayaw gumana',
    'walang tubig', 'walang ilaw', 'walang kuryente', 'walang aksyon', 'sira na',
    'nasira na', 'sobrang baho', 'sobrang ingay', 'sobrang dilim', 'baradong kanal',
    'hindi kinokolekta', 'napaka baho', 'napaka ingay',
    # English 2-word & sentence phrases
    'not working', 'does not work', 'did not work', 'cannot upload', 'cant upload',
    'can not', 'failed to', 'no water', 'no electricity', 'no streetlight', 'no action',
    'broken pipe', 'water leak', 'clogged drainage', 'foul odor', 'bad smell',
    'too noisy', 'very dark', 'very dirty', 'please fix', 'need help', 'huge pothole',
]

_POSITIVE_PHRASES = [
    'thank you', 'thanks a lot', 'good job', 'well done', 'great service',
    'salamat kaayo', 'daghang salamat', 'maraming salamat', 'maayo kaayo',
    'magandang serbisyo', 'naayo na', 'naayos na', 'fixed already', 'resolved already',
]

_APP_OFFTOPIC_PHRASES = [
    'change picture', 'chnage picture', 'change the picture', 'chnage ang picture',
    'change ang picture', 'upload picture', 'mag upload', 'ayaw mag upload',
    'dili ma change', 'dili ma chnage', 'dili lagi ma chnage', 'hindi ma upload',
    'profile photo', 'profile picture', 'avatar', 'cannot upload photo',
    'app is slow', 'app bug', 'login problem', 'forgot password', 'how to use',
]

_POSITIVE_WORDS = {
    'thank', 'thanks', 'salamat', 'good', 'great', 'appreciate', 'maayo', 'maganda',
    'helpful', 'resolved', 'fixed', 'clean', 'limpyo', 'malinis', 'safe', 'kind',
    'commend', 'grateful', 'request', 'tree planting', 'inquiry',
}

# ─── Joke / Spam / Nonsense Detection ─────────────────────────────────────────
_JOKE_PHRASES: List[str] = [
    # ── English jokes / spam / test / nonsense ──────────────────────────────
    'haha', 'hahaha', 'hahahaha', 'hahahahaha', 'ha ha ha',
    'lol', 'lmao', 'lmfao', 'rofl', 'roflmao', 'xd', 'xdd',
    'just kidding', 'jk', 'joke only', 'joking', 'not serious',
    'this is a test', 'testing only', 'just testing', 'test only', 'im testing',
    'im just testing', 'sample only', 'example only', 'try only',
    'asdf', 'qwerty', 'asdfgh', 'zxcvbn', 'qwertyuiop', 'fjdskl', 'sdfjkl',
    'aaa', 'bbb', 'ccc', 'ddd', 'eee', 'zzz', 'xxx',
    'abc', 'abcd', 'abcde', 'abcdef', '123', '1234', '12345', '123456',
    'aaaaa', 'bbbbb', 'ccccc', 'xxxxx', 'zzzzz',
    'blah blah', 'blah', 'blah blah blah', 'lorem ipsum',
    'nothing', 'none', 'nada', 'nil', 'n/a',
    'idk', 'i dont know', 'i don\'t know', 'dunno', 'no idea',
    'whatever', 'whatevs', 'nevermind', 'never mind', 'nvm',
    'no comment', 'no complaint', 'no problem', 'no issue',
    'for fun', 'for lols', 'for laughs', 'just because',
    'prank', 'troll', 'trolling', 'trolled',
    'spam', 'spamming', 'fake', 'fake complaint', 'fake news',
    'yolo', 'swag', 'skibidi', 'rizz', 'sus', 'sussy', 'bruh', 'bruhh',
    'deez nuts', 'ligma', 'sigma', 'gyatt', 'fanum tax', 'ohio',
    'cap', 'no cap', 'sheesh', 'bussin', 'fr fr', 'ong', 'slay',
    'stupid', 'idiot', 'dumb', 'moron', 'fool',
    'shit', 'fuck', 'fuck you', 'bitch', 'asshole', 'bastard', 'dick',
    'wtf', 'wth', 'omg', 'omfg', 'stfu', 'gtfo',
    'boring', 'bored', 'meh',
    'lolol', 'lololol', 'kek', 'kekw', 'pepega',
    'click here', 'free money', 'you won', 'congratulations',
    'subscribe', 'follow me', 'check this out',

    # ── Tagalog jokes / spam / slang / profanity ────────────────────────────
    'joke lang', 'joke ko lang', 'nagbibiro lang', 'nagbibiro lang ako',
    'biro lang', 'biro ko lang', 'biruan lang', 'biruan lang to',
    'pakitang gilas', 'pakitang tao',
    'charot', 'charot lang', 'charing', 'char lang', 'chos', 'chos lang',
    'eme', 'eme lang', 'eme eme', 'emeng eme',
    'chika lang', 'tsika lang', 'tsismis lang',
    'walang kwenta', 'wala kwenta', 'walang silbi', 'walang sense',
    'trip lang', 'tripping', 'trip trip lang', 'nag-trip lang',
    'wala lang', 'wala lang to', 'walang laman',
    'bored lang', 'bored lang ako', 'nababaliw na ko',
    'para lang', 'pang test lang', 'practice lang',
    'sample lang', 'try lang', 'test lang', 'testing lang',
    'bobo', 'bobo mo', 'tanga', 'tanga ka', 'tanga mo',
    'gago', 'gago ka', 'gago mo', 'gaga', 'gaga ka',
    'ulol', 'ulol ka', 'olol',
    'putang ina', 'putang ina mo', 'puta', 'tang ina', 'tangina',
    'tarantado', 'gunggong', 'engot', 'inutil', 'siraulo',
    'pakyu', 'pak u', 'leche', 'lintik', 'punyeta', 'hudas',
    'animal ka', 'hayop ka',
    'petmalu', 'lodi', 'werpa',
    'skl', 'share ko lang', 'fyi lang',
    'hehe', 'hihi', 'huhu',
    'weh di nga',

    # ── Bisaya / Cebuano jokes / spam / slang / profanity ───────────────────
    'joke ra', 'joke ra ni', 'joke ra man', 'nag-joke ra', 'nagjoke ra',
    'biro ra', 'biro ra ni', 'biro ra man', 'nagbiro ra',
    'katawa', 'kataw-anan', 'kataw anan', 'makatawa', 'tawa tawa',
    'kadyot lang', 'kadyot ra', 'way pulos', 'way gamit', 'way kwenta',
    'way lami', 'way kapuslanan',
    'test ra', 'test ra ni', 'testing ra', 'try ra', 'try ra ni',
    'sample ra', 'sample ra ni', 'practice ra',
    'wala ra', 'wala ra ni', 'wala ray labot',
    'trip ra', 'trip ra ni', 'nag-trip ra',
    'bored ra', 'bored ra ko',
    'buang', 'buang ka', 'buang jud', 'buang gyud', 'buanga',
    'bugo', 'bugo ka', 'bugo jud', 'bugo gyud', 'bugoa',
    'yawa', 'yawa ka', 'yawaa', 'yawi', 'yawai',
    'atay', 'ataya', 'giatay', 'giataya',
    'istupido', 'istupida', 'stupido', 'stupida',
    'lingin', 'lingina', 'amaw', 'amawa',
    'iring ka', 'iro ka',
    'pakyas', 'pakyasa', 'bogo', 'bogoa', 'hangol',
    'charot lang gyud', 'chos ra', 'eme ra', 'eme ra ni',
    'ambot lang', 'ambot nimo', 'pasagdi na',
]

def _is_joke_or_spam(text: str, tokens: List[str]) -> Tuple[bool, List[str], str]:
    """Detect joke, spam, nonsense, or test submissions.
    Returns (is_joke: bool, captured_words: List[str], reason: str).
    """
    lower = text.lower().strip()
    captured: List[str] = []

    # 1. Too short to be a real complaint (< 3 real words)
    alpha_tokens = [t for t in tokens if len(t) > 1 and t.isalpha()]
    if len(alpha_tokens) < 2 and len(lower) < 10:
        return True, [lower], 'Too short to be a real complaint.'

    # 2. Check for known joke/spam phrases — collect ALL matches
    for phrase in _JOKE_PHRASES:
        pat = re.compile(r'(?<!\w)' + re.escape(phrase) + r'(?!\w)')
        if pat.search(lower):
            captured.append(phrase)

    if captured:
        words_str = ', '.join(f'"{w}"' for w in captured[:5])
        return True, captured[:5], f'The word/phrase {words_str} you typed belongs to the Joke / Spam category.'

    # 3. Excessive repeated characters (e.g., "aaaaaaa", "hahahahahaha")
    rep_match = re.search(r'(.)\1{4,}', lower)
    if rep_match:
        captured_char = rep_match.group(0)
        return True, [captured_char], f'Excessive repeated characters: "{captured_char}".'

    # 4. Excessive repeated words (e.g., "test test test test")
    if len(tokens) >= 3:
        word_counts = Counter(tokens)
        most_common_word, most_common_count = word_counts.most_common(1)[0]
        if most_common_count >= 3 and most_common_count / len(tokens) > 0.6:
            return True, [most_common_word], f'Repetitive text: "{most_common_word}" repeated {most_common_count} times.'

    # 5. All numbers / no meaningful alpha content
    alpha_chars = sum(1 for c in lower if c.isalpha())
    if len(lower) >= 3 and alpha_chars < len(lower) * 0.3:
        return True, [lower[:20]], 'Text contains mostly numbers/symbols, not a valid complaint.'

    # 6. Text is entirely profanity with no complaint context
    profanity = {'bobo', 'gago', 'gaga', 'tanga', 'ulol', 'olol', 'putang', 'ina',
                 'puta', 'tangina', 'tarantado', 'gunggong', 'engot', 'inutil',
                 'siraulo', 'pakyu', 'leche', 'lintik', 'punyeta', 'hudas',
                 'buang', 'bugo', 'bogo', 'yawa', 'atay', 'giatay', 'istupido',
                 'istupida', 'lingin', 'lingina', 'amaw', 'amawa', 'pakyas',
                 'shit', 'fuck', 'damn', 'ass', 'bitch', 'stupid', 'idiot',
                 'moron', 'dumb', 'bastard', 'dick', 'asshole'}
    complaint_context = set()
    for cat_name, pats in _CAT_PATTERNS_FLAT:
        for kw, pat, _ in pats:
            if pat.search(lower):
                complaint_context.add(cat_name)
    profanity_tokens = [t for t in tokens if t in profanity]
    if len(profanity_tokens) >= 2 and not complaint_context and len(alpha_tokens) <= 5:
        return True, profanity_tokens[:5], f'Contains profanity without a real complaint: {", ".join(profanity_tokens[:5])}.'

    # 7. App/technical/off-topic messages (not a city/community complaint)
    if not complaint_context:
        offtopic_hits = [p for p in _APP_OFFTOPIC_PHRASES if p in lower]
        if offtopic_hits:
            return (
                True,
                offtopic_hits[:3],
                f'This looks like an app/upload or off-topic message ({", ".join(offtopic_hits[:2])}) rather than a city/community complaint.',
            )

    return False, [], ''

# Flat reference for profanity-with-no-context check (populated after class init)
_CAT_PATTERNS_FLAT: List[Tuple[str, List[Tuple[str, re.Pattern, int]]]] = []


def _tokenize(text: str) -> List[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _extract_ngrams(tokens: List[str]) -> List[str]:
    grams = list(tokens)
    for i in range(len(tokens) - 1):
        grams.append(f"{tokens[i]}_{tokens[i + 1]}")
    for i in range(len(tokens) - 2):
        grams.append(f"{tokens[i]}_{tokens[i + 1]}_{tokens[i + 2]}")
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

        # 1. Seed multilingual examples & full-sentence samples per category
        _SENTENCE_SEEDS: Dict[str, List[str]] = {
            'Road & Infrastructure': [
                'There is a big pothole on the main road causing traffic and flat tires',
                'The water pipe is leaking on the street and there is no water supply in our barangay',
                'Guba kaayo ang dalan diri daghan ug lubak ug lapok kung mag ulan',
                'Walay agas ang tubig sa among barangay sukad pa gahapon kay buslot ang tubo',
                'Sira na ang kalsada at butas butas ang daan delikado sa mga motorista',
                'Walang tulo ang tubig sa gripo dahil sa sirang tubo sa kanto',
            ],
            'Streetlights & Electricity': [
                'The streetlight has been broken for a week and the street is very dark at night',
                'A power pole fell and exposed live electrical wires are sparking near houses',
                'Walay suga ang poste sa dalan ngitngit kaayo delikado mag lakaw sa gabii',
                'Nag spark ang kable sa kuryente ug brownout sa among purok',
                'Pundi ang ilaw sa poste at madilim ang kalsada baka may madisgrasya',
                'Nakabiting wire ng kuryente malapit sa eskwelahan delikado sa mga bata',
            ],
            'Drainage & Flooding': [
                'The drainage canal is clogged with trash causing severe flooding on our street',
                'Heavy rain caused creek overflow and flash flood inside our neighborhood',
                'Barado ang kanal mao nga nibaha dayon ang karsada ug nisulod sa balay',
                'Niawas ang sapa ug delikado sa landslide diri sa among barangay',
                'Baradong drainage kaya mabilis bumaha tuwing umuulan ng malakas',
                'Umaapaw ang kanal at mataas na ang tubig baha sa kalsada',
            ],
            'Garbage & Sanitation': [
                'Garbage has not been collected for days and the pile smells terrible',
                'Someone is burning plastic trash creating thick foul smoke and air pollution',
                'Wala gihakot ang basura ug baho kaayo ang tambak sa kanto',
                'Nagdaob ug basura ang silingan baho kaayo ang aso ug abog sa hangin',
                'Hindi kinokolekta ang basura kaya tambak na at sobrang baho sa paligid',
                'Nagsusunog ng basura at maruming hangin ang pumapasok sa mga bahay',
            ],
            'Health Concerns': [
                'There are many mosquitoes and stagnant water causing dengue cases in the area',
                'Stray dogs bit a child and we need anti rabies vaccine at the health center',
                'Daghan kaayo ug lamok ug naay nagkasakit ug dengue sa among barangay',
                'Naay iro nga laag nga nakapaak ug bata kinahanglan ug bakuna sa health center',
                'Maraming lamok at asong gala na nangangagat walang gamot sa health center',
                'May food poisoning at maruming tubig na nagdulot ng pagtatae',
            ],
            'Peace, Order & Public Safety': [
                'There is a robbery and drunk people fighting in front of our house',
                'Suspected illegal drugs activity and snatching happening near the plaza',
                'Naay naghubog ug nanggubot sa karsada delikado sa mga lumalabay',
                'Naay kawatan nga nisulod sa balay ug naghulga sa mga residente',
                'May nag aaway na lasing at magnanakaw sa barangay kailangan ng tanod',
                'May holdap at kaguluhan sa kalye tuwing gabi',
            ],
            'Traffic & Transport': [
                'Vehicles are illegally parked blocking the driveway and causing traffic congestion',
                'A motorcycle accident happened because of reckless speeding at the intersection',
                'Huot kaayo ang trapiko kay naay nag illegal parking ug nagbabag sa dalan',
                'Naay aksidente sa motor kay paspas kaayo magpadagan ang driver',
                'Nakaparada sa daan ang mga sasakyan kaya sobrang trapik sa umaga',
                'May nabangga na tricycle dahil sa sirang traffic light',
            ],
            'Social Welfare & Assistance': [
                'Senior citizen and PWD residents are asking about financial assistance and social pension',
                'Abandoned children and street dwellers need shelter and medical assistance from CSWDO',
                'Mga senior citizen ug pwd nangayo ug tabang pinansyal o ayuda',
                'Naay bata nga giabandonar ug walay balay nagkinahanglan ug tabang',
                'Humingi ng tulong pinansyal at burial assistance ang pamilyang mahirap',
                'Senior citizen at solo parent nagtatanong tungkol sa ayuda',
            ],
            'Noise & Public Nuisance': [
                'Neighbors are playing loud videoke and karaoke past midnight every night',
                'Modified motorcycle open pipe muffler is making extreme noise at night',
                'Saba kaayo ang videoke sa silingan hangtod tungang gabii dili mi katulog',
                'Kusog kaayo ang tambutso sa motor ug saba ang speaker sa karsada',
                'Sobrang ingay ng karaoke ng kapitbahay kahit hatinggabi na',
                'Maingay na tambutso ng motor at tahol ng aso buong gabi',
            ],
            'Other Concerns': [
                'General inquiry for the city mayor office regarding business permit and barangay official',
                'Illegal vending on the sidewalk without permit near the public market',
                'Naay pangutana ug sugyot para sa barangay kapitan ug mayor office',
                'Illegal nga tindahan nagbabag sa agianan sa merkado',
                'Suhestiyon sa serbisyo publiko at reklamo sa walang permit na tindahan',
            ],
        }
        for cat_name, sents in _SENTENCE_SEEDS.items():
            for s in sents:
                corpus.append((s, cat_name))
                corpus.append((s, cat_name))  # double weight for full-sentence multilingual seeds
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

        # 8. Joke / Spam / Nonsense Detection (run before final priority/sentiment calibration)
        is_joke, joke_words, joke_reason = _is_joke_or_spam(text, tokens)

        if priority_score >= 10:
            priority = 'critical'
        elif priority_score >= 6:
            priority = 'high'
        elif priority_score >= 3:
            priority = 'medium'
        elif len(tokens) >= 6 and best_cat != 'Other Concerns' and not is_joke and len(matched_keywords) >= 1:
            priority = 'medium'

        if is_joke:
            priority = 'low'

        # 6. Sentiment Analysis (multi-word phrases + negation-aware + intensifier-weighted)
        neg_score = 0.0
        pos_score = 0.0
        for phrase in _NEGATIVE_PHRASES:
            if phrase in text:
                neg_score += 2.0
        for phrase in _POSITIVE_PHRASES:
            if phrase in text:
                pos_score += 2.0

        for idx, tok in enumerate(tokens):
            prev_tokens = tokens[max(0, idx - 2):idx]
            negated = any(t in _SENTIMENT_NEGATORS for t in prev_tokens)
            boost = 1.5 if (idx > 0 and tokens[idx - 1] in _INTENSIFIERS) else 1.0
            if tok in _NEGATIVE_WORDS:
                # Only flip if a positive-meaning negation doesn't apply; complaints with 'walay/dili/hindi' stay negative
                neg_score += boost
            elif tok in _POSITIVE_WORDS:
                if negated:
                    neg_score += 1.2
                else:
                    pos_score += boost

        # Any real civic complaint with matched problem keywords is negative unless explicitly thankful/positive
        if neg_score == 0 and pos_score == 0 and matched_keywords and best_cat != 'Other Concerns':
            neg_score = 1.0

        if neg_score > pos_score:
            sentiment = 'negative'
        elif pos_score > neg_score and priority in ('low', 'medium') and not is_joke:
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
            'is_joke': is_joke,
            'joke_reason': joke_reason,
            'joke_words': joke_words,
        }


# Singleton classifier trained once on module import
classifier = HybridComplaintClassifier()

# Populate flat pattern reference for profanity-with-no-context check
_CAT_PATTERNS_FLAT.clear()
_CAT_PATTERNS_FLAT.extend(classifier._cat_patterns.items())
