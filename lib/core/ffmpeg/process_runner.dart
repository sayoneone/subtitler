import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging.dart';
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

  /// Куда писать выполняемые команды — это главный инструмент отладки:
  /// по строке из журнала команду можно повторить руками в терминале.
  final DebugLog log;

  ProcessFfmpegRunner({
    this.ffmpegPath = 'ffmpeg',
    this.ffprobePath = 'ffprobe',
    DebugLog? log,
  }) : log = log ?? DebugLog.instance;

  /// Берёт пути из окружения, а если их нет — из PATH.
  /// [env] подменяется в тестах.
  factory ProcessFfmpegRunner.fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    return ProcessFfmpegRunner(
      ffmpegPath: source[kFfmpegPathEnv] ?? 'ffmpeg',
      ffprobePath: source[kFfprobePathEnv] ?? 'ffprobe',
    );
  }

  static final _safeArg = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

  /// Строка, которую можно скопировать в терминал и повторить руками —
  /// самый полезный вид отладочной записи.
  String _asShellCommand(String executable, List<String> args) {
    String quote(String arg) {
      if (_safeArg.hasMatch(arg)) return arg;
      // В одинарных кавычках сама кавычка закрывается, экранируется и
      // открывается заново: don't -> 'don'\''t'.
      final escaped = arg.replaceAll("'", r"'\''");
      return "'$escaped'";
    }

    return [executable, ...args].map(quote).join(' ');
  }

  static final _outTimeUs = RegExp(r'out_time_us=(\d+)');

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    log.debug('ffmpeg ▶ ${_asShellCommand(ffmpegPath, args)}');
    final started = DateTime.now();
    final process = await Process.start(ffmpegPath, args);
    final errorOutput = StringBuffer();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(errorOutput.write);

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
    final tookMs = DateTime.now().difference(started).inMilliseconds;
    if (exitCode == 0) {
      log.debug('ffmpeg ✔ код 0, $tookMs мс');
    } else {
      log.error('ffmpeg ✘ код $exitCode, $tookMs мс\n'
          '${errorOutput.toString().trim()}');
    }
    return FfmpegResult(exitCode: exitCode, log: errorOutput.toString());
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
      log.error('ffprobe ✘ не смог прочитать $path: ${result.stderr}');
      throw StateError('ffprobe не смог прочитать $path: ${result.stderr}');
    }
    return double.parse((result.stdout as String).trim());
  }
}
