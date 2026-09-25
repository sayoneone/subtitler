import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg/ffmpeg_locator.dart';
import '../core/ffmpeg/ffmpeg_runner.dart';
import '../core/languages.dart';
import '../core/logging.dart';
import '../core/models.dart';
import '../core/pipeline/burner.dart';
import '../core/pipeline/pipeline.dart';
import '../core/session_store.dart';
import '../core/srt.dart';
import 'debug_controller.dart';
import 'key_check.dart';
import 'key_store.dart';
import 'output_files.dart';
import 'runtime.dart';
import 'services.dart';
import 'settings.dart';
import 'user_error.dart';
import 'video_probe.dart';

/// Этап приложения — ровно один экран.
enum AppStage {
  /// «Подготовка…»: папки, ffmpeg, хранилище ключа.
  starting,

  /// Десктоп без ffmpeg или без libass, либо не создались папки
  /// приложения. Работать нельзя; [AppController.error] объясняет, что
  /// сделать, а в `details` — перебранные пути и версия.
  broken,

  /// Ключа нет (или хранилище не читается) — экран ввода ключа.
  needsKey,

  /// «Перетащите видео сюда».
  home,

  /// Идёт обработка: [AppController.progress], кнопка «Отмена».
  processing,

  /// Обработку остановил человек. «Открыть, что успели» доступно, если
  /// [AppController.canOpenPartial]; иначе только «На главный экран».
  cancelled,

  /// Обработка упала: [AppController.error] с кнопкой по смыслу.
  failed,

  /// Предпросмотр и правка; сохранение видео — внутри этого этапа
  /// ([AppController.saveStatus]).
  review,
}

/// Шаги обработки, как их видит человек.
enum ProcessingStep {
  /// Извлечение звука, поиск пауз, нарезка.
  preparingAudio,
  detectingLanguage,
  recognizing,
  translating,
}

extension ProcessingStepTitle on ProcessingStep {
  String get title => switch (this) {
        ProcessingStep.preparingAudio => 'Готовим звук',
        ProcessingStep.detectingLanguage => 'Определяем язык',
        ProcessingStep.recognizing => 'Распознаём речь',
        ProcessingStep.translating => 'Переводим на русский',
      };
}

/// Где сейчас обработка. [done]/[total] — реплики при распознавании и
/// пробные запросы при определении языка; 0/0 — счёта нет.
class ProcessingProgress {
  final ProcessingStep step;
  final int done;
  final int total;

  const ProcessingProgress(this.step, {this.done = 0, this.total = 0});

  /// «Распознаём речь: 4 из 13», «Готовим звук».
  String get label => step == ProcessingStep.recognizing && total > 0
      ? '${step.title}: $done из $total'
      : step.title;

  /// Доля выполненного для полосы прогресса; `null` — неизвестно.
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  @override
  bool operator ==(Object other) =>
      other is ProcessingProgress &&
      other.step == step &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(step, done, total);

  @override
  String toString() => label;
}

/// Ролик длиннее [AppController.longVideoThreshold]: ждём, согласится ли
/// человек на долгую и платную обработку (§5).
class LongVideoQuestion {
  final String videoPath;
  final Duration duration;

  const LongVideoQuestion({required this.videoPath, required this.duration});

  String get fileName => p.basename(videoPath);
}

/// Сохранение видео с субтитрами — режим этапа [AppStage.review].
enum SaveStatus {
  idle,

  /// Кодирование: [AppController.saveProgress] — доля длительности ролика.
  burning,

  /// Проверяем, что субтитры в кадре видны.
  verifying,

  /// Готово: [AppController.saveResult].
  saved,

  /// Не вышло: [AppController.saveError].
  failed,
}

/// Что и куда сохранено.
class SaveResult {
  final String videoPath;
  final String origSrtPath;
  final String ruSrtPath;

  /// Рядом с исходником писать нельзя — файлы (все или часть) лежат в
  /// папке приложения. Интерфейс показывает плашку с путём (§9).
  final bool inFallback;

  const SaveResult({
    required this.videoPath,
    required this.origSrtPath,
    required this.ruSrtPath,
    required this.inFallback,
  });

  String get fileName => p.basename(videoPath);
  String get dir => p.dirname(videoPath);
}

/// Пункт меню «Не тот язык?».
class LanguageChoice {
  final String code;

  /// По-русски, из таблицы языков: «узбекский».
  final String name;

  /// На этом языке ролик уже распознан целиком (есть резервная копия):
  /// переключение бесплатное и мгновенное.
  final bool ready;

  /// Сколько реплик на этом языке уже оплачено пробами — их при смене
  /// языка повторно не распознаём.
  final int probedCues;

  /// Второй по оценке язык — его меню показывает первым.
  final bool isRunnerUp;

  const LanguageChoice({
    required this.code,
    required this.name,
    required this.ready,
    required this.probedCues,
    required this.isRunnerUp,
  });

  @override
  String toString() => '$code${ready ? ' (готово)' : ''}';
}

/// Ролик длиннее этого — сначала вопрос «Продолжить?» (§5).
const Duration kLongVideoThreshold = Duration(minutes: 15);

class _Job {
  bool cancelled = false;

  /// Сколько всего реплик в ролике, если известно: счёт «4 из 13» идёт от
  /// всех реплик, а не только от ещё не распознанных.
  int knownCues = 0;
}

/// Состояние пользовательского приложения: этап, обработка, правки,
/// сохранение. Экраны только читают его и вызывают методы.
///
/// Всё, что трогает внешний мир, приходит через [AppServices], поэтому
/// контроллер проверяется в тестах на подделках.
class AppController extends ChangeNotifier {
  final AppServices services;
  final DebugLog log;

  /// Через сколько после последней правки сессия и .srt пишутся на диск.
  final Duration editSaveDelay;

  final Duration longVideoThreshold;

  /// [openOnStart] — видео, с которым программу запустили: его перетащили
  /// на значок subtitler.exe или на ярлык. Открывается само, как только
  /// программа готова к работе, — сразу при старте или после ввода ключа.
  AppController({
    AppServices? services,
    DebugLog? log,
    this.editSaveDelay = const Duration(milliseconds: 700),
    this.longVideoThreshold = kLongVideoThreshold,
    String? openOnStart,
  })  : services = services ?? AppServices.real(),
        log = log ?? DebugLog.instance,
        _pendingVideo = openOnStart;

  /// Видео из командной строки, ещё не открытое: ждёт главного экрана.
  String? _pendingVideo;

  void _openPendingVideo() {
    final video = _pendingVideo;
    if (video == null || _stage != AppStage.home) return;
    _pendingVideo = null;
    log.info('Видео передано при запуске: $video');
    unawaited(openVideo(video));
  }

  // ---------------------------------------------------------------- этап

  AppStage _stage = AppStage.starting;
  AppStage get stage => _stage;

  /// Ошибка этапов [AppStage.failed] и [AppStage.broken].
  UserError? _error;
  UserError? get error => _error;

  /// Короткое сообщение, которое этап НЕ меняет: «это не видео», «в этом
  /// видео нет звука», сбой бесплатной смены языка. Показывать заголовок
  /// и подсказку; кнопку действия для него не рисовать.
  UserError? _notice;
  UserError? get notice => _notice;

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  // ------------------------------------------------------------ окружение

  AppRuntime? _runtime;
  AppRuntime? get runtime => _runtime;

  FfmpegInfo? _ffmpeg;
  FfmpegInfo? get ffmpeg => _ffmpeg;
  FfmpegRunner? _runner;

  List<String> _ffmpegCandidates = const [];

  /// Какие пути перебирал поиск ffmpeg.
  List<String> get ffmpegCandidates => _ffmpegCandidates;

  String? _appVersion;

  /// Версия приложения («0.1.1+1»); `null`, пока не прочитана.
  String? get appVersion => _appVersion;

  KeyStore? _keyStore;
  KeyStore? get keyStore => _keyStore;

  SettingsStore? _settingsStore;
  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;

  SessionStore? _sessionStore;

  bool get isMobile => services.isMobile;

  /// Пункт меню «Для разработчика → Отладочный стенд» виден.
  bool get debugStandAvailable => services.debugStandAvailable;

  /// Файл журнала этого запуска.
  String? get logFilePath => log.filePath;

  /// Сведения об ffmpeg для «Технических деталей» и «О программе».
  String get ffmpegReport {
    final info = _ffmpeg;
    final lines = <String>[
      if (info == null)
        'ffmpeg: не найден'
      else ...[
        'ffmpeg: ${info.ffmpegPath}',
        'Версия: ${info.version}',
        'libass: ${info.hasLibass ? 'есть' : 'нет'}',
      ],
      if (_ffmpegCandidates.isNotEmpty) ...[
        'Где искали:',
        for (final path in _ffmpegCandidates) '  $path',
      ],
    ];
    return lines.join('\n');
  }

  /// Последние строки журнала — ключ в них уже замаскирован.
  String recentLog({int lines = 40}) {
    final entries = log.entries;
    final from = entries.length > lines ? entries.length - lines : 0;
    return entries.sublist(from).join('\n');
  }

  // ----------------------------------------------------------------- ключ

  String? _apiKey;

  /// Проверенный ключ есть в памяти. Самого ключа интерфейс не видит.
  bool get hasKey => _apiKey != null;

  bool? _keyStorageWorks;

  /// Хранилище ключа прошло самопроверку на старте. `false` — ключ
  /// работает только до закрытия программы (честная плашка).
  bool? get keyStorageWorks => _keyStorageWorks;

  bool _keySaved = false;

  /// Ключ записан в хранилище и переживёт перезапуск.
  bool get keySaved => _keySaved;

  KeyCheckResult _keyCheck = KeyCheckResult.idle;
  KeyCheckResult get keyCheck => _keyCheck;

  bool _keyChecking = false;
  bool get isCheckingKey => _keyChecking;

  AppStage? _stageBeforeKeyChange;

  /// На экране ключа есть куда вернуться: ключ уже был, его меняют.
  bool get canCancelKeyChange =>
      _stage == AppStage.needsKey &&
      _apiKey != null &&
      _stageBeforeKeyChange != null;

  // ---------------------------------------------------------------- видео

  String? _videoPath;
  String? get videoPath => _videoPath;
  String? get videoName => _videoPath == null ? null : p.basename(_videoPath!);

  Session? _session;

  /// Сессия текущего видео. В [AppStage.review] — с правками; во время
  /// обработки появляется, как только определён язык.
  Session? get session => _session;

  /// Язык ролика (код распознавания), как только он определён.
  String? get language => _session?.lang;
  String? get languageTitle =>
      _session == null ? null : languageName(_session!.lang);

  /// `null` — язык выбрал человек или сессия записана до схемы 2.
  LanguageConfidence? get languageConfidence => _session?.langConfidence;
  String? get languageRunnerUp => _session?.langRunnerUp;

  Session? _partial;

  /// После отмены есть что открыть.
  bool get canOpenPartial =>
      _stage == AppStage.cancelled && _partial != null;

  LongVideoQuestion? _longVideoQuestion;
  LongVideoQuestion? get longVideoQuestion => _longVideoQuestion;

  bool _opening = false;

  // ------------------------------------------------------------ обработка

  _Job? _job;
  Future<void>? _jobFuture;

  ProcessingProgress? _progress;
  ProcessingProgress? get progress => _progress;

  static const List<ProcessingStep> _fullSteps = ProcessingStep.values;
  static const List<ProcessingStep> _switchSteps = [
    ProcessingStep.preparingAudio,
    ProcessingStep.recognizing,
    ProcessingStep.translating,
  ];
  List<ProcessingStep> _steps = _fullSteps;

  /// Шаги текущей обработки — для списка с галочками. При платной смене
  /// языка определения языка нет.
  List<ProcessingStep> get processingSteps => _steps;

  /// «Отмена» нажата, обработка останавливается (ждём текущий запрос).
  bool get cancelRequested => _job?.cancelled ?? false;

  /// Завершится, когда текущая обработка закончится (для тестов).
  @visibleForTesting
  Future<void> get jobDone => _jobFuture ?? Future<void>.value();

  // --------------------------------------------------------- смена языка

  Set<String> _backupLangs = {};
  bool _switching = false;

  // ----------------------------------------------------------- сохранение

  SaveStatus _saveStatus = SaveStatus.idle;
  SaveStatus get saveStatus => _saveStatus;

  double _saveProgress = 0;

  /// Доля от 0 до 1 во время [SaveStatus.burning] — от длительности ролика.
  double get saveProgress => _saveProgress;

  SaveResult? _saveResult;
  SaveResult? get saveResult => _saveResult;

  UserError? _saveError;
  UserError? get saveError => _saveError;

  bool get isSaving =>
      _saveStatus == SaveStatus.burning || _saveStatus == SaveStatus.verifying;

  SrtFiles? _srtFiles;

  /// Субтитры пришлось записать в папку приложения: рядом с видео нельзя.
  bool get outputInFallback =>
      (_saveResult?.inFallback ?? false) || (_srtFiles?.inFallback ?? false);

  /// Папка, где лежат субтитры (и видео после сохранения).
  String? get outputDir => _saveResult?.dir ?? _srtFiles?.names.dir;

  // ---------------------------------------------------------------- правки

  Timer? _editTimer;
  bool _dirty = false;
  Future<void> _writes = Future<void>.value();

  // --------------------------------------------------------------- общее

  bool _initStarted = false;
  bool _disposed = false;

  /// Что-то идёт: обработка, сохранение, смена языка, проверка ключа или
  /// файла. Ключ и видео в это время не меняются.
  bool get isBusy =>
      _job != null || isSaving || _opening || _keyChecking || _switching;

  /// Принимать ли сейчас видео (перетаскивание, «Выбрать файл»). Во время
  /// работы приём выключен: иначе результат одного видео записался бы под
  /// именем другого.
  bool get canOpenVideo =>
      _runner != null &&
      _apiKey != null &&
      !isBusy &&
      const {
        AppStage.home,
        AppStage.review,
        AppStage.cancelled,
        AppStage.failed,
      }.contains(_stage);

  /// Реплик на проверку: с пометками, кроме принудительной нарезки — она
  /// показывается одной плашкой на весь ролик, а не жёлтыми строками.
  int get reviewCount => _session == null
      ? 0
      : _session!.cues
          .where((c) => c.flags.any((f) => f != CueFlag.forcedSplit))
          .length;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _editTimer?.cancel();
    if (_dirty) unawaited(flush());
    super.dispose();
  }

  // ================================================================ старт

  /// Готовит всё и выбирает первый экран. Вызывается один раз.
  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    _stage = AppStage.starting;
    _notify();
    log.info('Запуск приложения');

    try {
      _runtime = await services.prepareRuntime(log);
    } catch (e) {
      log.error('Не удалось подготовить папки приложения: $e');
      _broken(UserError(
        title: 'Не удалось подготовить папки программы',
        hint: 'Проверьте, что на диске есть свободное место, и запустите '
            'программу ещё раз. Если не поможет — сохраните журнал и '
            'отправьте его разработчику.',
        details: log.mask('$e'),
      ));
      return;
    }
    final runtime = _runtime!;

    try {
      _appVersion = await services.appVersion();
    } catch (e) {
      log.warn('Не удалось узнать версию приложения: $e');
    }
    log.info('Subtitler ${_appVersion ?? '(версия неизвестна)'}; '
        'ОС: ${services.osVersion()}');

    _sessionStore = SessionStore(fallbackDir: runtime.supportDir);
    _settingsStore = services.settingsStore(runtime.supportDir, log);
    _settings = await _settingsStore!.load();
    log.info('Языки для автоопределения: '
        '${_settings.detectionCandidates.join(', ')}');

    _ffmpegCandidates = services.ffmpegCandidates();
    try {
      _ffmpeg = await services.locateFfmpeg(log);
    } catch (e) {
      log.error('Поиск ffmpeg упал: $e');
    }
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null || (!services.isMobile && !ffmpeg.hasLibass)) {
      _broken(UserError(
        title: ffmpeg == null
            ? 'Не найден компонент обработки видео'
            : 'Компонент обработки видео неполный',
        hint: 'Распакуйте архив заново целиком: все папки должны лежать '
            'рядом с subtitler.exe.',
        details: ffmpegReport,
      ));
      return;
    }
    try {
      _runner = await services.runner(ffmpeg, runtime, log);
    } catch (e) {
      log.error('Не удалось подготовить ffmpeg: $e');
      _broken(UserError(
        title: 'Не удалось запустить компонент обработки видео',
        hint: 'Распакуйте архив заново целиком и запустите программу ещё раз.',
        details: log.mask('$e\n$ffmpegReport'),
      ));
      return;
    }

    _keyStore = services.keyStore(runtime.supportDir, log);
    try {
      _keyStorageWorks = await _keyStore!.selfTest();
    } catch (e) {
      log.warn('Самопроверка хранилища ключа упала: $e');
      _keyStorageWorks = false;
    }
    log.info(_keyStorageWorks!
        ? 'Хранилище ключа работает: ${_keyStore!.description}'
        : 'Хранилище ключа недоступно (${_keyStore!.description}). '
            'Ключ придётся вводить при каждом запуске.');

    // Нечитаемое хранилище — это «ключа нет», а не падение (§4).
    String? stored;
    try {
      stored = await _keyStore!.read();
    } catch (e) {
      log.warn('Не удалось прочитать сохранённый ключ: $e');
    }
    final key = stored?.trim() ?? '';
    if (key.isNotEmpty) {
      log.redact(key);
      _apiKey = key;
      _keySaved = true;
      log.info('Ключ загружен из хранилища (${key.length} символов)');
      _stage = AppStage.home;
    } else {
      log.info('Ключ ещё не сохранён');
      _stage = AppStage.needsKey;
    }
    _notify();
    _openPendingVideo();
  }

  void _broken(UserError error) {
    _error = error;
    _stage = AppStage.broken;
    _notify();
  }

  // ================================================================= ключ

  /// Проверяет ключ переводом и распознаванием и только потом сохраняет.
  ///
  /// Неверный ключ рабочим не становится: пока обе проверки не прошли, он
  /// живёт только в локальной переменной, а прежний ключ (если меняли)
  /// продолжает работать. В журнале он замаскирован с первой же строки.
  /// Возвращает `true`, если ключ принят.
  Future<bool> submitKey(String value) async {
    if (_keyChecking || _job != null || isSaving) return false;
    if (_stage == AppStage.starting || _stage == AppStage.broken) return false;
    _keyChecking = true;
    _keyCheck = const KeyCheckResult(
        translate: CheckState.checking, stt: CheckState.checking);
    _notify();

    final key = value.trim();
    final KeyCheckResult result;
    try {
      result = await KeyChecker(
        translate: services.translate,
        speechKit: services.speechKit,
        log: log,
      ).check(key, onProgress: (r) {
        _keyCheck = r;
        _notify();
      });
    } finally {
      _keyChecking = false;
    }
    _keyCheck = result;
    if (!result.ok) {
      log.warn('Ключ не принят — прежний ключ не тронут');
      _notify();
      return false;
    }

    _apiKey = key;
    // Показать итог проверки НАДО до записи в хранилище: Связка ключей
    // macOS может ждать разрешения пользователя сколько угодно.
    _notify();
    try {
      await _keyStore!.write(key);
      _keySaved = true;
      log.info('Ключ сохранён: ${_keyStore!.description}');
    } catch (e) {
      _keySaved = false;
      log.warn('Ключ проверен, но сохранить его не удалось: $e. '
          'В этом запуске он работает, при следующем — введите заново.');
    }

    if (_stage == AppStage.needsKey) {
      final previous = _stageBeforeKeyChange;
      _stageBeforeKeyChange = null;
      if (previous == AppStage.failed && _videoPath != null) {
        // «Изменить ключ» из ошибки: с новым ключом продолжаем с того же
        // места, а не заставляем выбирать видео заново.
        unawaited(_startProcessing(_videoPath!));
        return true;
      }
      _stage = _returnStage(previous);
    }
    _notify();
    _openPendingVideo();
    return true;
  }

  /// Куда вернуться с экрана ключа: туда, откуда пришли, если там ещё есть
  /// что показывать.
  AppStage _returnStage(AppStage? previous) => switch (previous) {
        AppStage.review when _session != null => AppStage.review,
        AppStage.cancelled || AppStage.failed => previous!,
        _ => AppStage.home,
      };

  /// «Изменить ключ»: экран ключа, прежний ключ пока остаётся.
  void changeKey() {
    if (isBusy || _stage == AppStage.starting || _stage == AppStage.broken) {
      return;
    }
    if (_stage != AppStage.needsKey) _stageBeforeKeyChange = _stage;
    _keyCheck = KeyCheckResult.idle;
    _stage = AppStage.needsKey;
    _notify();
  }

  /// Передумал менять ключ — назад, откуда пришёл.
  void cancelKeyChange() {
    if (!canCancelKeyChange) return;
    final previous = _stageBeforeKeyChange!;
    _stageBeforeKeyChange = null;
    _keyCheck = KeyCheckResult.idle;
    _stage = _returnStage(previous);
    _notify();
  }

  /// «Удалить ключ» в настройках: из хранилища и из памяти.
  Future<void> forgetKey() async {
    if (isBusy || _stage == AppStage.starting || _stage == AppStage.broken) {
      return;
    }
    await flush();
    try {
      await _keyStore?.clear();
    } catch (e) {
      log.warn('Не удалось удалить ключ из хранилища: $e');
    }
    _apiKey = null;
    _keySaved = false;
    _keyCheck = KeyCheckResult.idle;
    _stageBeforeKeyChange = null;
    _resetVideo();
    _stage = AppStage.needsKey;
    log.info('Ключ удалён');
    _notify();
  }

  // ================================================================ видео

  /// Видео выбрано (перетащили или «Выбрать файл»): проверяем и сразу
  /// обрабатываем.
  ///
  /// Во время работы вызов игнорируется. Не видео, папка или видео без
  /// звука — [notice], этап не меняется. Ролик длиннее
  /// [longVideoThreshold] — [longVideoQuestion] и ожидание
  /// [confirmLongVideo]. Завершается, когда обработка закончена.
  Future<void> openVideo(String path) async {
    if (!canOpenVideo) {
      log.info('Видео сейчас не принимается (этап ${_stage.name}'
          '${isBusy ? ', идёт работа' : ''}): $path');
      return;
    }
    _opening = true;
    _notice = null;
    _longVideoQuestion = null;
    _notify();

    var start = false;
    try {
      await flush(); // правки прежнего видео — на диск
      log.info('Выбрано видео: $path');
      final probe = await probeVideo(_runner!, path);
      if (!probe.hasAudio) throw const NoAudioStreamException();
      final seconds = await _runner!.probeDuration(path);
      final duration = Duration(milliseconds: (seconds * 1000).round());
      log.info('Длительность ${seconds.toStringAsFixed(2)} с, размер '
          '${File(path).lengthSync()} байт');
      if (duration > longVideoThreshold &&
          !await _hasFinishedSession(path, seconds)) {
        log.info('Ролик длиннее ${longVideoThreshold.inMinutes} мин — '
            'ждём подтверждения');
        _longVideoQuestion =
            LongVideoQuestion(videoPath: path, duration: duration);
      } else {
        start = true;
      }
    } catch (e) {
      log.warn('Видео не принято: $e');
      _notice = describeError(e, mask: log.mask);
    } finally {
      _opening = false;
      _notify();
    }
    if (start) await _startProcessing(path);
  }

  /// «Продолжить» в вопросе о длинном ролике.
  Future<void> confirmLongVideo() async {
    final question = _longVideoQuestion;
    if (question == null || isBusy) return;
    _longVideoQuestion = null;
    await _startProcessing(question.videoPath);
  }

  /// «Отмена» в вопросе о длинном ролике.
  void declineLongVideo() {
    if (_longVideoQuestion == null) return;
    _longVideoQuestion = null;
    _notify();
  }

  Future<bool> _hasFinishedSession(String path, double seconds) async {
    final saved = await _sessionStore!.load(
      path,
      SourceFingerprint(
          sizeBytes: File(path).lengthSync(), durationSec: seconds),
    );
    return saved != null && _isComplete(saved);
  }

  /// Делать больше нечего: всё распознано и переведено. Реплика с текстом
  /// без перевода — незаконченная: обработку могли остановить перед
  /// переводом, и повторное открытие должно его доделать (перевод дёшев,
  /// распознавание уже оплаченных реплик ядро не повторяет).
  static bool _isComplete(Session session) => session.cues.every((c) =>
      c.status == CueStatus.empty ||
      (c.status == CueStatus.ok && c.ru.trim().isNotEmpty));

  /// Определить язык и обработать. Сохранённую сессию ядро отдаёт без
  /// проб; если в ней всё распознано — сразу в редактор, без запросов.
  Future<void> _startProcessing(String video) => _runJob(
        video,
        steps: _fullSteps,
        // Язык нового видео ещё неизвестен — прежний показывать нельзя.
        shown: null,
        body: (job, pipeline) async {
          final probe = await pipeline.detectLanguage(
            videoPath: video,
            candidates: _settings.detectionCandidates,
            previousLang: _settings.lastLanguage,
            onProgress: (p) => _onProgress(job, p),
            sleep: services.sleep,
            isCancelled: () => job.cancelled,
          );
          _session = probe.session;
          _notify(); // язык виден, как только определён
          if (probe.reusedSession && _isComplete(probe.session)) {
            log.info('Сессия уже готова — открываем без обработки');
            return probe.session;
          }
          job.knownCues = probe.session.cues.length;
          return pipeline.process(
            videoPath: video,
            lang: probe.session.lang,
            resumeFrom: probe.session,
            onProgress: (p) => _onProgress(job, p),
            sleep: services.sleep,
            isCancelled: () => job.cancelled,
          );
        },
      );

  /// [shown] — сессия, которую показывать во время работы (язык в шапке),
  /// пока ядро не вернуло настоящую.
  Future<void> _runJob(
    String video, {
    required List<ProcessingStep> steps,
    required Session? shown,
    required Future<Session> Function(_Job job, Pipeline pipeline) body,
  }) {
    final job = _Job();
    _job = job;
    final future = _execute(job, video, steps, shown, body);
    _jobFuture = future;
    return future;
  }

  Future<void> _execute(
    _Job job,
    String video,
    List<ProcessingStep> steps,
    Session? shown,
    Future<Session> Function(_Job job, Pipeline pipeline) body,
  ) async {
    _videoPath = video;
    _session = shown;
    _backupLangs = {};
    _srtFiles = null;
    _stage = AppStage.processing;
    _steps = steps;
    _progress = ProcessingProgress(steps.first);
    _error = null;
    _notice = null;
    _partial = null;
    _longVideoQuestion = null;
    _resetSave();
    _notify();

    final pipeline = Pipeline(
      runner: _runner!,
      stt: services.speechKit(_apiKey!),
      translate: services.translate(_apiKey!),
      store: _sessionStore!,
      workDir: _runtime!.workDirFor(video),
      log: log,
    );
    try {
      final result = await body(job, pipeline);
      _session = result;
      if (job.cancelled) {
        log.info('Обработка остановлена — открыть можно то, что успели');
        _partial = result;
        _stage = AppStage.cancelled;
      } else {
        await _rememberLanguage(result.lang);
        await _enterReview(result);
      }
    } on PipelineCancelledException {
      log.info('Обработка остановлена до распознавания — открывать нечего');
      _stage = AppStage.cancelled;
    } catch (e, stack) {
      log.error('Обработка прервана: $e');
      log.debug('$stack');
      _error = describeError(e, mask: log.mask);
      _stage = AppStage.failed;
    } finally {
      if (identical(_job, job)) _job = null;
      _notify();
    }
  }

  void _onProgress(_Job job, PipelineProgress p) {
    if (!identical(_job, job)) return;
    final step = switch (p.stage) {
      PipelineStage.extractingAudio ||
      PipelineStage.detectingSilence =>
        ProcessingStep.preparingAudio,
      PipelineStage.detectingLanguage => ProcessingStep.detectingLanguage,
      PipelineStage.recognizing => ProcessingStep.recognizing,
      PipelineStage.translating => ProcessingStep.translating,
      PipelineStage.done => null,
    };
    if (step == null) return;
    var done = p.done;
    var total = p.total;
    // Ядро считает только то, что осталось распознать; человеку понятнее
    // «6 из 13», чем «4 из 11», когда две реплики ушли на пробы.
    if (step == ProcessingStep.recognizing && job.knownCues > total) {
      done += job.knownCues - total;
      total = job.knownCues;
    }
    _progress = ProcessingProgress(step, done: done, total: total);
    _notify();
  }

  /// «Отмена»: работает на любом шаге. Текущий запрос дожидается ответа,
  /// новых платных запросов нет.
  void cancel() {
    final job = _job;
    if (job == null || job.cancelled) return;
    job.cancelled = true;
    log.warn('Запрошена отмена');
    _notify();
  }

  /// «Открыть, что успели» после отмены.
  Future<void> openPartial() async {
    final partial = _partial;
    if (!canOpenPartial || partial == null) return;
    await _enterReview(partial);
    _notify();
  }

  /// «Повторить» после ошибки обработки: продолжает с сохранённого.
  Future<void> retry() async {
    final video = _videoPath;
    if (_stage != AppStage.failed || video == null || isBusy) return;
    if (_apiKey == null) {
      changeKey();
      return;
    }
    await _startProcessing(video);
  }

  /// «На главный экран», «Другое видео».
  Future<void> goHome() async {
    if (isBusy) return;
    if (_stage == AppStage.starting || _stage == AppStage.broken) return;
    await flush();
    _resetVideo();
    _stage = _apiKey == null ? AppStage.needsKey : AppStage.home;
    _notify();
  }

  void _resetVideo() {
    _editTimer?.cancel();
    _editTimer = null;
    _dirty = false;
    _videoPath = null;
    _session = null;
    _partial = null;
    _progress = null;
    _error = null;
    _notice = null;
    _longVideoQuestion = null;
    _backupLangs = {};
    _srtFiles = null;
    _resetSave();
  }

  void _resetSave() {
    _saveStatus = SaveStatus.idle;
    _saveProgress = 0;
    _saveResult = null;
    _saveError = null;
  }

  Future<void> _enterReview(Session session) async {
    _session = session;
    _partial = null;
    _stage = AppStage.review;
    _resetSave();
    await _refreshBackups();
    await _writeSrtsQuietly(_videoFor(session), session);
  }

  /// Куда писать сессию, .srt и резервные копии: путь открытого видео, а
  /// не записанный в сессии. Видео могли перенести вместе с сессией
  /// (скопировали папку дела, флешка получила другую букву) — тогда в
  /// JSON прежний путь, и запись ушла бы в чужую копию вещдока.
  String _videoFor(Session session) => _videoPath ?? session.videoPath;

  Future<void> _refreshBackups() async {
    final session = _session;
    if (session == null) return;
    try {
      _backupLangs = await _sessionStore!
          .backupLanguages(_videoFor(session), session.fingerprint);
    } catch (e) {
      log.warn('Не удалось проверить резервные копии: $e');
      _backupLangs = {};
    }
  }

  Future<void> _rememberLanguage(String lang) async {
    if (_settings.lastLanguage == lang) return;
    _settings = _settings.copyWith(lastLanguage: lang);
    await _settingsStore?.save(_settings);
  }

  // ================================================================ язык

  /// Меню «Не тот язык?»: второй язык первым, затем остальные языки из
  /// настроек, затем языки, на которых ролик уже распознан.
  List<LanguageChoice> get languageChoices {
    final session = _session;
    if (session == null) return const [];
    final codes = <String>[];
    void add(String? code) {
      if (code == null || code == session.lang) return;
      if (languageByCode(code) == null || codes.contains(code)) return;
      codes.add(code);
    }

    add(session.langRunnerUp);
    _settings.detectionCandidates.forEach(add);
    kLanguageCodes.where(_backupLangs.contains).forEach(add);
    return [for (final code in codes) _choice(session, code)];
  }

  /// «Другой язык…»: все языки распознавания, кроме текущего.
  List<LanguageChoice> get allLanguageChoices {
    final session = _session;
    if (session == null) return const [];
    return [
      for (final code in kLanguageCodes)
        if (code != session.lang) _choice(session, code),
    ];
  }

  LanguageChoice _choice(Session session, String code) => LanguageChoice(
        code: code,
        name: languageName(code),
        ready: _backupLangs.contains(code),
        probedCues: session.probeTexts[code]?.length ?? 0,
        isRunnerUp: code == session.langRunnerUp,
      );

  /// «Не тот язык?» → язык [lang]. Если ролик на нём уже распознан —
  /// бесплатно и сразу (резервная копия). Иначе — платная обработка на
  /// этапе [AppStage.processing]; текущий вариант с правками уходит в
  /// резервную копию, и к нему можно вернуться бесплатно.
  Future<void> switchLanguage(String lang) async {
    final video = _videoPath;
    // Копии ищутся и пишутся по пути открытого видео (см. [_videoFor]).
    final current = _session?.copyWith(videoPath: video);
    if (_stage != AppStage.review || current == null || video == null) return;
    if (isBusy || lang == current.lang || languageByCode(lang) == null) return;

    _switching = true;
    _notice = null;
    _notify();
    Session? restored;
    try {
      await flush();
      restored = await _sessionStore!.swapWithBackup(current, lang);
      if (restored != null) {
        log.info('Язык: ${current.lang} → $lang из резервной копии, '
            'без запросов');
        await _rememberLanguage(lang);
        await _enterReview(restored);
      }
    } catch (e) {
      log.error('Смена языка не удалась: $e');
      _notice = describeError(e, mask: log.mask);
      return;
    } finally {
      _switching = false;
      _notify();
    }
    if (restored != null) return;
    if (_apiKey == null) {
      changeKey();
      return;
    }

    log.info('Язык: ${current.lang} → $lang — распознаём заново');
    await _runJob(
      video,
      steps: _switchSteps,
      // В шапке — уже новый язык: его и распознаём. Эта сессия только для
      // показа; на диск ядро пишет свою.
      shown: current.copyWith(
          lang: lang, langConfidence: null, langRunnerUp: current.lang),
      body: (job, pipeline) {
        job.knownCues = current.cues.length;
        return pipeline.process(
          videoPath: video,
          lang: lang,
          resumeFrom: current,
          onProgress: (p) => _onProgress(job, p),
          sleep: services.sleep,
          isCancelled: () => job.cancelled,
        );
      },
    );
  }

  /// «Языки ваших записей» в настройках. Пустой набор не принимается:
  /// выбирать язык было бы не из чего.
  Future<void> setDetectionCandidates(List<String> codes) async {
    final valid = <String>[];
    for (final code in codes) {
      if (languageByCode(code) != null && !valid.contains(code)) {
        valid.add(code);
      }
    }
    if (valid.isEmpty) return;
    _settings = _settings.copyWith(detectionCandidates: List.unmodifiable(valid));
    log.info('Языки для автоопределения: ${valid.join(', ')}');
    _notify();
    await _settingsStore?.save(_settings);
  }

  /// Чип языка в настройках: включить или выключить. Последний язык не
  /// выключается.
  Future<void> toggleDetectionCandidate(String code) {
    final current = _settings.detectionCandidates;
    return setDetectionCandidates(current.contains(code)
        ? current.where((c) => c != code).toList()
        : [...current, code]);
  }

  // ================================================================ правки

  /// Правка перевода реплики [cueIndex]. Видна в кадре сразу; на диск
  /// (сессия и оба .srt) уходит через [editSaveDelay] после последней
  /// правки.
  ///
  /// Реплика «речи нет» (`empty`) с вписанным текстом становится `ok`:
  /// предпросмотр такие реплики скрывает, а вшивание берёт любой непустой
  /// текст — без смены статуса человек не увидел бы в кадре то, что
  /// окажется в готовом видео. Обратно (текст стёрли) статус не меняется.
  void updateTranslation(int cueIndex, String text) {
    final session = _session;
    if (_stage != AppStage.review || session == null) return;
    if (isSaving || _switching) return;
    final position = session.cues.indexWhere((c) => c.index == cueIndex);
    if (position < 0) return;
    final cues = [...session.cues];
    cues[position] = _edited(cues[position], text);
    _session = session.copyWith(cues: cues);
    if (_saveStatus == SaveStatus.saved || _saveStatus == SaveStatus.failed) {
      // Готовый файл больше не отражает правки — сохранять заново.
      _resetSave();
    }
    _dirty = true;
    _editTimer?.cancel();
    _editTimer = Timer(editSaveDelay, () => unawaited(flush()));
    _notify();
  }

  static Cue _edited(Cue cue, String text) {
    final filled = text.trim().isNotEmpty;
    final status =
        cue.status == CueStatus.empty && filled ? CueStatus.ok : cue.status;
    // «Перевод не получен» после правки уже неправда; если перевод снова
    // стёрли при непустом оригинале — снова правда.
    final flags = {...cue.flags}..remove(CueFlag.translateFailed);
    if (!filled && cue.orig.trim().isNotEmpty) {
      flags.add(CueFlag.translateFailed);
    }
    return cue.copyWith(ru: text, status: status, flags: flags);
  }

  /// Дописывает на диск правки, которые ещё ждут своей задержки, и ждёт
  /// уже начатые записи. Вызывать перед закрытием окна.
  Future<void> flush() {
    _editTimer?.cancel();
    _editTimer = null;
    final session = _session;
    if (_dirty && session != null) {
      _dirty = false;
      final video = _videoFor(session);
      _writes = _writes.then((_) => _writeEdits(video, session));
    }
    return _writes;
  }

  Future<void> _writeEdits(String video, Session session) async {
    try {
      await _sessionStore!.save(session.copyWith(videoPath: video));
    } catch (e) {
      log.warn('Не удалось записать сессию: $e');
    }
    await _writeSrtsQuietly(video, session);
  }

  OutputFiles _outputsFor(String video) => OutputFiles(
        videoPath: video,
        fallbackRoot: _runtime!.outputDir,
        log: log,
      );

  Future<void> _writeSrtsQuietly(String video, Session session) async {
    try {
      _srtFiles = await _outputsFor(video).writeSrts(session.cues);
    } catch (e) {
      // Не повод останавливать работу: при сохранении видео запись
      // повторится, и тогда человек увидит понятную ошибку.
      log.warn('Не удалось записать субтитры: $e');
    }
  }

  // ============================================================ сохранение

  /// «Сохранить видео с субтитрами».
  ///
  /// Сначала дописываются свежие правки. Оба .srt — рядом с видео (или в
  /// папке приложения, если там нельзя). SRT для вшивания — в рабочей
  /// папке: на папке только для чтения вшивание иначе падало. Видео
  /// кодируется во временный `<имя>_ru.partial.mp4`, проверяется, что
  /// субтитры в кадре видны, и только потом встаёт на место
  /// `<имя>_ru.mp4`. При провале проверки временный файл удаляется.
  Future<void> save() async {
    final video = _videoPath;
    if (_stage != AppStage.review || _session == null || video == null) return;
    if (isSaving || _switching) return;
    _resetSave();
    _saveStatus = SaveStatus.burning;
    _notify();

    String? partial;
    try {
      await flush(); // иначе в файлах рядом с видео — текст до правки
      final session = _session!;
      final checkAt = visibilityCheckPoint(session.cues);
      if (checkAt == null) throw const NothingToBurnException();

      final outputs = _outputsFor(video);
      final srt = await outputs.writeSrts(session.cues);
      _srtFiles = srt;

      final workDir = _runtime!.workDirFor(video);
      Directory(workDir).createSync(recursive: true);
      final burnSrt = p.join(workDir, 'burn_ru.srt');
      await File(burnSrt)
          .writeAsString(buildSrt(session.cues, field: SrtField.ru), flush: true);

      var names = srt.names;
      var inFallback = srt.inFallback;
      if (!outputs.canReplace(names.video)) {
        names = outputs.fallback;
        inFallback = true;
        Directory(names.dir).createSync(recursive: true);
        if (!outputs.canReplace(names.video)) {
          throw FileSystemException(
              'Видео записать некуда', names.video);
        }
        log.warn('Видео рядом с исходником записать нельзя — '
            'сохраняем в ${names.dir}');
      }
      partial = names.partialVideo;
      deleteQuietly(partial, log: log);

      final seconds = session.fingerprint.durationSec;
      final burner = SubtitleBurner(_runner!);
      await burner.burn(
        input: video,
        srtPath: burnSrt,
        fontsDir: _runtime!.fontsDir,
        output: partial,
        onProgress: (position) {
          if (seconds <= 0) return;
          _saveProgress = (position / seconds).clamp(0.0, 1.0);
          _notify();
        },
      );

      _saveStatus = SaveStatus.verifying;
      _saveProgress = 1;
      _notify();
      final check = await burner.checkVisibility(
          original: video, burned: partial, atSeconds: checkAt);
      if (!check.visible) throw SubtitlesInvisibleException(check);
      log.info('Субтитры в кадре видны: ${check.describe()}');

      outputs.replace(partial, names.video);
      partial = null;
      _saveResult = SaveResult(
        videoPath: names.video,
        origSrtPath: srt.names.origSrt,
        ruSrtPath: srt.names.ruSrt,
        inFallback: inFallback,
      );
      _saveStatus = SaveStatus.saved;
      log.info('Готово: ${names.video}');
    } catch (e, stack) {
      log.error('Сохранение не удалось: $e');
      log.debug('$stack');
      _saveError = describeError(e, mask: log.mask);
      _saveStatus = SaveStatus.failed;
    } finally {
      if (partial != null) deleteQuietly(partial, log: log);
      _notify();
    }
  }

  /// «Открыть папку» (десктоп) или «Поделиться» (Android: видео и оба .srt).
  Future<void> revealOutput() async {
    final result = _saveResult;
    if (result == null) return;
    if (services.isMobile) {
      await services.share(
          [result.videoPath, result.origSrtPath, result.ruSrtPath]);
    } else {
      await services.reveal(result.videoPath);
    }
  }

  /// Показать любой файл: плашка «файлы в папке приложения», журнал.
  Future<void> showInFolder(String path) async {
    if (services.isMobile) {
      await services.share([path]);
    } else {
      await services.reveal(path);
    }
  }

  /// «Сохранить журнал…»: весь журнал этого запуска в файл [to] (по
  /// умолчанию — в папку приложения). Возвращает путь.
  Future<String> exportLog({String? to}) async {
    final dir = _runtime?.supportDir ?? Directory.systemTemp.path;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final path = to ?? p.join(dir, 'subtitler-log-$stamp.txt');
    await File(path).writeAsString(log.asText(), flush: true);
    log.info('Журнал сохранён: $path');
    return path;
  }

  /// Отладочный стенд с теми же папками, ffmpeg и хранилищем: стенд не
  /// должен повторно готовить папки — это переоткрыло бы журнал с нуля.
  DebugController debugStand() => DebugController(
        runtime: _runtime,
        ffmpeg: _ffmpeg,
        keyStore: _keyStore,
        log: log,
      );

  // ================================================================ тесты

  /// Забывает правки, которые ещё ждут записи. Тесту, который удаляет свою
  /// временную папку, не нужна запись после удаления — она создала бы
  /// папку заново.
  @visibleForTesting
  void debugDiscardPendingEdits() {
    _editTimer?.cancel();
    _editTimer = null;
    _dirty = false;
  }

  /// Выставляет состояние напрямую — для виджет-тестов экранов, которым
  /// не нужна настоящая обработка. Переданное поле заменяет текущее.
  @visibleForTesting
  void debugEmulate({
    AppStage? stage,
    String? videoPath,
    Session? session,
    Session? partial,
    ProcessingProgress? progress,
    List<ProcessingStep>? processingSteps,
    UserError? error,
    UserError? notice,
    LongVideoQuestion? longVideoQuestion,
    SaveStatus? saveStatus,
    double? saveProgress,
    SaveResult? saveResult,
    UserError? saveError,
    KeyCheckResult? keyCheck,
    Set<String>? backupLanguages,
    bool? keyStorageWorks,
    bool? hasKey,
  }) {
    if (stage != null) _stage = stage;
    if (session != null) {
      _session = session;
      _videoPath ??= session.videoPath;
    }
    if (videoPath != null) _videoPath = videoPath;
    if (partial != null) _partial = partial;
    if (progress != null) _progress = progress;
    if (processingSteps != null) _steps = processingSteps;
    if (error != null) _error = error;
    if (notice != null) _notice = notice;
    if (longVideoQuestion != null) _longVideoQuestion = longVideoQuestion;
    if (saveStatus != null) _saveStatus = saveStatus;
    if (saveProgress != null) _saveProgress = saveProgress;
    if (saveResult != null) _saveResult = saveResult;
    if (saveError != null) _saveError = saveError;
    if (keyCheck != null) _keyCheck = keyCheck;
    if (backupLanguages != null) _backupLangs = {...backupLanguages};
    if (keyStorageWorks != null) _keyStorageWorks = keyStorageWorks;
    if (hasKey != null) _apiKey = hasKey ? 'эмуляция-ключа' : null;
    _notify();
  }
}
