/// Контроллер приложения на подделках — для тестов контроллера и экранов.
///
/// ```dart
/// final h = makeTestController();          // ключ уже «сохранён»
/// await h.controller.init();               // → AppStage.home
/// h.controller.debugEmulate(stage: AppStage.review, session: sampleSession());
/// ...
/// await h.dispose();
/// ```
///
/// Всё, что `init()` трогает, живёт в памяти (ключ, настройки, версия,
/// поиск ffmpeg), поэтому в `testWidgets` он завершается без
/// `tester.runAsync`. Настоящие диск и ffmpeg нужны только обработке и
/// сохранению — это тесты контроллера, а не экранов.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/runtime.dart';
import 'package:subtitler/app/services.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_locator.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';

import 'fakes.dart';
import 'media.dart';

/// Выдуманный ключ: настоящего у тестов нет и быть не должно.
const String kTestApiKey = 'AQVN-vydumannyj-testovyj-klyuch-0001';

/// ffmpeg «найден, libass есть» — на самом деле это SUBTITLER_FFMPEG.
final FfmpegInfo kTestFfmpeg = FfmpegInfo(
  ffmpegPath: testRunner.ffmpegPath,
  ffprobePath: testRunner.ffprobePath,
  version: 'ffmpeg (тестовый)',
  hasLibass: true,
  source: 'test',
);

class AppHarness {
  final Directory root;
  final bool _ownsRoot;
  final AppRuntime runtime;
  final MemoryKeyStore keyStore;
  final SettingsStore settingsStore;
  final RecordingRunner runner;
  final DebugLog log;

  /// Распознавание и перевод, которые получит контроллер. Можно заменить
  /// после создания: фабрика берёт текущее значение при каждом вызове.
  SpeechKitClient stt;
  TranslateClient translate;

  /// Какие ключи контроллер отдавал фабрикам клиентов.
  final List<String> keysUsed = [];

  /// Что контроллер просил показать в Проводнике.
  final List<String> revealed = [];

  /// Что контроллер отдавал в «Поделиться».
  final List<List<String>> shared = [];

  late final AppController controller;

  AppHarness._({
    required this.root,
    required this._ownsRoot,
    required this.runtime,
    required this.keyStore,
    required this.settingsStore,
    required this.runner,
    required this.log,
    required this.stt,
    required this.translate,
  });

  /// Тестовое видео, скопированное под новым именем в папку [folder]
  /// внутри корня: рядом с ним ещё нет ни сессии, ни субтитров.
  String copyVideo(String source, {String folder = 'videos', String? name}) {
    final dir = Directory(p.join(root.path, folder))
      ..createSync(recursive: true);
    final target = p.join(dir.path, name ?? 'clip${_copies++}.mp4');
    File(source).copySync(target);
    return target;
  }

  int _copies = 0;

  Future<void> dispose() async {
    controller.dispose();
    if (_ownsRoot) {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Файл мог держать ещё не закрытый процесс — пусть остаётся во
        // временной папке, тест от этого не ломается.
      }
    }
  }
}

/// Контроллер на подделках.
///
/// [storedKey] — ключ, «сохранённый» в хранилище с прошлого запуска
/// (`null` — ключа нет, `init()` приведёт на [AppStage.needsKey]).
/// [ffmpeg] `null` — ffmpeg «не найден» ([AppStage.broken]).
/// [root] — общая папка для имитации перезапуска: второй контроллер с тем
/// же [root] видит сессии, настройки ([persistentSettings]) и рабочие
/// файлы первого.
AppHarness makeTestController({
  String? storedKey = kTestApiKey,
  SpeechKitClient? stt,
  TranslateClient? translate,
  FfmpegInfo? ffmpeg,
  bool noFfmpeg = false,
  bool isMobile = false,
  AppSettings settings = const AppSettings(),
  bool persistentSettings = false,
  Object? runtimeError,
  Directory? root,
  Duration editSaveDelay = const Duration(hours: 1),
  Duration longVideoThreshold = kLongVideoThreshold,
}) {
  final dir = root ?? Directory.systemTemp.createTempSync('app_harness_');
  final support = p.join(dir.path, 'support');
  final runtime = AppRuntime(
    supportDir: support,
    fontsDir: p.join(support, 'fonts'),
    workDir: p.join(dir.path, 'cache', 'work'),
    outputDir: p.join(dir.path, 'cache', 'output'),
  );
  for (final path in [runtime.fontsDir, runtime.workDir]) {
    Directory(path).createSync(recursive: true);
  }
  // Тот же шрифт, что приложение выкладывает для libass.
  final font = File(p.join(runtime.fontsDir, 'NotoSans-Regular.ttf'));
  if (!font.existsSync()) {
    File('assets/fonts/NotoSans-Regular.ttf').copySync(font.path);
  }

  final log = DebugLog();
  final keyStore = MemoryKeyStore(storedKey);
  final settingsStore = persistentSettings
      ? FileSettingsStore(p.join(support, 'settings.json'), log: log)
      : MemorySettingsStore(settings);
  final harness = AppHarness._(
    root: dir,
    ownsRoot: root == null,
    runtime: runtime,
    keyStore: keyStore,
    settingsStore: settingsStore,
    runner: RecordingRunner(testRunner),
    log: log,
    stt: stt ?? FakeStt(const []),
    translate: translate ?? FakeTranslate(),
  );

  final services = AppServices(
    prepareRuntime: (_) async {
      if (runtimeError != null) throw runtimeError;
      return runtime;
    },
    locateFfmpeg: (_) async => noFfmpeg ? null : (ffmpeg ?? kTestFfmpeg),
    ffmpegCandidates: () => [
      p.join(dir.path, 'app', 'tools', 'ffmpeg', 'ffmpeg.exe'),
      'ffmpeg',
    ],
    keyStore: (_, _) => keyStore,
    settingsStore: (_, _) => settingsStore,
    runner: (_, _, _) async => harness.runner,
    speechKit: (key) {
      harness.keysUsed.add(key);
      return harness.stt;
    },
    translate: (key) {
      harness.keysUsed.add(key);
      return harness.translate;
    },
    reveal: (path) async {
      harness.revealed.add(path);
      return true;
    },
    share: (paths) async => harness.shared.add(paths),
    sleep: (_) async {},
    appVersion: () async => '0.0.0-test',
    osVersion: () => 'тестовая ОС 1.0',
    isMobile: isMobile,
  );

  harness.controller = AppController(
    services: services,
    log: log,
    editSaveDelay: editSaveDelay,
    longVideoThreshold: longVideoThreshold,
  );
  return harness;
}

/// Сессия для экранов: реплики всех видов — обычная, с зацикливанием,
/// нераспознанная, без перевода, «речи нет». Тексты выдуманные.
Session sampleSession({
  String videoPath = '/видео/дело 1/clip.mp4',
  String lang = 'tr-TR',
  LanguageConfidence? confidence = LanguageConfidence.high,
  String? runnerUp = 'uz-UZ',
  bool forcedSplit = false,
}) {
  Set<CueFlag> flags(Set<CueFlag> own) =>
      {...own, if (forcedSplit) CueFlag.forcedSplit};
  return Session(
    videoPath: videoPath,
    fingerprint: const SourceFingerprint(sizeBytes: 1000, durationSec: 30),
    lang: lang,
    langConfidence: confidence,
    langRunnerUp: runnerUp,
    probeTexts: {
      'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz'},
      'uz-UZ': {1: 'ertaga ertalab bozorga boramiz'},
    },
    silenceThreshold: '-30dB',
    forcedSplit: forcedSplit,
    cues: [
      Cue(
        index: 1,
        range: const TimeRange(0.5, 3.2),
        orig: 'yarın sabah erkenden çarşıya gideceğiz',
        ru: 'завтра рано утром пойдём на рынок',
        status: CueStatus.ok,
        flags: flags(const {}),
      ),
      Cue(
        index: 2,
        range: const TimeRange(4.0, 6.0),
        orig: 'tamam tamam tamam tamam',
        ru: 'ладно ладно ладно ладно',
        status: CueStatus.ok,
        flags: flags(const {CueFlag.repeatLoop}),
      ),
      Cue(
        index: 3,
        range: const TimeRange(7.0, 9.5),
        orig: '',
        ru: '',
        status: CueStatus.failed,
        flags: flags(const {CueFlag.translateFailed}),
      ),
      Cue(
        index: 4,
        range: const TimeRange(10.0, 12.0),
        orig: 'akşam eve geç geleceğim',
        ru: '',
        status: CueStatus.ok,
        flags: flags(const {CueFlag.translateFailed}),
      ),
      Cue(
        index: 5,
        range: const TimeRange(13.0, 14.0),
        orig: '',
        ru: '',
        status: CueStatus.empty,
        flags: flags(const {}),
      ),
    ],
  );
}
