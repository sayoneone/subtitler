import 'dart:math' as math;

import 'validation.dart';

/// Буквы и сочетания, которые есть в турецком и невозможны в узбекской
/// латинице.
const Set<String> kTurkishMarkers = {'ç', 'ğ', 'ı', 'ş', 'ö', 'ü'};

/// И наоборот: узбекская латиница пишет то, чего нет в турецком алфавите —
/// буквы q и x, апостроф в oʻ/gʻ и диграфы sh/ch вместо ş/ç.
const Set<String> kUzbekMarkers = {'q', 'x', 'ʻ', 'sh', 'ch'};

/// Насколько один вариант должен обойти другой, чтобы предлагать его выбор.
/// Ниже этого — данных не хватает, и решать должен человек.
const double kLanguageConfidenceGap = 0.25;

class LanguageCandidate {
  final String lang;
  final String text;
  final double score;
  const LanguageCandidate({
    required this.lang,
    required this.text,
    required this.score,
  });
}

class LanguageVerdict {
  /// Отсортированы по убыванию правдоподобия.
  final List<LanguageCandidate> candidates;

  /// Хватает ли данных, чтобы предлагать выбор. Если нет — оба варианта
  /// показываются равноправно, и язык выбирает человек.
  final bool confident;

  const LanguageVerdict({required this.candidates, required this.confident});

  LanguageCandidate get best => candidates.first;
  double get gap => candidates.length < 2
      ? 0
      : candidates[0].score - candidates[1].score;
}

double _markerRate(String lowered, Set<String> markers) {
  if (lowered.isEmpty) return 0;
  var hits = 0;
  for (final marker in markers) {
    var from = 0;
    while (true) {
      final at = lowered.indexOf(marker, from);
      if (at < 0) break;
      hits++;
      from = at + marker.length;
    }
  }
  return hits / lowered.length;
}

/// Оценивает, насколько текст похож на результат распознавания на [lang].
///
/// Смысл: правильная модель выдаёт связный текст со «своими» буквами,
/// а неправильная — фонетическую кальку без них и часто зацикливается,
/// повторяя одно слово (реальный случай — «***» восемь раз подряд).
double scoreLanguage(String text, String lang) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return -1;

  final lowered = trimmed.toLowerCase();
  final own = lang == 'tr-TR' ? kTurkishMarkers : kUzbekMarkers;
  final alien = lang == 'tr-TR' ? kUzbekMarkers : kTurkishMarkers;

  final words = trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  var score = 8.0 * _markerRate(lowered, own) -
      8.0 * _markerRate(lowered, alien) +
      0.02 * math.min(words, 30);
  if (hasRepeatLoop(trimmed)) score -= 0.5;
  return score;
}

/// Сравнивает распознавание одного и того же звука разными моделями.
LanguageVerdict judgeLanguage(Map<String, String> textByLang) {
  final candidates = textByLang.entries
      .map((e) => LanguageCandidate(
            lang: e.key,
            text: e.value,
            score: scoreLanguage(e.value, e.key),
          ))
      .toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  final verdict = LanguageVerdict(candidates: candidates, confident: false);
  return LanguageVerdict(
    candidates: candidates,
    confident: candidates.length >= 2 && verdict.gap >= kLanguageConfidenceGap,
  );
}
