// lib/core/pipeline/silence_parser.dart
import '../models.dart';

enum SilenceEventKind { start, end }

class SilenceEvent {
  final SilenceEventKind kind;
  final double time;
  const SilenceEvent(this.kind, this.time);
}

final _eventPattern =
    RegExp(r'silence_(start|end):\s*(-?\d+(?:\.\d+)?)');

/// Разбирает stderr ffmpeg с фильтром silencedetect.
List<SilenceEvent> parseSilenceLog(String log) {
  return _eventPattern.allMatches(log).map((m) {
    final kind = m.group(1) == 'start'
        ? SilenceEventKind.start
        : SilenceEventKind.end;
    return SilenceEvent(kind, double.parse(m.group(2)!));
  }).toList();
}

/// Инвертирует паузы в интервалы речи. Слишком короткие огрызки (< 0.05 с)
/// отбрасываются: это артефакты на границах, а не реплики.
List<TimeRange> speechIntervals(List<SilenceEvent> events, double duration) {
  if (events.isEmpty) return [TimeRange(0, duration)];

  final result = <TimeRange>[];
  double? speechStart = 0;

  for (final event in events) {
    if (event.kind == SilenceEventKind.start) {
      if (speechStart != null) {
        final start = speechStart.clamp(0.0, duration);
        final end = event.time.clamp(0.0, duration);
        if (end - start > 0.05) result.add(TimeRange(start, end));
      }
      speechStart = null;
    } else {
      speechStart = event.time.clamp(0.0, duration);
    }
  }

  if (speechStart != null && duration - speechStart > 0.05) {
    result.add(TimeRange(speechStart, duration));
  }
  return result;
}
