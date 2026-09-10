import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/pipeline/burner.dart';

/// Фильтр `subtitles` существует только в сборках ffmpeg с libass.
/// В релизных сборках он есть (Windows — gyan.dev release-essentials,
/// Android — ffmpeg_kit_flutter_new full-gpl), но ffmpeg из homebrew-core
/// собран без libass, поэтому на такой машине вшивание проверить нечем.
/// Эти тесты честно помечаются пропущенными, а не выдают ложный успех.
final _runner = ProcessFfmpegRunner.fromEnvironment();

String? _burnSkipReason() {
  final result = Process.runSync(_runner.ffmpegPath, ['-hide_banner', '-filters']);
  final hasSubtitles =
      RegExp(r'\bsubtitles\b').hasMatch(result.stdout as String);
  if (hasSubtitles) return null;
  return 'ffmpeg в PATH собран без libass: фильтра subtitles нет, '
      'вшивание на этой машине непроверяемо. Укажите путь к сборке с libass '
      'через переменную $kFfmpegPathEnv или проверяйте вшивание '
      'на Windows/Android.';
}

void main() {
  late Directory tmp;
  final runner = _runner;
  late String video;
  late String srt;
  final burnSkip = _burnSkipReason();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('burner_test_');
    video = '${tmp.path}/src.mp4';
    srt = '${tmp.path}/subs.srt';

    // Тёмный ролик: любой светлый пиксель внизу — это уже субтитр.
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=6',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-shortest', video,
    ]);

    File(srt).writeAsStringSync('''
1
00:00:01,000 --> 00:00:05,000
Проверка субтитров
''');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Счётчик светлых пикселей считает только яркие байты', () {
    expect(countBrightPixels([0, 10, 199, 200, 201, 255]), 2,
        reason: 'строго больше порога 200');
    expect(countBrightPixels(const []), 0);
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

  test('Копия без субтитров проверку не проходит', () async {
    final copy = '${tmp.path}/copy.mp4';
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', video, '-c', 'copy', copy,
    ]);
    expect(
      await SubtitleBurner(runner)
          .subtitlesVisible(original: video, burned: copy, atSeconds: 3.0),
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
