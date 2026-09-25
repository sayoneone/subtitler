import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/cloud/speechkit_client.dart';
import '../core/cloud/translate_client.dart';
import '../core/ffmpeg/ffmpeg_locator.dart';
import '../core/ffmpeg/ffmpeg_runner.dart';
import '../core/ffmpeg/lib_runner.dart';
import '../core/ffmpeg/process_runner.dart';
import '../core/languages.dart';
import '../core/logging.dart';
import '../core/models.dart';
import '../core/pipeline/burner.dart';
import '../core/pipeline/language_detector.dart';
import '../core/pipeline/pipeline.dart';
import '../core/session_store.dart';
import '../core/srt.dart';
import 'key_check.dart';
import 'key_store.dart';
import 'reveal.dart';
import 'runtime.dart';
import 'services.dart';

export 'key_check.dart' show CheckState;

/// Состояние отладочного стенда. Одна модель на весь экран — этого хватает,
/// а лишние слои только мешают отлаживать.
class DebugController extends ChangeNotifier {
  final DebugLog log;

  KeyStore? _keyStore;

  /// Стенд, открытый из приложения, получает уже готовые папки, ffmpeg и
  /// хранилище ключа. Повторный AppRuntime.prepare переоткрыл бы журнал
  /// с нуля (и отложил бы журнал запуска как «прошлый») и заново
  /// распаковал шрифт.
  DebugController({
    this.runtime,
    this.ffmpeg,
    this._keyStore,
    DebugLog? log,
  }) : log = log ?? DebugLog.instance;

  /// Удалось ли вообще пользоваться хранилищем ключа.
  bool? storageWorks;

  /// Где именно лежит ключ — показываем пользователю.
  String storageDescription = '';

  AppRuntime? runtime;
  FfmpegInfo? ffmpeg;
  String ffmpegOverride = '';

  String apiKey = '';
  CheckState sttCheck = CheckState.unknown;
  CheckState translateCheck = CheckState.unknown;
  String? keyError;

  String? videoPath;
  String? videoSummary;
  String lang = 'tr-TR';

  Session? session;
  PipelineProgress? progress;
  String? burnedPath;
  LanguageVerdict? languageVerdict;
  Timer? _saveDebounce;

  /// Язык подтверждён — определился сам или его выбрал человек.
  bool languageConfirmed = false;

  /// Определение не дало уверенного ответа: ждём выбора человека.
  bool awaitingLanguageChoice = false;

  /// Человек раскрыл ручной выбор языка (в обычном ходе он не нужен).
  bool manualLanguage = false;

  /// Языки, среди которых идёт автоопределение. Каждый добавленный язык —
  /// это лишние платные запросы и меньше шансов на уверенный ответ,
  /// поэтому набор короткий и настраиваемый.
  final Set<String> detectionCandidates = {...kDefaultDetectionCandidates};

  void toggleCandidate(String code) {
    if (detectionCandidates.contains(code)) {
      if (detectionCandidates.length > 1) detectionCandidates.remove(code);
    } else {
      detectionCandidates.add(code);
    }
    notifyListeners();
  }

  bool busy = false;
  bool _cancelRequested = false;
  String? lastError;

  bool get canRun =>
      !busy && videoPath != null && apiKey.isNotEmpty && ffmpeg != null;

  bool get canBurn =>
      !busy &&
      runtime != null && // шрифт для libass лежит в папке приложения
      session != null &&
      session!.cues.any((c) => c.ru.trim().isNotEmpty) &&
      (ffmpeg?.hasLibass ?? false);

  Future<void> init() async {
    log.info(runtime == null
        ? 'Запуск приложения (отладочный стенд)'
        : 'Открыт отладочный стенд');
    if (runtime == null) {
      try {
        runtime = await AppRuntime.prepare(log: log);
      } catch (e) {
        log.error('Не удалось подготовить папки приложения: $e');
      }
    }
    if (ffmpeg == null || isMobile) {
      await detectFfmpeg();
    } else {
      notifyListeners();
    }
    _keyStore ??= createKeyStore(
      supportDir: runtime?.supportDir ?? Directory.systemTemp.path,
      log: log,
    );
    storageDescription = _keyStore!.description;
    await _checkStorage();
    final stored = await _readKey();
    if (stored != null && stored.isNotEmpty) {
      apiKey = stored;
      log.redact(apiKey);
      log.info('Ключ загружен из хранилища (${apiKey.length} символов)');
    } else {
      log.info('Ключ ещё не сохранён');
    }
    notifyListeners();
  }

  /// Проверяет хранилище на старте: записывает и читает пробное значение.
  /// Лучше узнать о неработающем хранилище сразу, чем после ввода ключа.
  Future<void> _checkStorage() async {
    storageWorks = await _keyStore!.selfTest();
    log.info(storageWorks!
        ? 'Хранилище ключа работает: $storageDescription'
        : 'Хранилище ключа недоступно ($storageDescription). '
            'Ключ придётся вводить при каждом запуске.');
  }

  Future<String?> _readKey() async {
    try {
      return await _keyStore!.read();
    } catch (e) {
      log.warn('Не удалось прочитать сохранённый ключ: $e');
      return null;
    }
  }

  static Dio newDio() => AppServices.newDio();

  Future<void> detectFfmpeg() async {
    if (isMobile) {
      // Пакет ffmpeg_kit_flutter_new собран в варианте full-gpl: libass внутри.
      ffmpeg = const FfmpegInfo(
        ffmpegPath: 'встроенный в приложение',
        ffprobePath: 'встроенный в приложение',
        version: 'ffmpeg-kit full-gpl',
        hasLibass: true,
        source: 'bundled',
      );
      final fonts = runtime?.fontsDir;
      if (fonts != null) await (_runner() as LibFfmpegRunner).registerFonts(fonts);
      log.info('ffmpeg встроен в приложение, libass есть');
      notifyListeners();
      return;
    }
    ffmpeg = await FfmpegLocator.locate(
      override: ffmpegOverride.isEmpty ? null : ffmpegOverride,
      log: log,
    );
    if (ffmpeg != null) {
      log.info('Версия: ${ffmpeg!.version}');
      log.info(ffmpeg!.hasLibass
          ? 'libass есть — вшивание субтитров доступно'
          : 'libass НЕТ — вшивание будет недоступно');
    }
    notifyListeners();
  }

  /// На Android ffmpeg вкомпилирован в приложение, на десктопе — отдельный
  /// бинарник. Один и тот же интерфейс, разные реализации.
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  LibFfmpegRunner? _libRunner;

  FfmpegRunner _runner() {
    if (isMobile) return _libRunner ??= LibFfmpegRunner(log: log);
    return ProcessFfmpegRunner(
      ffmpegPath: ffmpeg?.ffmpegPath ?? 'ffmpeg',
      ffprobePath: ffmpeg?.ffprobePath ?? 'ffprobe',
      log: log,
    );
  }

  Future<void> setVideo(String path) async {
    videoPath = path;
    session = null;
    burnedPath = null;
    progress = null;
    lastError = null;
    // Новое видео — язык определяем заново.
    languageConfirmed = false;
    awaitingLanguageChoice = false;
    languageVerdict = null;
    notifyListeners();

    // Стенд пишет в тот же журнал: папка видео прячется и здесь.
    log.hideFolderOf(path);
    log.info('Выбрано видео: $path');
    try {
      final size = File(path).lengthSync();
      final duration = await _runner().probeDuration(path);
      videoSummary = '${duration.toStringAsFixed(2)} с, '
          '${(size / 1024 / 1024).toStringAsFixed(1)} МБ';
      log.info('Длительность ${duration.toStringAsFixed(2)} с, размер $size байт');
    } catch (e) {
      videoSummary = 'не удалось прочитать файл';
      log.error('Не удалось прочитать видео: $e');
    }
    notifyListeners();
  }

  void setLang(String value) {
    lang = value;
    languageConfirmed = true;
    awaitingLanguageChoice = false;
    log.info('Язык распознавания: $value');
    notifyListeners();
  }

  void toggleManualLanguage() {
    manualLanguage = !manualLanguage;
    notifyListeners();
  }

  /// Единственная кнопка для обычного хода: сначала определяем язык,
  /// и только если это не удалось — спрашиваем человека.
  Future<void> processVideo() async {
    if (!canRun) return;

    if (!languageConfirmed) {
      await detectLanguage();
      if (lastError != null) return;

      // Отладочный стенд по-прежнему спрашивает человека при неуверенном
      // выборе — так видно, что именно услышала каждая модель.
      if (!languageConfirmed) {
        awaitingLanguageChoice = true;
        log.info('Ждём, что язык выберет человек');
        notifyListeners();
        return;
      }
    }
    await run();
  }

  /// Человек выбрал язык на развилке — продолжаем обработку.
  Future<void> chooseLanguage(String value) async {
    lang = value;
    languageConfirmed = true;
    awaitingLanguageChoice = false;
    log.info('Язык выбран человеком: $value');
    notifyListeners();
    await run();
  }

  /// Проверяет ключ и только потом берёт его: неверный ключ не должен
  /// оставаться в памяти и открывать кнопку «Обработать».
  Future<void> saveKey(String value) async {
    keyError = null;
    sttCheck = CheckState.checking;
    translateCheck = CheckState.checking;
    notifyListeners();

    final key = value.trim();
    final dio = newDio();
    final result = await KeyChecker(
      translate: (k) => TranslateClient(dio: dio, apiKey: k),
      speechKit: (k) => SpeechKitClient(dio: dio, apiKey: k),
      log: log,
      sttLang: lang,
    ).check(key, onProgress: (r) {
      translateCheck = r.translate;
      sttCheck = r.stt;
      notifyListeners();
    });
    translateCheck = result.translate;
    sttCheck = result.stt;
    keyError = result.error?.toString();

    // Показать результат проверки НАДО до записи в хранилище: обращение к
    // Связке ключей macOS может ждать разрешения пользователя сколько угодно,
    // и индикатор всё это время висел бы в состоянии «проверяется».
    notifyListeners();

    if (result.ok) {
      apiKey = key;
      try {
        await _keyStore!.write(apiKey);
        log.info('Ключ сохранён: $storageDescription');
      } catch (e) {
        log.warn('Ключ проверен, но сохранить его не удалось: $e. '
            'В этом запуске он работает, при следующем — введите заново.');
      }
      notifyListeners();
    }
  }

  Future<void> run() async {
    if (!canRun) return;
    busy = true;
    _cancelRequested = false;
    lastError = null;
    burnedPath = null;
    notifyListeners();

    final video = videoPath!;
    final work = runtime?.workDirFor(video) ??
        Directory.systemTemp.createTempSync('subtitler_').path;
    final dio = newDio();

    try {
      final pipeline = Pipeline(
        runner: _runner(),
        stt: SpeechKitClient(dio: dio, apiKey: apiKey),
        translate: TranslateClient(dio: dio, apiKey: apiKey),
        store: SessionStore(fallbackDir: runtime?.supportDir ?? work),
        workDir: work,
        log: log,
      );

      // Продолжаем то, что уже есть: сессию из определения языка либо
      // сохранённую на диске. Так повторный запуск не оплачивает
      // распознавание заново.
      final previous = session ??
          await SessionStore(
            fallbackDir: runtime?.supportDir ?? work,
          ).load(
            video,
            SourceFingerprint(
              sizeBytes: File(video).lengthSync(),
              durationSec: await _runner().probeDuration(video),
            ),
          );

      session = await pipeline.process(
        videoPath: video,
        lang: lang,
        // Сессия на другом языке тоже передаётся: ядро отложит её в
        // резервную копию и переиспользует оплаченные пробы нового языка.
        resumeFrom: previous,
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
        isCancelled: () => _cancelRequested,
      );
      await _writeSrt();
    } catch (e) {
      lastError = '$e';
      log.error('Обработка прервана: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (!busy) return;
    _cancelRequested = true;
    log.warn('Запрошена отмена');
    notifyListeners();
  }

  /// Прогоняет пару реплик через обе модели и предлагает язык.
  /// Решение остаётся за человеком: когда обе модели дают невнятицу,
  /// приложение так и говорит, а не выбирает наугад.
  Future<void> detectLanguage() async {
    if (busy || videoPath == null || apiKey.isEmpty || ffmpeg == null) return;
    busy = true;
    _cancelRequested = false;
    lastError = null;
    languageVerdict = null;
    notifyListeners();

    final video = videoPath!;
    final work = runtime?.workDirFor(video) ??
        Directory.systemTemp.createTempSync('subtitler_').path;
    final dio = newDio();

    try {
      final probe = await Pipeline(
        runner: _runner(),
        stt: SpeechKitClient(dio: dio, apiKey: apiKey),
        translate: TranslateClient(dio: dio, apiKey: apiKey),
        store: SessionStore(fallbackDir: runtime?.supportDir ?? work),
        workDir: work,
        log: log,
      ).detectLanguage(
        videoPath: video,
        candidates: detectionCandidates.toList(),
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
        isCancelled: () => _cancelRequested,
      );
      languageVerdict = probe.verdict;
      session = probe.session;
      final verdict = probe.verdict;
      // verdict == null — для видео уже есть сохранённая сессия: язык в ней
      // и так известен, спрашивать нечего.
      if (verdict == null || verdict.confidence == LanguageConfidence.high) {
        lang = probe.session.lang;
        languageConfirmed = true;
      }
    } on PipelineCancelledException {
      lastError = 'Отменено';
      log.warn('Определение языка отменено');
    } catch (e) {
      lastError = '$e';
      log.error('Определение языка не удалось: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Правка реплики прямо в приложении. Сессия и оба .srt переписываются
  /// с небольшой задержкой, чтобы не дёргать диск на каждую букву.
  void updateCue(int cueIndex, {String? orig, String? ru}) {
    final current = session;
    if (current == null) return;
    session = current.copyWith(
      cues: current.cues
          .map((c) => c.index == cueIndex
              ? c.copyWith(orig: orig ?? c.orig, ru: ru ?? c.ru)
              : c)
          .toList(),
    );
    notifyListeners();

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () async {
      await _writeSrt();
      final s = session;
      if (s != null && runtime != null) {
        await SessionStore(fallbackDir: runtime!.supportDir).save(s);
      }
    });
  }

  /// Ставит ffmpeg со всеми нужными кодеками через Homebrew.
  /// Ничего не скачиваем сами: пакет ставится обычным менеджером пакетов,
  /// а весь вывод виден в журнале.
  bool get canInstallFfmpeg => Platform.isMacOS;

  Future<void> installFfmpeg() async {
    if (busy || !canInstallFfmpeg) return;
    busy = true;
    lastError = null;
    notifyListeners();

    try {
      final brew = ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']
          .firstWhere((p) => File(p).existsSync(), orElse: () => '');
      if (brew.isEmpty) {
        lastError = 'Homebrew не найден. Установите его с brew.sh, '
            'затем нажмите «Установить ffmpeg» снова.';
        log.error(lastError!);
        return;
      }

      log.info('Устанавливаем ffmpeg-full через Homebrew — это займёт '
          'несколько минут, окно можно не закрывать');
      final process = await Process.start(brew, ['install', 'ffmpeg-full']);
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => log.debug('brew: $line'));
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => log.debug('brew: $line'));

      final code = await process.exitCode;
      if (code == 0) {
        log.info('Homebrew закончил успешно');
      } else {
        lastError = 'Установка вернула код $code — подробности в журнале';
        log.error(lastError!);
      }
      await detectFfmpeg();
    } catch (e) {
      lastError = '$e';
      log.error('Установка ffmpeg не удалась: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  String get _base =>
      videoPath!.replaceAll(RegExp(r'\.[^.]+$'), '');

  Future<void> _writeSrt() async {
    final current = session;
    if (current == null) return;
    try {
      File('${_base}_orig.srt')
          .writeAsStringSync(buildSrt(current.cues, field: SrtField.orig));
      File('${_base}_ru.srt')
          .writeAsStringSync(buildSrt(current.cues, field: SrtField.ru));
      log.info('Записаны ${_base}_orig.srt и ${_base}_ru.srt');
    } catch (e) {
      log.error('Не удалось записать SRT рядом с видео: $e');
    }
  }

  Future<void> burn() async {
    if (!canBurn) return;
    busy = true;
    lastError = null;
    notifyListeners();

    try {
      final current = session!;
      final checkAt = visibilityCheckPoint(current.cues)!;
      final output = '${_base}_ru.mp4';
      final check = await SubtitleBurner(_runner()).burnAndVerify(
        input: videoPath!,
        srtPath: '${_base}_ru.srt',
        fontsDir: runtime!.fontsDir,
        output: output,
        checkAtSeconds: checkAt,
        onProgress: (seconds) {
          progress = PipelineProgress(PipelineStage.done,
              done: seconds.round(), total: 0);
          notifyListeners();
        },
      );
      burnedPath = output;
      log.info('Вшито: $output — субтитры в кадре видны (${check.describe()})');
    } catch (e) {
      lastError = '$e';
      log.error('Вшивание не удалось: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Показать файл в Проводнике (Finder) — теперь и на Windows.
  bool get canRevealOutput => !isMobile;

  Future<void> revealOutput() async {
    final target = burnedPath ?? videoPath;
    if (target == null || !canRevealOutput) return;
    await revealInFileManager(target, log: log);
  }

  Future<void> saveLog() async {
    final dir = runtime?.supportDir ?? Directory.systemTemp.path;
    final file = File(p.join(dir, 'subtitler-debug.log'));
    file.writeAsStringSync(log.asText());
    log.info('Журнал сохранён: ${file.path}');
    if (canRevealOutput) await revealInFileManager(file.path, log: log);
    notifyListeners();
  }
}
