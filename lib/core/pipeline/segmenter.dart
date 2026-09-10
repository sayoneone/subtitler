import '../models.dart';

/// Максимальная длина сегмента (лимит API — 30 с, но короткие реплики
/// распознаются заметно точнее).
const double kMaxSegment = 8.0;

/// Зазор, который ещё можно «проглотить» внутри одного сегмента.
const double kMaxGap = 1.0;

/// Сколько тишины прихватываем с каждой стороны, чтобы не срезать звуки.
const double kPad = 0.12;

/// Шаг принудительной нарезки, когда пауз нет.
const double kForcedSplit = 7.2;

/// Огрызок короче этого приклеивается к предыдущему сегменту.
const double kMinFragment = 1.2;

double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Строит сегменты для распознавания из интервалов речи.
///
/// [fineSpeech] — интервалы речи, найденные на более чувствительном пороге;
/// используются только чтобы разрезать слишком длинные куски по микропаузам.
List<TimeRange> buildSegments({
  required List<TimeRange> speech,
  required double duration,
  List<TimeRange> fineSpeech = const [],
}) {
  if (speech.isEmpty) return const [];
  final split = _splitLong(speech, fineSpeech);
  final merged = _merge(split);
  return _pad(merged, duration);
}

/// Нарезка вслепую: когда пауз не нашлось ни на одном пороге.
List<TimeRange> forcedSegments(double duration) {
  final result = <TimeRange>[];
  var cursor = 0.0;
  while (cursor < duration) {
    final end = (cursor + kForcedSplit) < duration ? cursor + kForcedSplit : duration;
    result.add(TimeRange(_round2(cursor), _round2(end)));
    cursor = end;
  }
  return result;
}

List<TimeRange> _splitLong(List<TimeRange> speech, List<TimeRange> fineSpeech) {
  final result = <TimeRange>[];
  for (final range in speech) {
    if (range.duration <= kMaxSegment + 0.5) {
      result.add(range);
      continue;
    }
    // Точки-кандидаты для разреза — середины микропауз внутри интервала.
    final cutPoints = <double>[];
    for (var i = 0; i + 1 < fineSpeech.length; i++) {
      final gapStart = fineSpeech[i].end;
      final gapEnd = fineSpeech[i + 1].start;
      if (gapStart > range.start + 1.0 &&
          gapEnd < range.end - 1.0 &&
          gapEnd - gapStart >= 0.10) {
        cutPoints.add((gapStart + gapEnd) / 2);
      }
    }
    var cursor = range.start;
    while (range.end - cursor > kMaxSegment + 0.5) {
      final candidates = cutPoints
          .where((p) => p >= cursor + 1.5 && p <= cursor + kMaxSegment)
          .toList();
      final next = candidates.isNotEmpty
          ? candidates.reduce((a, b) => a > b ? a : b)
          : cursor + kForcedSplit;
      result.add(TimeRange(cursor, next));
      cursor = next;
    }
    result.add(TimeRange(cursor, range.end));
  }
  return result;
}

List<TimeRange> _merge(List<TimeRange> ranges) {
  final merged = <TimeRange>[];
  for (final range in ranges) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        range.start - last.end <= kMaxGap &&
        range.end - last.start <= kMaxSegment) {
      merged[merged.length - 1] = TimeRange(last.start, range.end);
    } else {
      merged.add(range);
    }
  }

  // Огрызки приклеиваем к предыдущему сегменту, если он это выдержит.
  final folded = <TimeRange>[];
  for (final range in merged) {
    final last = folded.isEmpty ? null : folded.last;
    if (last != null &&
        range.duration < kMinFragment &&
        range.start - last.end <= kMaxGap &&
        range.end - last.start <= kMaxSegment + 1.0) {
      folded[folded.length - 1] = TimeRange(last.start, range.end);
    } else {
      folded.add(range);
    }
  }
  return folded;
}

/// Добавляет паддинг, ограничивая его половиной зазора до соседа,
/// чтобы сегменты гарантированно не перекрывались.
List<TimeRange> _pad(List<TimeRange> ranges, double duration) {
  final result = <TimeRange>[];
  for (var i = 0; i < ranges.length; i++) {
    final range = ranges[i];
    // Гэп для расчёта паддинга берём между исходными (ещё не паддированными)
    // границами соседей — иначе паддинг предыдущего сегмента «съедает» часть
    // зазора ещё раз, и половина зазора считается неверно.
    final prevOriginalEnd = i == 0 ? 0.0 : ranges[i - 1].end;
    final prevPaddedEnd = result.isEmpty ? 0.0 : result.last.end;
    final nextStart = i + 1 < ranges.length ? ranges[i + 1].start : duration;

    final padBefore = _min(kPad, _max(0.0, (range.start - prevOriginalEnd) / 2));
    final padAfter = _min(kPad, _max(0.0, (nextStart - range.end) / 2));

    final start = _round2(_max(prevPaddedEnd, _max(0.0, range.start - padBefore)));
    final end = _round2(_min(duration, range.end + padAfter));
    if (end > start) result.add(TimeRange(start, end));
  }
  return result;
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;
