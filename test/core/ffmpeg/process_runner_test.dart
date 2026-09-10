import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';

void main() {
  late Directory tmp;
  final runner = ProcessFfmpegRunner.fromEnvironment();

  setUpAll(() => tmp = Directory.systemTemp.createTempSync('runner_test_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Синтезирует тон и читает его длительность', () async {
    final wav = '${tmp.path}/tone.wav';
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
      wav,
    ]);
    expect(made.ok, isTrue, reason: made.log);
    expect(await runner.probeDuration(wav), closeTo(3.0, 0.05));
  });

  test('Неверные аргументы дают ненулевой код и текст ошибки', () async {
    final result = await runner.run(['-i', '${tmp.path}/нет-такого.mp4', '-f', 'null', '-']);
    expect(result.ok, isFalse);
    expect(result.log, isNotEmpty);
  });

  test('Путь к ffmpeg берётся из окружения, если задан', () {
    final custom = ProcessFfmpegRunner.fromEnvironment({
      kFfmpegPathEnv: '/opt/custom/ffmpeg',
      kFfprobePathEnv: '/opt/custom/ffprobe',
    });
    expect(custom.ffmpegPath, '/opt/custom/ffmpeg');
    expect(custom.ffprobePath, '/opt/custom/ffprobe');
  });

  test('Без переменных окружения берётся ffmpeg из PATH', () {
    final fallback = ProcessFfmpegRunner.fromEnvironment(const {});
    expect(fallback.ffmpegPath, 'ffmpeg');
    expect(fallback.ffprobePath, 'ffprobe');
  });

  test('FfmpegResult.ok привязан к нулевому коду', () {
    expect(const FfmpegResult(exitCode: 0, log: '').ok, isTrue);
    expect(const FfmpegResult(exitCode: 1, log: '').ok, isFalse);
  });
}
