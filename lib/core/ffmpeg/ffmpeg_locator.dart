import 'dart:io';

import 'package:path/path.dart' as p;

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
  /// Куда ffmpeg кладут пакетные менеджеры. Это машина разработчика: на
  /// служебном ПК следователя ничего из этого нет и быть не может.
  static const List<String> knownPaths = [
    // Сборка с libass из homebrew-core (keg-only, не подменяет системную).
    '/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg',
    '/usr/local/opt/ffmpeg-full/bin/ffmpeg',
    '/opt/homebrew/bin/ffmpeg',
    '/usr/local/bin/ffmpeg',
    '/usr/bin/ffmpeg',
  ];

  /// Бинарники, распакованные вместе с приложением.
  ///
  /// Переносимая сборка под Windows кладёт ffmpeg в `tools/ffmpeg/` рядом с
  /// `subtitler.exe` — так собирает `.github/workflows/build.yml`. Искать его
  /// там обязательно: приложение раздаётся ZIP-архивом на служебный ПК, где
  /// нет ни прав администратора, ни установщиков, ни ffmpeg в PATH. Всё, на
  /// что можно опереться, лежит в самой папке приложения.
  ///
  /// [appDir] и [windows] подменяются в тестах: перебор путей должен
  /// проверяться одинаково на любой машине, где идут тесты.
  static List<String> bundledPaths({String? appDir, bool? windows}) {
    final onWindows = windows ?? Platform.isWindows;
    // Явный контекст путей, а не платформенный: иначе тест Windows-раскладки
    // собирал бы разделители хозяйской ОС и падал бы на Linux-раннере.
    final context = onWindows ? p.windows : p.posix;
    final dir = appDir ?? context.dirname(Platform.resolvedExecutable);
    final name = onWindows ? 'ffmpeg.exe' : 'ffmpeg';
    return [
      context.join(dir, 'tools', 'ffmpeg', name),
      context.join(dir, name),
    ];
  }

  /// [env], [appDir] и [windows] подменяются в тестах.
  static List<String> candidates({
    String? override,
    Map<String, String>? env,
    String? appDir,
    bool? windows,
  }) {
    final onWindows = windows ?? Platform.isWindows;
    final fromEnv = (env ?? Platform.environment)[kFfmpegPathEnv];
    return [
      if (override != null && override.trim().isNotEmpty) override.trim(),
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      // Своя сборка идёт раньше системной: приложение не должно зависеть от
      // того, что установлено на машине пользователя.
      ...bundledPaths(appDir: appDir, windows: windows),
      // Пути пакетных менеджеров бывают только в Unix. На Windows их перебор
      // — это пять бессмысленных строк в журнале перед словом «не найден».
      if (!onWindows) ...knownPaths,
      'ffmpeg', // последняя надежда: вдруг PATH всё-таки есть
    ];
  }

  /// Что советовать, когда пригодного ffmpeg нет. Совет зависит от платформы:
  /// Homebrew на служебном ПК не существует, и чинить там нужно не установку,
  /// а распаковку архива.
  static String get _hint => Platform.isWindows
      ? 'В переносимой сборке ffmpeg лежит в tools\\ffmpeg рядом с '
          'subtitler.exe — проверьте, что архив распакован целиком.'
      : 'Поставьте сборку с libass: brew install ffmpeg-full';

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
          'вшивание субтитров будет недоступно. $_hint');
    } else {
      journal.error('ffmpeg не найден ни в одном из известных мест. $_hint');
    }
    return fallback;
  }
}
