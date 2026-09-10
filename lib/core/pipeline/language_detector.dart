import 'dart:math' as math;

import '../languages.dart';
import 'validation.dart';

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

  /// Хватает ли данных, чтобы предлагать выбор. Если нет — варианты
  /// показываются равноправно, и язык выбирает человек.
  final bool confident;

  const LanguageVerdict({required this.candidates, required this.confident});

  LanguageCandidate get best => candidates.first;
  double get gap =>
      candidates.length < 2 ? 0 : candidates[0].score - candidates[1].score;
}

double _markerRate(String lowered, Set<String> markers) {
  if (lowered.isEmpty || markers.isEmpty) return 0;
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
///
/// [against] — остальные проверяемые языки: их отличительные буквы
/// работают против варианта.
double scoreLanguage(
  String text,
  String lang, {
  Iterable<String> against = const [],
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return -1;

  final own = languageByCode(lang)?.markers ?? const <String>{};
  final alien = <String>{};
  for (final other in against) {
    if (other == lang) continue;
    alien.addAll(languageByCode(other)?.markers ?? const <String>{});
  }
  alien.removeAll(own);

  final lowered = trimmed.toLowerCase();
  final words = trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  var score = 8.0 * _markerRate(lowered, own) -
      8.0 * _markerRate(lowered, alien) +
      0.02 * math.min(words, 30);
  if (hasRepeatLoop(trimmed)) score -= 0.5;
  return score;
}

/// Сравнивает распознавание одного и того же звука разными моделями.
LanguageVerdict judgeLanguage(Map<String, String> textByLang) {
  final codes = textByLang.keys.toList();
  final candidates = textByLang.entries
      .map((e) => LanguageCandidate(
            lang: e.key,
            text: e.value,
            score: scoreLanguage(e.value, e.key, against: codes),
          ))
      .toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  final gap = candidates.length < 2
      ? 0.0
      : candidates[0].score - candidates[1].score;

  return LanguageVerdict(
    candidates: candidates,
    // Один кандидат — это не выбор, а данность: подтверждать нечего.
    confident: candidates.length >= 2 && gap >= kLanguageConfidenceGap,
  );
}
