import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../logging.dart';
import 'ffmpeg_runner.dart';

/// Переменные окружения, которыми разработчик указывает свой ffmpeg.
/// Нужны, потому что системный ffmpeg бывает собран без libass, а фильтр
/// `subtitles` без него не существует. В релизе путь задаётся явно —
/// на Windows это `tools/ffmpeg/ffmpeg.exe` рядом с приложением.
const String kFfmpegPathEnv = 'SUBTITLER_FFMPEG';
const String kFfprobePathEnv = 'SUBTITLER_FFPROBE';

/// Десктопная реализация: ffmpeg как отдельный процесс.
class ProcessFfmpegRunner implements StoppableFfmpegRunner {
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

  /// Вывод ffmpeg — диагностика, а не данные: в нём бывают метаданные
  /// ролика в чужой кодировке (заголовки AVI в CP1251 — обычное дело).
  /// Строгий декодер ронял на таком байте всю обработку, поэтому битые
  /// последовательности заменяются символом-заменителем.
  static const _lenientUtf8 = Utf8Decoder(allowMalformed: true);

  /// Запущенные сейчас ffmpeg — чтобы остановить их при закрытии окна.
  final Set<Process> _running = {};
  bool _stopped = false;

  /// PID запущенных сейчас ffmpeg.
  Iterable<int> get runningPids => _running.map((process) => process.pid);

  @override
  Future<void> stopAll() async {
    _stopped = true;
    final running = [..._running];
    for (final process in running) {
      log.warn('Останавливаем ffmpeg (PID ${process.pid})');
      process.kill();
    }
    await Future.wait([for (final process in running) process.exitCode]);
  }

  static const FfmpegResult _refused =
      FfmpegResult(exitCode: -1, log: 'ffmpeg не запущен: программа закрывается');

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    if (_stopped) return _refused;
    log.debug('ffmpeg ▶ ${_asShellCommand(ffmpegPath, args)}');
    final started = DateTime.now();
    final process = await Process.start(ffmpegPath, args);
    _running.add(process);
    // stopAll мог прийти, пока процесс запускался.
    if (_stopped) process.kill();
    try {
      return await _collect(process, started, onProgress);
    } finally {
      _running.remove(process);
    }
  }

  Future<FfmpegResult> _collect(Process process, DateTime started,
      void Function(double seconds)? onProgress) async {
    final errorOutput = StringBuffer();

    final stderrDone = process.stderr
        .transform(_lenientUtf8)
        .forEach(errorOutput.write);

    final stdoutDone = process.stdout
        .transform(_lenientUtf8)
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

  /// `Duration: 00:00:34.80, start: ...` — так ffmpeg сообщает длительность.
  static final _durationLine =
      RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)');

  /// Достаёт длительность из вывода `ffmpeg -i`.
  ///
  /// Отдельный ffprobe для этого не нужен, а в переносимой сборке под
  /// Windows он стоил бы лишних 98 МБ: там каждый бинарник статический,
  /// и один и тот же код лежал бы дважды.
  static double? parseDuration(String ffmpegOutput) {
    final m = _durationLine.firstMatch(ffmpegOutput);
    if (m == null) return null;
    final fraction = m.group(4)!;
    return int.parse(m.group(1)!) * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!) +
        int.parse(fraction) / math.pow(10, fraction.length);
  }

  @override
  Future<double> probeDuration(String path) async {
    // ffprobe точнее, но он есть не везде: пробуем его, а если бинарника
    // нет — читаем то же самое из вывода ffmpeg.
    try {
      final result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=nw=1:nk=1',
        path,
      ]);
      if (result.exitCode == 0) {
        final value = double.tryParse((result.stdout as String).trim());
        if (value != null) return value;
      }
    } on ProcessException {
      log.debug('ffprobe отсутствует, длительность берём из вывода ffmpeg');
    }

    final probe = await Process.run(ffmpegPath, ['-hide_banner', '-i', path]);
    final duration = parseDuration('${probe.stdout}${probe.stderr}');
    if (duration == null) {
      log.error('Не удалось определить длительность: $path');
      throw StateError('Не удалось определить длительность: $path');
    }
    return duration;
  }
}
