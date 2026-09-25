// test/core/pipeline/silence_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/pipeline/silence_parser.dart';

const _log = '''
[Parsed_silencedetect_0 @ 0x600000c1c0] silence_start: 2.41337
[Parsed_silencedetect_0 @ 0x600000c1c0] silence_end: 3.90561 | silence_duration: 1.49224
[Parsed_silencedetect_0 @ 0x600000c1c0] silence_start: 8.12473
[Parsed_silencedetect_0 @ 0x600000c1c0] silence_end: 9.03319 | silence_duration: 0.90846
''';

void main() {
  test('Парсер вытаскивает события в порядке появления', () {
    final events = parseSilenceLog(_log);
    expect(events.length, 4);
    expect(events[0].kind, SilenceEventKind.start);
    expect(events[0].time, closeTo(2.41337, 1e-6));
    expect(events[1].kind, SilenceEventKind.end);
    expect(events[1].time, closeTo(3.90561, 1e-6));
    expect(events[3].time, closeTo(9.03319, 1e-6));
  });

  test('Парсер игнорирует посторонние строки лога', () {
    final events = parseSilenceLog('Stream #0:0 Audio: aac\nframe= 42 fps=0.0\n');
    expect(events, isEmpty);
  });

  test('Речь — это промежутки между паузами, включая хвост', () {
    final speech = speechIntervals(parseSilenceLog(_log), 10.0);
    expect(speech.length, 3);
    expect(speech[0].start, closeTo(0.0, 1e-9));
    expect(speech[0].end, closeTo(2.41337, 1e-6));
    expect(speech[1].start, closeTo(3.90561, 1e-6));
    expect(speech[1].end, closeTo(8.12473, 1e-6));
    expect(speech[2].start, closeTo(9.03319, 1e-6));
    expect(speech[2].end, closeTo(10.0, 1e-9), reason: 'хвост до конца файла');
  });

  test('Без событий весь файл считается речью', () {
    expect(speechIntervals(const [], 12.5).single.end, closeTo(12.5, 1e-9));
  });

  test('Пауза до конца файла не даёт хвостового интервала', () {
    final events = parseSilenceLog(
        '[silencedetect @ 0x1] silence_start: 9.5\n');
    final speech = speechIntervals(events, 10.0);
    expect(speech.length, 1);
    expect(speech.single.end, closeTo(9.5, 1e-9));
  });
}
