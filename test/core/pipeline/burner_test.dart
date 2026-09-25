import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/burner.dart';

/// Фильтр `subtitles` существует только в сборках ffmpeg с libass.
/// В релизных сборках он есть (Windows — gyan.dev release-essentials,
/// Android — ffmpeg_kit_flutter_new full-gpl), но ffmpeg из homebrew-core
/// собран без libass, поэтому на такой машине вшивание проверить нечем.
/// Эти тесты честно помечаются пропущенными, а не выдают ложный успех.
final _runner = ProcessFfmpegRunner.fromEnvironment();

String? _burnSkipReason() {
  final result =
      Process.runSync(_runner.ffmpegPath, ['-hide_banner', '-filters']);
  final hasSubtitles =
      RegExp(r'\bsubtitles\b').hasMatch(result.stdout as String);
  if (hasSubtitles) return null;
  return 'ffmpeg собран без libass: фильтра subtitles нет, вшивание на этой '
      'машине непроверяемо. Поставьте сборку с libass (brew install '
      'ffmpeg-full) и укажите её через переменную $kFfmpegPathEnv, '
      'либо проверяйте вшивание на Windows/Android.';
}

/// Ролик 848x480 (размер как у WhatsApp) с заливкой [color] и тоном.
Future<void> _makeVideo(String path, String color) async {
  final made = await _runner.run([
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'color=c=$color:s=848x480:d=6',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
    '-shortest', path,
  ]);
  if (!made.ok) throw StateError('Не удалось сделать ролик: ${made.log}');
}

void main() {
  late Directory tmp;
  final runner = _runner;
  late String video;
  late String brightVideo;
  late String srt;
  late String shortSrt;
  final burnSkip = _burnSkipReason();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('burner_test_');
    video = '${tmp.path}/src.mp4';
    brightVideo = '${tmp.path}/bright.mp4';
    srt = '${tmp.path}/subs.srt';
    shortSrt = '${tmp.path}/short.srt';

    // Тёмный кадр — самый удобный для проверки случай.
    await _makeVideo(video, '#202020');
    // Светлый низ кадра — стена, бумага, салон машины днём. Здесь белый
    // текст не добавляет светлых пикселей, а чёрная обводка их гасит.
    await _makeVideo(brightVideo, '#F0F0F0');

    // Реплика примерно той длины, что бывает в работе.
    File(srt).writeAsStringSync('''
1
00:00:01,000 --> 00:00:05,000
Проверка вшивания: строка обычной длины.
''');
    // Реплики в одно слово в разговоре обычны, и проверка обязана их видеть.
    File(shortSrt).writeAsStringSync('''
1
00:00:01,000 --> 00:00:05,000
Да.
''');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Изменёнными считаются только пиксели, сдвинувшиеся сильнее шума', () {
    expect(
      countChangedPixels(
          [0, 100, 200, 255, 30], [0, 100 + kSubtitlePixelDelta, 90, 255, 250]),
      2,
      reason: 'ровно на порог — ещё шум; белое в чёрное и чёрное в белое — '
          'это субтитры, в какую бы сторону ни сдвинулась яркость',
    );
    expect(countChangedPixels(const [], const []), 0);
  });

  test('Кадры разного размера не сравниваются молча', () {
    expect(() => countChangedPixels([1, 2, 3], [1, 2]), throwsStateError);
  });

  test('Порог растёт вместе с площадью полосы, но не опускается ниже пола', () {
    // 848x480: нижние 20 % — это 81408 пикселей.
    expect(subtitleMinChangedPixels(81408), 41);
    // 1280x720: полоса 184320 пикселей.
    expect(subtitleMinChangedPixels(184320), 92);
    // 320x240: полоса 15360 пикселей, доля вышла бы мельче пола.
    expect(subtitleMinChangedPixels(15360), kSubtitleMinChangedPixelsFloor);
    expect(subtitleMinChangedPixels(0), kSubtitleMinChangedPixelsFloor);
  });

  test('Из окна исходника засчитывается кадр, лучше всего совпавший со вшитым',
      () {
    // Вшитый кадр = второй кадр окна плюс два пикселя субтитров. Первый
    // и третий кадры окна отличаются ещё и «движением».
    const after = [255, 255, 10, 10, 10, 10];
    const window = [
      10, 10, 200, 200, 10, 10, // соседний кадр: сдвинулось всё
      10, 10, 10, 10, 10, 10, // тот же момент
      10, 10, 10, 10, 200, 200, // соседний кадр с другой стороны
    ];
    expect(fewestChangedPixels(window, after), 2);
  });

  test('Проверка идёт по реплике с самым длинным переводом', () {
    Cue cue(int i, double start, double end, String ru) => Cue(
        index: i,
        range: TimeRange(start, end),
        orig: '',
        ru: ru,
        status: CueStatus.ok,
        flags: const {});
    // Первая реплика в разговоре часто в одно слово и даёт мало пикселей.
    final cues = [
      cue(1, 0.0, 1.0, 'Алло?'),
      cue(2, 2.0, 4.0, '   '),
      cue(3, 5.0, 9.0, 'Приходи завтра к девяти, ключи у соседки.'),
      cue(4, 10.0, 11.0, 'Хорошо.'),
    ];
    expect(visibilityCheckPoint(cues), 7.0);
    expect(visibilityCheckPoint([cue(1, 0, 2, ''), cue(2, 3, 5, ' ')]), isNull,
        reason: 'без перевода вшивать нечего');
  });

  test('Окно, не кратное размеру кадра, не сравнивается молча', () {
    expect(() => fewestChangedPixels([1, 2, 3], [1, 2]), throwsStateError);
    expect(() => fewestChangedPixels(const [], [1, 2]), throwsStateError);
  });

  test('Субтитры на светлом низу кадра признаются видимыми', () async {
    // Самое вероятное объяснение жалобы коллег: субтитры в файле есть,
    // а приложение сообщает «Субтитры не отрисовались». Светлых пикселей
    // после вшивания здесь становится МЕНЬШЕ, чем было, — старая метрика
    // уходила в минус.
    final check = await SubtitleBurner(runner).burnAndVerify(
      input: brightVideo,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/bright_ru.mp4',
      checkAtSeconds: 3.0,
    );
    expect(check.visible, isTrue, reason: check.describe());
  }, skip: burnSkip);

  test('Реплика в одно слово признаётся видимой', () async {
    final check = await SubtitleBurner(runner).burnAndVerify(
      input: video,
      srtPath: shortSrt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/short_ru.mp4',
      checkAtSeconds: 3.0,
    );
    expect(check.visible, isTrue, reason: check.describe());
  }, skip: burnSkip);

  test('Кадр достаётся и из MPEG-TS с длинной группой кадров', () async {
    // x264 по умолчанию ставит ключевой кадр раз в 250 кадров. В таком TS
    // быстрая перемотка (-ss до -i) не находила кадр вовсе: полоса
    // приходила пустой, и проверка падала на готовом, вшитом ролике.
    final ts = '${tmp.path}/long_gop.ts';
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=#202020:s=848x480:d=6',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-shortest', ts,
    ]);
    expect(made.ok, isTrue, reason: made.log);

    final check = await SubtitleBurner(runner).burnAndVerify(
      input: ts,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/long_gop_ru.mp4',
      checkAtSeconds: 3.0,
    );
    expect(check.visible, isTrue, reason: check.describe());
  }, skip: burnSkip);

  test('Сдвиг на кадр между исходником и перекодированным не выдаётся за субтитры',
      () async {
    // Видео начинается на 23 мс позже звука — так бывает у записей с
    // телефона. Кодировщик округляет начало до кадра, и один и тот же
    // момент в двух файлах попадает в соседние кадры. На движущейся
    // картинке сравнение «кадр с кадром» видело тысячи изменённых
    // пикселей там, где субтитров нет вовсе.
    final raw = '${tmp.path}/moving_raw.mp4';
    final shifted = '${tmp.path}/moving_shifted.mp4';
    final reencoded = '${tmp.path}/moving_shifted_re.mp4';
    for (final args in [
      ['-y', '-hide_banner', '-loglevel', 'error',
       '-f', 'lavfi', '-i', 'testsrc2=s=848x480:d=6',
       '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
       '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
       '-shortest', raw],
      ['-y', '-hide_banner', '-loglevel', 'error',
       '-itsoffset', '0.023', '-i', raw, '-i', raw,
       '-map', '0:v', '-map', '1:a', '-c', 'copy', shifted],
      ['-y', '-hide_banner', '-loglevel', 'error', '-i', shifted,
       '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast',
       '-c:a', 'copy', reencoded],
    ]) {
      final r = await runner.run(args);
      expect(r.ok, isTrue, reason: r.log);
    }
    final check = await SubtitleBurner(runner).checkVisibility(
        original: shifted, burned: reencoded, atSeconds: 1.0);
    expect(check.visible, isFalse, reason: check.describe());
  });

  test('Короткая реплика на маленьком кадре признаётся видимой', () async {
    // Число пикселей текста растёт с высотой кадра, а нижний предел порога
    // нет: на 320x240 реплика «А?» давала 34 пикселя при нужных 40.
    final small = '${tmp.path}/small.mp4';
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=#202020:s=320x240:d=6',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-shortest', small,
    ]);
    expect(made.ok, isTrue, reason: made.log);
    final tinySrt = '${tmp.path}/tiny.srt';
    File(tinySrt).writeAsStringSync('''
1
00:00:01,000 --> 00:00:05,000
А?
''');
    final check = await SubtitleBurner(runner).burnAndVerify(
      input: small,
      srtPath: tinySrt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/small_ru.mp4',
      checkAtSeconds: 3.0,
    );
    expect(check.visible, isTrue, reason: check.describe());
  }, skip: burnSkip);

  test('Перекодирование светлого ролика без субтитров проверку не проходит',
      () async {
    // Новая метрика не должна принимать шум сжатия за текст и на светлом.
    final reencoded = '${tmp.path}/bright_reencoded.mp4';
    final result = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', brightVideo,
      '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-c:a', 'copy',
      reencoded,
    ]);
    expect(result.ok, isTrue, reason: result.log);
    expect(
      await SubtitleBurner(runner).subtitlesVisible(
          original: brightVideo, burned: reencoded, atSeconds: 3.0),
      isFalse,
    );
  });

  test('Вшивание создаёт видео, где субтитры действительно видны', () async {
    final out = '${tmp.path}/out.mp4';
    final burner = SubtitleBurner(runner);

    await burner.burn(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: out,
    );

    expect(File(out).existsSync(), isTrue);
    expect(File(out).lengthSync(), greaterThan(0));
    expect(
      await burner.subtitlesVisible(
          original: video, burned: out, atSeconds: 3.0),
      isTrue,
    );
  }, skip: burnSkip);

  test('burnAndVerify пропускает удачное вшивание', () async {
    await SubtitleBurner(runner).burnAndVerify(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/verified.mp4',
      checkAtSeconds: 3.0,
    );
    expect(File('${tmp.path}/verified.mp4').existsSync(), isTrue);
  }, skip: burnSkip);

  test('burnAndVerify бросает исключение, если субтитров в кадре нет', () async {
    // SRT, у которого нет ни одной реплики в момент проверки.
    final lateSrt = '${tmp.path}/late.srt';
    File(lateSrt).writeAsStringSync('''
1
00:00:05,500 --> 00:00:05,900
Поздняя реплика
''');
    await expectLater(
      SubtitleBurner(runner).burnAndVerify(
        input: video,
        srtPath: lateSrt,
        fontsDir: 'assets/fonts',
        output: '${tmp.path}/invisible.mp4',
        checkAtSeconds: 3.0,
      ),
      throwsA(isA<SubtitlesInvisibleException>()),
    );
  }, skip: burnSkip);

  test('Перекодирование без субтитров проверку не проходит', () async {
    // Именно перекодирование, а не копирование потока: так проверяется,
    // что шум компрессии не выдаётся за появившийся текст.
    final reencoded = '${tmp.path}/reencoded.mp4';
    final result = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', video,
      '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-c:a', 'copy',
      reencoded,
    ]);
    expect(result.ok, isTrue, reason: result.log);
    expect(
      await SubtitleBurner(runner)
          .subtitlesVisible(original: video, burned: reencoded, atSeconds: 3.0),
      isFalse,
      reason: 'иначе проверка бесполезна и пропустит невидимые субтитры',
    );
  });

  test('Прогресс сообщается по ходу кодирования', () async {
    final seen = <double>[];
    await SubtitleBurner(runner).burn(
      input: video,
      srtPath: srt,
      fontsDir: 'assets/fonts',
      output: '${tmp.path}/progress.mp4',
      onProgress: seen.add,
    );
    expect(seen, isNotEmpty);
    expect(seen.last, greaterThan(0));
  }, skip: burnSkip);
}
