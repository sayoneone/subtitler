import 'models.dart';

enum SrtField { orig, ru }

String _two(int v) => v.toString().padLeft(2, '0');
String _three(int v) => v.toString().padLeft(3, '0');

String formatSrtTimestamp(double seconds) {
  final totalMs = (seconds * 1000).round();
  final ms = totalMs % 1000;
  final totalSec = totalMs ~/ 1000;
  return '${_two(totalSec ~/ 3600)}:${_two((totalSec % 3600) ~/ 60)}:'
      '${_two(totalSec % 60)},${_three(ms)}';
}

double parseSrtTimestamp(String value) {
  final m = RegExp(r'(\d+):(\d+):(\d+),(\d+)').firstMatch(value.trim());
  if (m == null) throw FormatException('Не таймкод SRT: $value');
  return int.parse(m.group(1)!) * 3600 +
      int.parse(m.group(2)!) * 60 +
      int.parse(m.group(3)!) +
      int.parse(m.group(4)!) / 1000;
}

String _textOf(Cue cue, SrtField field) =>
    field == SrtField.orig ? cue.orig : cue.ru;

/// Собирает SRT из реплик. Реплики с пустым текстом пропускаются,
/// номера блоков идут подряд без дыр.
String buildSrt(List<Cue> cues, {required SrtField field}) {
  final buffer = StringBuffer();
  var number = 1;
  for (final cue in cues) {
    final text = _textOf(cue, field).trim();
    if (text.isEmpty) continue;
    buffer
      ..writeln(number)
      ..writeln('${formatSrtTimestamp(cue.range.start)} --> '
          '${formatSrtTimestamp(cue.range.end)}')
      ..writeln(text)
      ..writeln();
    number++;
  }
  return buffer.toString();
}

/// Разбирает SRT. Текст кладётся и в orig, и в ru: вызывающий знает,
/// какой это файл, а модель одна.
List<Cue> parseSrt(String content) {
  final blocks = content.trim().split(RegExp(r'\n\s*\n'));
  final cues = <Cue>[];
  for (final block in blocks) {
    final lines = block.trim().split('\n');
    if (lines.length < 3) continue;
    final times = lines[1].split('-->');
    if (times.length != 2) continue;
    final text = lines.sublist(2).join('\n').trim();
    cues.add(Cue(
      index: int.tryParse(lines[0].trim()) ?? cues.length + 1,
      range: TimeRange(parseSrtTimestamp(times[0]), parseSrtTimestamp(times[1])),
      orig: text,
      ru: text,
      status: CueStatus.ok,
      flags: const {},
    ));
  }
  return cues;
}
