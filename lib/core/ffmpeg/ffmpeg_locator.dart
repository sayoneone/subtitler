import 'dart:io';

import '../logging.dart';
import 'process_runner.dart';

/// Что удалось выяснить про найденный ffmpeg.
class FfmpegInfo {
  final String ffmpegPath;
  final String ffprobePath;
  final String version;

  /// Есть ли фильтр `subtitles`. Без libass вшивание невозможно.
  final bool hasLibass;

  /// Откуда взялся путь — показываем в интерфейсе, чтобы было видно,
  /// какой именно бинарь используется.
  final String source;

  const FfmpegInfo({
    required this.ffmpegPath,
    required this.ffprobePath,
    required this.version,
    required this.hasLibass,
    required this.source,
  });
}

/// Ищет пригодный ffmpeg.
///
/// Приложение, запущенное из Finder, не наследует PATH из терминала, поэтому
/// полагаться на голое имя `ffmpeg` нельзя — перебираем известные места.
/// Сборка с libass приоритетнее: без неё не работает вшивание субтитров.
class FfmpegLocator {
  static const List<String> knownPaths = [
    // Сборка с libass из homebrew-core (keg-only, не подменяет системную).
    '/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg',
    '/usr/local/opt/ffmpeg-full/bin/ffmpeg',
    '/opt/homebrew/bin/ffmpeg',
    '/usr/local/bin/ffmpeg',
    '/usr/bin/ffmpeg',
  ];

  static List<String> candidates({String? override}) {
    final env = Platform.environment[kFfmpegPathEnv];
    return [
      if (override != null && override.trim().isNotEmpty) override.trim(),
      if (env != null && env.isNotEmpty) env,
      ...knownPaths,
      'ffmpeg', // последняя надежда: вдруг PATH всё-таки есть
    ];
  }

  static String _probeFor(String ffmpegPath) {
    if (!ffmpegPath.contains(Platform.pathSeparator)) return 'ffprobe';
    final dir = ffmpegPath.substring(
        0, ffmpegPath.lastIndexOf(Platform.pathSeparator));
    return '$dir${Platform.pathSeparator}ffprobe';
  }

  /// Возвращает первый рабочий ffmpeg, предпочитая сборку с libass.
  /// null — если не нашлось ничего работающего.
  static Future<FfmpegInfo?> locate({String? override, DebugLog? log}) async {
    final journal = log ?? DebugLog.instance;
    FfmpegInfo? fallback;

    for (final path in candidates(override: override)) {
      try {
        final filters =
            await Process.run(path, ['-hide_banner', '-filters']);
        if (filters.exitCode != 0) {
          journal.debug('ffmpeg не запустился: $path');
          continue;
        }
        final hasLibass =
            RegExp(r'\bsubtitles\b').hasMatch(filters.stdout as String);

        final versionRun = await Process.run(path, ['-version']);
        final version = (versionRun.stdout as String).split('\n').first.trim();

        final info = FfmpegInfo(
          ffmpegPath: path,
          ffprobePath: _probeFor(path),
          version: version,
          hasLibass: hasLibass,
          source: path,
        );

        if (hasLibass) {
          journal.info('ffmpeg найден (с libass): $path');
          return info;
        }
        journal.debug('ffmpeg найден, но без libass: $path');
        fallback ??= info;
      } on ProcessException {
        journal.debug('ffmpeg отсутствует: $path');
      }
    }

    if (fallback != null) {
      journal.warn(
          'Используется ffmpeg без libass (${fallback.ffmpegPath}): '
          'вшивание субтитров будет недоступно. Поставьте сборку с libass: '
          'brew install ffmpeg-full');
    } else {
      journal.error('ffmpeg не найден ни в одном из известных мест');
    }
    return fallback;
  }
}
