import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../logging.dart';
import 'ffmpeg_runner.dart';

/// Реализация для Android: ffmpeg вкомпилирован в приложение, отдельного
/// процесса нет.
///
/// Отличий от десктопной три, и все они вынужденные:
/// 1. Команда уходит в библиотеку, а не в процесс — значит нет ни stdout,
///    ни `-progress pipe:1`; прогресс приходит отдельным колбэком статистики.
/// 2. Длительность читается методом getMediaInformation, а не разбором
///    вывода ffprobe.
/// 3. Шрифты надо зарегистрировать до первого вшивания: на Android нет
///    конфигурации fontconfig, и libass без неё «успешно» рисует пустоту.
class LibFfmpegRunner implements FfmpegRunner {
  final DebugLog log;
  bool _fontsRegistered = false;

  LibFfmpegRunner({DebugLog? log}) : log = log ?? DebugLog.instance;

  /// Регистрирует папку со шрифтами. Без этого вшивание субтитров
  /// завершается с кодом 0, а текста в кадре нет.
  Future<void> registerFonts(String fontsDir) async {
    try {
      await FFmpegKitConfig.setFontDirectoryList([fontsDir]);
      _fontsRegistered = true;
      log.info('Шрифты зарегистрированы для libass: $fontsDir');
    } catch (e) {
      log.error('Не удалось зарегистрировать шрифты ($fontsDir): $e. '
          'Субтитры могут не отрисоваться.');
    }
  }

  bool get fontsRegistered => _fontsRegistered;

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    // `-progress pipe:1` рассчитан на отдельный процесс: здесь stdout некуда
    // отдавать, а прогресс приходит колбэком статистики.
    final cleaned = <String>[];
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-progress' && i + 1 < args.length) {
        i++;
        continue;
      }
      cleaned.add(args[i]);
    }

    log.debug('ffmpeg ▶ ${cleaned.join(' ')}');
    final started = DateTime.now();
    final completer = Completer<FfmpegResult>();

    await FFmpegKit.executeWithArgumentsAsync(
      cleaned,
      (session) async {
        final code = await session.getReturnCode();
        final output = await session.getAllLogsAsString() ?? '';
        final exitCode =
            ReturnCode.isSuccess(code) ? 0 : (code?.getValue() ?? -1);
        final tookMs = DateTime.now().difference(started).inMilliseconds;
        if (exitCode == 0) {
          log.debug('ffmpeg ✔ код 0, $tookMs мс');
        } else {
          log.error('ffmpeg ✘ код $exitCode, $tookMs мс\n${output.trim()}');
        }
        if (!completer.isCompleted) {
          completer.complete(FfmpegResult(exitCode: exitCode, log: output));
        }
      },
      null,
      (statistics) => onProgress?.call(statistics.getTime() / 1000.0),
    );

    return completer.future;
  }

  @override
  Future<double> probeDuration(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final duration = session.getMediaInformation()?.getDuration();
    if (duration == null) {
      final output = await session.getAllLogsAsString() ?? '';
      log.error('ffprobe ✘ не смог прочитать $path: ${output.trim()}');
      throw StateError('Не удалось прочитать длительность: $path');
    }
    return double.parse(duration);
  }
}
