import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ffmpeg_runner.dart';

/// Переменные окружения, которыми разработчик указывает свой ffmpeg.
/// Нужны, потому что системный ffmpeg бывает собран без libass, а фильтр
/// `subtitles` без него не существует. В релизе путь задаётся явно —
/// на Windows это `tools/ffmpeg/ffmpeg.exe` рядом с приложением.
const String kFfmpegPathEnv = 'SUBTITLER_FFMPEG';
const String kFfprobePathEnv = 'SUBTITLER_FFPROBE';

/// Десктопная реализация: ffmpeg как отдельный процесс.
class ProcessFfmpegRunner implements FfmpegRunner {
  final String ffmpegPath;
  final String ffprobePath;

  ProcessFfmpegRunner({
    this.ffmpegPath = 'ffmpeg',
    this.ffprobePath = 'ffprobe',
  });

  /// Берёт пути из окружения, а если их нет — из PATH.
  /// [env] подменяется в тестах.
  factory ProcessFfmpegRunner.fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    return ProcessFfmpegRunner(
      ffmpegPath: source[kFfmpegPathEnv] ?? 'ffmpeg',
      ffprobePath: source[kFfprobePathEnv] ?? 'ffprobe',
    );
  }

  static final _outTimeUs = RegExp(r'out_time_us=(\d+)');

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    final process = await Process.start(ffmpegPath, args);
    final log = StringBuffer();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(log.write);

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      final match = _outTimeUs.firstMatch(line);
      if (match != null && onProgress != null) {
        onProgress(int.parse(match.group(1)!) / 1000000);
      }
    });

    final exitCode = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    return FfmpegResult(exitCode: exitCode, log: log.toString());
  }

  @override
  Future<double> probeDuration(String path) async {
    final result = await Process.run(ffprobePath, [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1',
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('ffprobe не смог прочитать $path: ${result.stderr}');
    }
    return double.parse((result.stdout as String).trim());
  }
}
