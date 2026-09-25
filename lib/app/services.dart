import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/cloud/speechkit_client.dart';
import '../core/cloud/translate_client.dart';
import '../core/ffmpeg/ffmpeg_locator.dart';
import '../core/ffmpeg/ffmpeg_runner.dart';
import '../core/ffmpeg/lib_runner.dart';
import '../core/ffmpeg/process_runner.dart';
import '../core/logging.dart';
import 'key_store.dart';
import 'reveal.dart';
import 'runtime.dart';
import 'settings.dart';

/// Всё, чем контроллер трогает внешний мир: диск, ffmpeg, сеть, хранилище
/// ключа, Проводник. В тестах каждое подменяется подделкой, и контроллер
/// проверяется без настоящего окружения.
///
/// Настоящие реализации — [AppServices.real].
class AppServices {
  /// Папки приложения, журнал в файл, шрифт для libass.
  final Future<AppRuntime> Function(DebugLog log) prepareRuntime;

  /// Пригодный ffmpeg. `null` — не найден. На Android он встроен.
  final Future<FfmpegInfo?> Function(DebugLog log) locateFfmpeg;

  /// Какие пути перебирает поиск ffmpeg — для «Технических деталей».
  final List<String> Function() ffmpegCandidates;

  final KeyStore Function(String supportDir, DebugLog log) keyStore;
  final SettingsStore Function(String supportDir, DebugLog log) settingsStore;

  /// Исполнитель команд ffmpeg для найденного [FfmpegInfo].
  final Future<FfmpegRunner> Function(
      FfmpegInfo ffmpeg, AppRuntime runtime, DebugLog log) runner;

  final SpeechKitClient Function(String apiKey) speechKit;
  final TranslateClient Function(String apiKey) translate;

  /// Показать файл в Проводнике (Finder). `false` — не получилось.
  final Future<bool> Function(String path) reveal;

  /// «Поделиться» файлами (Android).
  final Future<void> Function(List<String> paths) share;

  /// Пауза между повторами запросов; в тестах — мгновенная.
  final Future<void> Function(Duration delay) sleep;

  /// Версия приложения — в журнал при старте и в «О программе».
  final Future<String> Function() appVersion;

  /// Версия ОС — в журнал при старте.
  final String Function() osVersion;

  /// Телефон: ffmpeg встроен, файлы не перетаскиваются, вместо «Открыть
  /// папку» — «Поделиться».
  final bool isMobile;

  /// Показывать ли пункт «Для разработчика → Отладочный стенд»: только в
  /// отладочной сборке или с переменной окружения SUBTITLER_DEBUG=1.
  final bool debugStandAvailable;

  const AppServices({
    required this.prepareRuntime,
    required this.locateFfmpeg,
    required this.ffmpegCandidates,
    required this.keyStore,
    required this.settingsStore,
    required this.runner,
    required this.speechKit,
    required this.translate,
    required this.reveal,
    required this.share,
    required this.sleep,
    required this.appVersion,
    required this.osVersion,
    required this.isMobile,
    this.debugStandAvailable = false,
  });

  /// Настоящее окружение: path_provider, ffmpeg из папки приложения,
  /// защищённое хранилище, Яндекс Облако, Проводник.
  factory AppServices.real() {
    final mobile = Platform.isAndroid || Platform.isIOS;
    LibFfmpegRunner? libRunner;
    return AppServices(
      prepareRuntime: (log) => AppRuntime.prepare(log: log),
      locateFfmpeg: (log) async {
        if (mobile) {
          // Пакет ffmpeg_kit_flutter_new собран в варианте full-gpl:
          // libass внутри.
          return const FfmpegInfo(
            ffmpegPath: 'встроенный в приложение',
            ffprobePath: 'встроенный в приложение',
            version: 'ffmpeg-kit full-gpl',
            hasLibass: true,
            source: 'bundled',
          );
        }
        return FfmpegLocator.locate(log: log);
      },
      ffmpegCandidates: () => mobile ? const [] : FfmpegLocator.candidates(),
      keyStore: (supportDir, log) =>
          createKeyStore(supportDir: supportDir, log: log),
      settingsStore: (supportDir, log) =>
          FileSettingsStore(p.join(supportDir, 'settings.json'), log: log),
      runner: (ffmpeg, runtime, log) async {
        if (mobile) {
          // Один экземпляр на всё приложение: шрифты регистрируются в
          // библиотеке один раз, без этого libass рисует пустоту.
          if (libRunner == null) {
            libRunner = LibFfmpegRunner(log: log);
            await libRunner!.registerFonts(runtime.fontsDir);
          }
          return libRunner!;
        }
        return ProcessFfmpegRunner(
          ffmpegPath: ffmpeg.ffmpegPath,
          ffprobePath: ffmpeg.ffprobePath,
          log: log,
        );
      },
      speechKit: (key) => SpeechKitClient(dio: newDio(), apiKey: key),
      translate: (key) => TranslateClient(dio: newDio(), apiKey: key),
      reveal: (path) => revealInFileManager(path),
      share: (paths) => SharePlus.instance
          .share(ShareParams(files: [for (final path in paths) XFile(path)])),
      sleep: (delay) => Future<void>.delayed(delay),
      appVersion: () async {
        final info = await PackageInfo.fromPlatform();
        return info.buildNumber.isEmpty
            ? info.version
            : '${info.version}+${info.buildNumber}';
      },
      osVersion: () =>
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      isMobile: mobile,
      debugStandAvailable:
          kDebugMode || Platform.environment['SUBTITLER_DEBUG'] == '1',
    );
  }

  /// Общие настройки сети. Без явных таймаутов зависший запрос подвесил бы
  /// весь прогон, и отменить его было бы нечем.
  static Dio newDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ));

  AppServices copyWith({
    Future<AppRuntime> Function(DebugLog log)? prepareRuntime,
    Future<FfmpegInfo?> Function(DebugLog log)? locateFfmpeg,
    List<String> Function()? ffmpegCandidates,
    KeyStore Function(String supportDir, DebugLog log)? keyStore,
    SettingsStore Function(String supportDir, DebugLog log)? settingsStore,
    Future<FfmpegRunner> Function(
            FfmpegInfo ffmpeg, AppRuntime runtime, DebugLog log)?
        runner,
    SpeechKitClient Function(String apiKey)? speechKit,
    TranslateClient Function(String apiKey)? translate,
    Future<bool> Function(String path)? reveal,
    Future<void> Function(List<String> paths)? share,
    Future<void> Function(Duration delay)? sleep,
    Future<String> Function()? appVersion,
    String Function()? osVersion,
    bool? isMobile,
    bool? debugStandAvailable,
  }) =>
      AppServices(
        prepareRuntime: prepareRuntime ?? this.prepareRuntime,
        locateFfmpeg: locateFfmpeg ?? this.locateFfmpeg,
        ffmpegCandidates: ffmpegCandidates ?? this.ffmpegCandidates,
        keyStore: keyStore ?? this.keyStore,
        settingsStore: settingsStore ?? this.settingsStore,
        runner: runner ?? this.runner,
        speechKit: speechKit ?? this.speechKit,
        translate: translate ?? this.translate,
        reveal: reveal ?? this.reveal,
        share: share ?? this.share,
        sleep: sleep ?? this.sleep,
        appVersion: appVersion ?? this.appVersion,
        osVersion: osVersion ?? this.osVersion,
        isMobile: isMobile ?? this.isMobile,
        debugStandAvailable: debugStandAvailable ?? this.debugStandAvailable,
      );
}
