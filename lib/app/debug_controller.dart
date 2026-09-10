import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../core/cloud/api_errors.dart';
import '../core/cloud/speechkit_client.dart';
import '../core/cloud/translate_client.dart';
import '../core/ffmpeg/ffmpeg_locator.dart';
import '../core/ffmpeg/process_runner.dart';
import '../core/logging.dart';
import '../core/models.dart';
import '../core/pipeline/burner.dart';
import '../core/pipeline/language_detector.dart';
import '../core/pipeline/pipeline.dart';
import '../core/session_store.dart';
import '../core/srt.dart';
import 'runtime.dart';

enum CheckState { unknown, checking, ok, failed }

/// Состояние отладочного стенда. Одна модель на весь экран — этого хватает,
/// а лишние слои только мешают отлаживать.
class DebugController extends ChangeNotifier {
  static const _keyStorageName = 'yc_api_key';

  final DebugLog log = DebugLog.instance;
  final _storage = const FlutterSecureStorage();

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

  bool busy = false;
  bool _cancelRequested = false;
  String? lastError;

  bool get canRun =>
      !busy && videoPath != null && apiKey.isNotEmpty && ffmpeg != null;

  bool get canBurn =>
      !busy &&
      session != null &&
      session!.cues.any((c) => c.ru.trim().isNotEmpty) &&
      (ffmpeg?.hasLibass ?? false);

  Future<void> init() async {
    log.info('Запуск приложения');
    try {
      runtime = await AppRuntime.prepare(log: log);
    } catch (e) {
      log.error('Не удалось подготовить папки приложения: $e');
    }
    await detectFfmpeg();
    final stored = await _storage.read(key: _keyStorageName);
    if (stored != null && stored.isNotEmpty) {
      apiKey = stored;
      log.redact(apiKey);
      log.info('Ключ загружен из хранилища (${apiKey.length} символов)');
    } else {
      log.info('Ключ ещё не сохранён');
    }
    notifyListeners();
  }

  /// Общие настройки сети. Без явных таймаутов зависший запрос подвесил бы
  /// весь прогон, и отменить его было бы нечем.
  static Dio newDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ));

  Future<void> detectFfmpeg() async {
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

  ProcessFfmpegRunner _runner() => ProcessFfmpegRunner(
        ffmpegPath: ffmpeg?.ffmpegPath ?? 'ffmpeg',
        ffprobePath: ffmpeg?.ffprobePath ?? 'ffprobe',
        log: log,
      );

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

      final verdict = languageVerdict;
      if (verdict == null || !verdict.confident) {
        awaitingLanguageChoice = true;
        log.info('Ждём, что язык выберет человек');
        notifyListeners();
        return;
      }
      languageConfirmed = true;
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

  Future<void> saveKey(String value) async {
    apiKey = value.trim();
    keyError = null;
    sttCheck = CheckState.checking;
    translateCheck = CheckState.checking;
    notifyListeners();

    if (apiKey.isEmpty) {
      keyError = 'Ключ пустой';
      sttCheck = translateCheck = CheckState.failed;
      notifyListeners();
      return;
    }
    log.redact(apiKey);
    log.info('Проверка ключа (${apiKey.length} символов)');

    final dio = newDio();
    // 1) Перевод — самая дешёвая проверка.
    try {
      final result = await TranslateClient(dio: dio, apiKey: apiKey)
          .translate(texts: const ['merhaba'], sourceLang: 'tr-TR');
      translateCheck = CheckState.ok;
      log.info('Перевод работает: merhaba → ${result.firstOrNull ?? ''}');
    } on ApiException catch (e) {
      translateCheck = CheckState.failed;
      keyError = e.message;
      log.error('Перевод недоступен: $e');
    } catch (e) {
      translateCheck = CheckState.failed;
      keyError = '$e';
      log.error('Перевод недоступен: $e');
    }
    notifyListeners();

    // 2) Распознавание — нужен хоть какой-то звук, генерируем тишину.
    try {
      final ogg = await _tinyOgg();
      if (ogg == null) {
        sttCheck = CheckState.failed;
        keyError ??= 'Не удалось подготовить пробный звук (нет ffmpeg?)';
      } else {
        await SpeechKitClient(dio: dio, apiKey: apiKey)
            .recognize(oggBytes: ogg, lang: lang);
        sttCheck = CheckState.ok;
        log.info('Распознавание отвечает');
      }
    } on ApiException catch (e) {
      sttCheck = CheckState.failed;
      keyError = e.message;
      log.error('Распознавание недоступно: $e');
    } catch (e) {
      sttCheck = CheckState.failed;
      keyError = '$e';
      log.error('Распознавание недоступно: $e');
    }

    // Показать результат проверки НАДО до записи в хранилище: обращение к
    // Связке ключей macOS может ждать разрешения пользователя сколько угодно,
    // и индикатор всё это время висел бы в состоянии «проверяется».
    notifyListeners();

    if (sttCheck == CheckState.ok && translateCheck == CheckState.ok) {
      try {
        await _storage
            .write(key: _keyStorageName, value: apiKey)
            .timeout(const Duration(seconds: 20));
        log.info('Ключ сохранён в хранилище системы');
      } catch (e) {
        log.warn('Ключ проверен, но сохранить его не удалось: $e. '
            'В этом запуске он работает, при следующем — введите заново.');
      }
      notifyListeners();
    }
  }

  /// Полсекунды тишины в OggOpus — нужен только чтобы проверить, что
  /// распознавание принимает наш ключ.
  Future<List<int>?> _tinyOgg() async {
    final dir = runtime?.supportDir;
    if (dir == null) return null;
    final path = p.join(dir, 'probe.ogg');
    final result = await _runner().run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono:d=0.5',
      '-c:a', 'libopus', '-b:a', '64k', path,
    ]);
    if (!result.ok) return null;
    return File(path).readAsBytesSync();
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
        resumeFrom: previous?.lang == lang ? previous : null,
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
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
      );
      languageVerdict = probe.verdict;
      session = probe.session;
      if (probe.verdict.confident) {
        lang = probe.verdict.best.lang;
        languageConfirmed = true;
      }
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
  Future<void> installFfmpeg() async {
    if (busy) return;
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
      final first = current.cues.firstWhere((c) => c.ru.trim().isNotEmpty);
      final output = '${_base}_ru.mp4';
      await SubtitleBurner(_runner()).burnAndVerify(
        input: videoPath!,
        srtPath: '${_base}_ru.srt',
        fontsDir: runtime!.fontsDir,
        output: output,
        checkAtSeconds: (first.range.start + first.range.end) / 2,
        onProgress: (seconds) {
          progress = PipelineProgress(PipelineStage.done,
              done: seconds.round(), total: 0);
          notifyListeners();
        },
      );
      burnedPath = output;
      log.info('Вшито: $output — субтитры в кадре видны');
    } catch (e) {
      lastError = '$e';
      log.error('Вшивание не удалось: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> revealOutput() async {
    final target = burnedPath ?? videoPath;
    if (target == null) return;
    await Process.run('open', ['-R', target]);
  }

  Future<void> saveLog() async {
    final dir = runtime?.supportDir ?? Directory.systemTemp.path;
    final file = File(p.join(dir, 'subtitler-debug.log'));
    file.writeAsStringSync(log.asText());
    log.info('Журнал сохранён: ${file.path}');
    await Process.run('open', ['-R', file.path]);
    notifyListeners();
  }
}
