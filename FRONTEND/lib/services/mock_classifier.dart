import '../core/constants.dart';
import '../models/models.dart';

/// Offline NLP classifier for auto-categorization and priority/sentiment analysis.
/// When USE_MOCK=false the same result shape comes from POST /api/complaints/classify.
class MockClassifier {
  // Baseline urgency of each category (1..3).
  static const _base = {1: 2, 2: 2, 3: 3, 4: 1, 5: 3, 6: 3, 7: 2, 8: 2, 9: 1, 10: 1};

  // ── Category keyword dictionaries (English + Filipino/Bisaya) ──────────
  static const _categoryKeywords = <int, List<String>>{
    1: [
      // Cebuano
      'dalan', 'kalsada', 'guba nga dalan', 'lubak', 'libaong', 'lungag', 'liki',
      'tulay', 'taytayan', 'nahugno', 'natumpag', 'semento', 'aspalto', 'ali sa dalan',
      'giuba nga building', 'giuba ga building', 'giuba', 'building', 'edipisyo', 'giniba',
      'demolisyon', 'demolition', 'konstruksyon', 'bungkag', 'naguba nga edipisyo', 'pagguba',
      // Tagalog
      'kalsada', 'daan', 'lubak', 'butas sa daan', 'bitak', 'sira ang kalsada', 'tulay',
      'gumuho', 'semento', 'aspalto', 'poste', 'manhole', 'nakaharang', 'ginibang building',
      // English
      'road', 'pothole', 'damaged road', 'broken street', 'cracked pavement', 'bridge',
      'asphalt', 'concrete', 'collapsed', 'repair road', 'sidewalk', 'manhole cover',
      'excavation', 'infrastructure', 'street light pole', 'demolished building', 'building demolition'
    ],
    2: [
      // Cebuano
      'suga sa dalan', 'walay suga', 'ngitngit', 'kuryente', 'brownout', 'blackout',
      'poste sa kuryente', 'natumba nga poste', 'alambre', 'putol nga wire', 'nagbitay nga kable',
      // Tagalog
      'ilaw sa kalsada', 'walang ilaw', 'madilim', 'kuryente', 'brownout', 'blackout',
      'poste ng kuryente', 'natumbang poste', 'nakabiting wire', 'putol na kawad',
      // English
      'streetlight', 'dark street', 'no street light', 'power outage', 'blackout',
      'brownout', 'electric post', 'fallen pole', 'exposed wire', 'dangling wire', 'transformer'
    ],
    3: [
      // Cebuano
      'baha', 'lunop', 'niawas ang kanal', 'barado nga kanal', 'clogged drainage',
      'tubig baha', 'sapa', 'suba', 'landslide', 'dahili sa yuta', 'evacuation', 'miawas ang sapa',
      // Tagalog
      'baha', 'umaapaw ang kanal', 'baradong drainage', 'baradong kanal', 'bumaha',
      'tubig baha', 'ilog', 'sapa', 'landslide', 'pagguho ng lupa', 'paglikas',
      // English
      'flood', 'flooding', 'flash flood', 'clogged drainage', 'blocked canal',
      'overflowing drain', 'storm drain', 'stagnant water', 'waterlogging', 'creek overflow', 'landslide'
    ],
    4: [
      // Cebuano
      'basura', 'hugaw', 'baho', 'wala gihakot nga basura', 'tambak nga basura',
      'dumpsite', 'paglabay ug basura', 'piggery nga baho', 'hugaw sa baboy', 'baho sa manokan',
      'laina sa hangin', 'lainas hangin', 'laina ug hangin', 'abog', 'hugaw nga hangin',
      'abog kaayo', 'polusyon', 'aso', 'baho nga aso', 'hangin nga baho', 'pwerte ka abog',
      // Tagalog
      'basura', 'marumi', 'mabaho', 'hindi kinokolekta ang basura', 'tambak na basura',
      'tapon ng basura', 'amoy piggery', 'amoy babuyan', 'amoy manukan', 'dumpsite', 'kalat',
      'maruming hangin', 'mabahong hangin', 'polusyon sa hangin', 'alikabok', 'maalikabok',
      // English
      'garbage', 'trash', 'waste', 'uncollected garbage', 'garbage pile', 'dumpsite',
      'foul odor', 'stinking', 'piggery smell', 'poultry smell', 'illegal dumping', 'litter',
      'air pollution', 'foul air', 'dust pollution', 'heavy dust', 'smoke', 'toxic air', 'bad air quality'
    ],
    5: [
      // Cebuano
      'sakit', 'hilanat', 'dengue', 'health center', 'tambalanan', 'tambal', 'doktor',
      'nars', 'bakuna', 'iro nga laag', 'napaakan ug iro', 'kagat sa iro', 'rabies',
      'kalibanga', 'pan-os nga pagkaon', 'hilo sa pagkaon',
      // Tagalog
      'sakit', 'lagnat', 'dengue', 'health center', 'ospital', 'gamot', 'doktor',
      'nars', 'bakuna', 'asong gala', 'nakagat ng aso', 'kagat ng aso', 'rabies',
      'pagtatae', 'food poisoning', 'sirang pagkain',
      // English
      'health', 'hospital', 'clinic', 'health center', 'medicine', 'dengue', 'fever',
      'disease', 'illness', 'rabies', 'dog bite', 'stray dog', 'food poisoning', 'contamination'
    ],
    6: [
      // Cebuano
      'kawat', 'kawatan', 'tulis', 'holdap', 'away', 'kagubot', 'sinumbagay', 'dunggab',
      'pusil', 'buto sa pusil', 'droga', 'shabu', 'hubog nga nanggubot', 'estambay', 'hulga',
      // Tagalog
      'magnanakaw', 'holdap', 'nakawan', 'away', 'kaguluhan', 'suntukan', 'saksakan',
      'baril', 'putok ng baril', 'droga', 'shabu', 'lasing na nagwawala', 'estambay', 'banta',
      // English
      'theft', 'robbery', 'burglar', 'fight', 'violence', 'stabbing', 'gunshot',
      'shooting', 'illegal drugs', 'public intoxication', 'drunkard disturbance', 'threat'
    ],
    7: [
      // Cebuano
      'trapiko', 'huot ang kalsada', 'aksidente sa motor', 'nabanggaan', 'disgrasya',
      'illegal parking', 'nagbabag sa dalan', 'tricycle nga paspas', 'counterflow',
      // Tagalog
      'trapik', 'traffic', 'aksidente sa motor', 'nabangga', 'disgrasya', 'illegal parking',
      'nakaharang sa daan', 'pasaway na driver', 'counterflow',
      // English
      'traffic', 'traffic congestion', 'vehicle accident', 'motorcycle crash', 'collision',
      'illegal parking', 'road obstruction', 'reckless driving'
    ],
    8: [
      // Cebuano
      'ayuda', 'tabang pinansyal', 'kabus', 'senior citizen', 'tiguwang', 'pwd',
      'bakol', 'solo parent', 'bata nga giabuso', 'giabandonar nga bata', '4ps', 'tabang sa lubong',
      // Tagalog
      'ayuda', 'tulong pinansyal', 'mahirap', 'senior citizen', 'matanda', 'pwd',
      'may kapansanan', 'solo parent', 'batang inabuso', '4ps', 'tulong sa libing',
      // English
      'financial assistance', 'ayuda', 'senior citizen', 'pwd', 'disability',
      'solo parent', 'child abuse', 'burial assistance', 'indigent assistance', 'social welfare'
    ],
    9: [
      // Cebuano
      'saba', 'pwerteng sabaha', 'videoke nga saba', 'karaoke sa gabii', 'saba sa silingan',
      'usig sa iro', 'disco sa karsada', 'kusog kaayong speaker',
      // Tagalog
      'ingay', 'sobrang ingay', 'videoke sa hatinggabi', 'karaoke na maingay', 'ingay ng kapitbahay',
      'tahol ng aso', 'napakalakas na speaker', 'videoke',
      // English
      'noise complaint', 'loud music', 'karaoke late at night', 'videoke disturbance',
      'barking dog', 'loud speaker', 'public nuisance'
    ],
    10: [
      // Cebuano
      'mayor', 'reklamo sa barangay', 'opisyal', 'kapitan', 'pangutana', 'sugyot',
      // Tagalog
      'tanggapan ng mayor', 'reklamo sa barangay', 'kapitan', 'opisyal', 'suhestiyon',
      // English
      'mayor office', 'barangay official', 'general inquiry', 'city hall feedback', 'other concern'
    ],
  };

  static const _critical = [
    'sunog', 'fire', 'baha', 'flood', 'baril', 'gun', 'patay', 'namatay', 'dead',
    'died', 'emergency', 'aksidente', 'accident', 'nasugatan', 'injured', 'collapse',
    'nahulog', 'electrocut', 'live wire', 'nakuryente', 'hostage', 'explosion',
    'sumabog', 'outbreak', 'dengue', 'nalunod', 'drowning', 'landslide',
  ];
  static const _high = [
    'delikado', 'dangerous', 'unsafe', 'danger', 'peligro', 'severe', 'grabe',
    'nag-agas', 'leaking', 'sira', 'guba', 'broken', 'nahugno', 'walay tubig',
    'no water', 'blackout', 'walay suga', 'holdap', 'robbery', 'nakawan', 'stolen',
    'violence', 'gibunalan', 'threat', 'gipanghadlok',
  ];
  static const _medium = [
    'week', 'semana', 'adlaw', 'days', 'buwan', 'month', 'damo', 'many', 'lubak',
    'pothole', 'baho', 'smell', 'garbage', 'basura', 'traffic', 'noise', 'ingay',
    'clogged', 'barado',
  ];
  static const _negative = [
    'reklamo', 'complain', 'kapoy', 'daot', 'bad', 'worst', 'terrible', 'kahadlok',
    'scared', 'angry', 'disappointed', 'wala', 'walay', 'problema', 'problem',
  ];
  static const _positive = ['salamat', 'thank', 'maayo', 'good', 'appreciate'];

  static List<String> _hits(String text, List<String> words) =>
      words.where((w) => RegExp('\\b${RegExp.escape(w)}').hasMatch(text)).toList();

  /// Auto-detect category from description text.
  /// Returns the category ID with the most keyword hits, or null if no match.
  static int? detectCategory(String description) {
    final text = description.toLowerCase();
    if (text.trim().length < 5) return null;

    int bestId = 10;
    int bestScore = 0;

    for (final entry in _categoryKeywords.entries) {
      int score = 0;
      for (final kw in entry.value) {
        if (text.contains(kw)) {
          score += kw.split(' ').length; // multi-word keywords score higher
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestId = entry.key;
      }
    }

    return bestScore > 0 ? bestId : null;
  }

  /// Get matched keywords from the description for a given category.
  static List<String> getMatchedKeywords(String description, int categoryId) {
    final text = description.toLowerCase();
    final keywords = _categoryKeywords[categoryId] ?? [];
    return keywords.where((kw) => text.contains(kw)).take(5).toList();
  }

  static Classification classify(int categoryId, String description) {
    final text = description.toLowerCase();
    final cat = categoryById(categoryId);
    var score = _base[categoryId] ?? 1;

    final crit = _hits(text, _critical);
    final high = _hits(text, _high);
    final med = _hits(text, _medium);
    final neg = _hits(text, _negative);
    final pos = _hits(text, _positive);

    if (crit.isNotEmpty) score += 5 + (crit.length - 1);
    score += (high.length * 2).clamp(0, 4).toInt();
    score += med.length.clamp(0, 2).toInt();

    final priority = score >= 8
        ? Priority.critical
        : score >= 5
            ? Priority.high
            : score >= 3
                ? Priority.medium
                : Priority.low;

    final negScore = crit.length + high.length + neg.length;
    final sentiment = negScore >= 1 && negScore >= pos.length
        ? 'negative'
        : pos.isNotEmpty
            ? 'positive'
            : 'neutral';

    final categoryOnly = description.trim().length < 20;
    final keywords = {...crit, ...high, ...med, ...getMatchedKeywords(description, categoryId)}.take(6).toList();
    final confidence = categoryOnly
        ? 0.55
        : (0.68 + 0.05 * (crit.length + high.length + med.length + keywords.length)).clamp(0.68, 0.95);

    // Multi-office collection:
    final allOfficeIds = <int>[cat.officeId];
    final coOfficeIds = <int>[];
    for (final entry in _categoryKeywords.entries) {
      if (entry.key == categoryId) continue;
      final hasHits = entry.value.any((kw) => text.contains(kw));
      if (hasHits) {
        final otherOid = categoryById(entry.key).officeId;
        if (!allOfficeIds.contains(otherOid)) {
          allOfficeIds.add(otherOid);
          coOfficeIds.add(otherOid);
        }
      }
    }
    final officeNames = allOfficeIds.map((id) => officeById(id).name).toList();

    return Classification(
      category: cat.name,
      categoryId: cat.id,
      sentiment: categoryOnly && negScore == 0 ? 'neutral' : sentiment,
      priority: priority,
      confidence: confidence.toDouble(),
      officeId: cat.officeId,
      coOfficeIds: coOfficeIds,
      officeNames: officeNames,
      keywords: keywords,
      categoryOnly: categoryOnly,
    );
  }
}
