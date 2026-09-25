/// Что из нашего burn_ru.srt доходит до кадра — проверка настоящим ffmpeg.
///
/// ffmpeg разбирает SRT как HTML-подобную разметку и отдаёт libass строку
/// ASS, где у libass своя разметка. Тексты здесь — то, что следователь
/// может вписать руками; все выдуманные.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/core/ffmpeg/commands.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/burner.dart';
import 'package:subtitler/core/srt.dart';

import '../support/media.dart';

const _texts = [
  '{неразборчиво} пойдём',
  'цена <5 тысяч> и x<y',
  'сказал <b>да</b> и < i>нет</i>',
  'отметка {C:1} и {\\an8} конец',
  'папка C:\\new\\Nдело \\h конец',
  'Первая строка\n   \nВторая строка',
  '<<кавычки>> и {} и }{ и <',
];

Cue _cue(String ru, {double start = 0.5, double end = 2.5}) => Cue(
      index: 1,
      range: TimeRange(start, end),
      orig: '',
      ru: ru,
      status: CueStatus.ok,
      flags: const {},
    );

/// Текст строки ASS так, как его нарисует libass (ass_parse.c,
/// ass_get_next_char; ass_render.c — блоки `{…}`; ass_shaper.c — U+2060
/// не рисуется).
String _asLibassDraws(String text) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '{' && text.indexOf('}', i) > i) {
      i = text.indexOf('}', i); // блок тегов — в кадр не попадает
    } else if (ch == r'\' && i + 1 < text.length) {
      final next = text[i + 1];
      final escaped = switch (next) {
        'N' => '\n',
        'n' => ' ',
        'h' => '\u00a0',
        '{' || '}' => next,
        _ => null,
      };
      if (escaped == null) {
        out.write(ch);
      } else {
        out.write(escaped);
        i++;
      }
    } else if (ch != '\u2060') {
      out.write(ch);
    }
  }
  return out.toString();
}

void main() {
  late Directory tmp;
  final burnSkip = burnSkipReason();

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('srt_burn_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('ffmpeg отдаёт libass ровно тот текст, что виден в предпросмотре',
      () async {
    for (final (i, text) in _texts.indexed) {
      final srt = p.join(tmp.path, 'in$i.srt');
      final ass = p.join(tmp.path, 'out$i.ass');
      File(srt).writeAsStringSync(
          buildSrt([_cue(text)], field: SrtField.ru, forBurning: true));
      final converted = await testRunner
          .run(['-y', '-hide_banner', '-loglevel', 'error', '-i', srt, ass]);
      expect(converted.ok, isTrue, reason: converted.log);
      final dialogue = File(ass)
          .readAsLinesSync()
          .singleWhere((l) => l.startsWith('Dialogue:'));
      // Текст — после девятой запятой.
      final assText = dialogue.split(',').skip(9).join(',');
      expect(_asLibassDraws(assText), subtitleText(_cue(text), SrtField.ru),
          reason: '«$text» → $assText');
    }
  });

  group('в кадре', () {
    late String video;

    setUpAll(() async {
      video = p.join(tmp.path, 'dark.mp4');
      final made = await testRunner.run([
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=#202020:s=848x480:d=3',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', video,
      ]);
      expect(made.ok, isTrue, reason: made.log);
    });

    Future<String> burn(String name, String text) async {
      final srt = p.join(tmp.path, '$name.srt');
      final out = p.join(tmp.path, '$name.mp4');
      File(srt).writeAsStringSync(
          buildSrt([_cue(text)], field: SrtField.ru, forBurning: true));
      await SubtitleBurner(testRunner).burn(
          input: video, srtPath: srt, fontsDir: 'assets/fonts', output: out);
      return out;
    }

    Future<List<int>> band(String burned) async {
      final raw = p.join(tmp.path, '${p.basename(burned)}.gray');
      final r = await testRunner.run(FfmpegCommands.grayBand(
          input: burned, atSeconds: 1.5, output: raw, exactSeek: true));
      expect(r.ok, isTrue, reason: r.log);
      return File(raw).readAsBytesSync();
    }

    test('невидимый соединитель U+2060 не меняет ни одного пикселя',
        () async {
      final plain = await burn('plain', 'пойдём на рынок');
      final joined = await burn('joined', 'пой\u2060дём на\u2060 рынок');
      expect(await band(joined), await band(plain));
    }, skip: burnSkip);

    test('текст в фигурных скобках виден целиком', () async {
      // Без экранирования libass считал «{…}» блоком тегов, и в кадре не
      // было ничего. Скобки чуть шире круглых — сравниваем с запасом.
      final braces = await burn('braces', '{неразборчиво}');
      final parens = await burn('parens', '(неразборчиво)');
      final burner = SubtitleBurner(testRunner);
      final shown = await burner.checkVisibility(
          original: video, burned: braces, atSeconds: 1.5);
      final reference = await burner.checkVisibility(
          original: video, burned: parens, atSeconds: 1.5);
      expect(shown.visible, isTrue, reason: shown.describe());
      expect(shown.changedPixels,
          greaterThan(reference.changedPixels * 0.9),
          reason: '${shown.describe()}; с круглыми: '
              '${reference.describe()}');
    }, skip: burnSkip);
  });
}
