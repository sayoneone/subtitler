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

/// Текст реплики [cue] в том виде, в каком его покажут субтитры; пустая
/// строка — реплики в субтитрах нет.
///
/// Одно правило на всех: по нему [buildSrt] решает, попадёт ли реплика в
/// файл (и во вшивание), а оверлей предпросмотра (`isCueVisible`) — есть
/// ли она в кадре и что в нём написано. Статус реплики не важен:
/// вписанный человеком текст вшивается при любом статусе, значит, и виден
/// должен быть.
///
/// Строки — без пробелов по краям, пустых строк внутри нет, табуляция —
/// пробел. Так текст выглядит и после ffmpeg: пустую строку внутри блока
/// его разбор SRT пропускает, а строка из одних пробелов вообще обрывает
/// реплику — всё, что после неё, в кадр не попадало (libavcodec/
/// htmlsubtitles.c: перевод строки в начале строки — конец текста).
String subtitleText(Cue cue, SrtField field) => _textOf(cue, field)
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\t', ' ')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n');

/// Невидимый «соединитель слов» U+2060. libass его пропускает, не рисуя
/// и не оставляя места (ass_shaper.c: is_harfbuzz_ignorable), а разбор
/// разметки ffmpeg и libass он разрывает.
const String _wordJoiner = '⁠';

/// Обезвреживает в [text] всё, что ffmpeg и libass при вшивании приняли бы
/// за разметку, — чтобы в кадре оказался ровно этот текст.
///
/// Путь текста: ffmpeg разбирает SRT как HTML-подобную разметку
/// (libavcodec/htmlsubtitles.c) и отдаёт libass строку ASS.
/// - `<` ffmpeg считает началом тега, если за ним (в том числе после
///   пробелов или `/`) до `>` идёт слово из латинских букв и цифр: `<b>`
///   и `< i>` превращает в жирный и курсив, `<5 тысяч>` выбрасывает
///   целиком. После `<` ставится U+2060 — тег не узнаётся, `<` остаётся.
/// - `{` libass считает началом блока тегов до `}`: «{неразборчиво}»
///   пропадало из кадра. `\{` и `\}` libass рисует как скобки
///   (ass_parse.c: ass_get_next_char). После `\{` — U+2060: иначе ffmpeg
///   вырезал бы «{\…}» и «{C:…}» ещё до libass.
/// - `\N`, `\n`, `\h` libass понимает как перенос и пробелы, а удвоенный
///   `\\` экраном не считает. После каждого `\` — U+2060, и он рисуется
///   просто косой чертой.
///
/// Проверено ffmpeg 9.0.1 с libass: кадры с U+2060 и без него совпадают
/// до пикселя, а экранированный текст виден в кадре целиком.
String escapeSubtitleMarkup(String text) => text.replaceAllMapped(
      RegExp(r'[\\{}<]'),
      (m) => switch (m[0]) {
        r'\' => '\\$_wordJoiner',
        '{' => '\\{$_wordJoiner',
        '}' => r'\}',
        _ => '<$_wordJoiner',
      },
    );

/// Собирает SRT из реплик. Реплики с пустым текстом пропускаются,
/// номера блоков идут подряд без дыр.
///
/// [forBurning] — файл для вшивания: разметка в тексте обезврежена
/// ([escapeSubtitleMarkup]). Файлы рядом с видео — для человека и других
/// плееров, в них текст как есть: обратные косые и невидимые знаки там
/// только мешали бы читать и искать.
String buildSrt(
  List<Cue> cues, {
  required SrtField field,
  bool forBurning = false,
}) {
  final buffer = StringBuffer();
  var number = 1;
  for (final cue in cues) {
    final text = subtitleText(cue, field);
    if (text.isEmpty) continue;
    buffer
      ..writeln(number)
      ..writeln('${formatSrtTimestamp(cue.range.start)} --> '
          '${formatSrtTimestamp(cue.range.end)}')
      ..writeln(forBurning ? escapeSubtitleMarkup(text) : text)
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
