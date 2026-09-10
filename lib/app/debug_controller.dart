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
    log.info('Язык распознавания: $value');
    notifyListeners();
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

    final dio = Dio();
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

    if (sttCheck == CheckState.ok && translateCheck == CheckState.ok) {
      await _storage.write(key: _keyStorageName, value: apiKey);
      log.info('Ключ сохранён в хранилище системы');
    }
    notifyListeners();
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
    final dio = Dio();

    try {
      final pipeline = Pipeline(
        runner: _runner(),
        stt: SpeechKitClient(dio: dio, apiKey: apiKey),
        translate: TranslateClient(dio: dio, apiKey: apiKey),
        store: SessionStore(fallbackDir: runtime?.supportDir ?? work),
        workDir: work,
        log: log,
      );

      // Продолжаем прошлую сессию, если она про это же видео —
      // так повторный запуск не оплачивает распознавание заново.
      final previous = await SessionStore(
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
