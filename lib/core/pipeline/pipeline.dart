import 'dart:io';

import '../cloud/api_errors.dart';
import '../cloud/retry.dart';
import '../cloud/speechkit_client.dart';
import '../cloud/translate_client.dart';
import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../logging.dart';
import '../models.dart';
import '../session_store.dart';
import 'segment_cutter.dart';
import 'silence_scanner.dart';
import 'validation.dart';

enum PipelineStage {
  extractingAudio,
  detectingSilence,
  recognizing,
  translating,
  done,
}

class PipelineProgress {
  final PipelineStage stage;
  final int done;
  final int total;
  const PipelineProgress(this.stage, {this.done = 0, this.total = 0});
}

/// Звук в файле есть, но речи не нашлось нигде.
class NoSpeechFoundException implements Exception {
  const NoSpeechFoundException();
  @override
  String toString() => 'Речь в ролике не обнаружена';
}

/// Собирает весь путь от видеофайла до готовых реплик с переводом.
/// Владеет статусами реплик: от них зависит, что уйдёт в платный API
/// при возобновлении.
class Pipeline {
  final FfmpegRunner runner;
  final SpeechKitClient stt;
  final TranslateClient translate;
  final SessionStore store;
  final String workDir;
  final DebugLog log;

  Pipeline({
    required this.runner,
    required this.stt,
    required this.translate,
    required this.store,
    required this.workDir,
    DebugLog? log,
  }) : log = log ?? DebugLog.instance;

  Future<Session> process({
    required String videoPath,
    required String lang,
    Session? resumeFrom,
    void Function(PipelineProgress)? onProgress,
    Future<void> Function(Duration)? sleep,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final report = onProgress ?? (_) {};

    Directory(workDir).createSync(recursive: true);
    log.info('Обработка: $videoPath, язык $lang');
    log.debug('Рабочая папка: $workDir');
    final duration = await runner.probeDuration(videoPath);
    log.info('Длительность ${duration.toStringAsFixed(2)} с');
    final fingerprint = SourceFingerprint(
      sizeBytes: File(videoPath).lengthSync(),
      durationSec: duration,
    );

    var session = resumeFrom;
    if (session != null && session.lang == lang) {
      log.info('Продолжаем прежнюю сессию');
    }
    if (session == null || session.lang != lang) {
      session = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
      );
    } else if (!_segmentsPresent(session)) {
      log.warn('Файлы сегментов пропали — режем заново, '
          'уже распознанный текст сохраняем');
      // Приложение перезапускали: рабочая папка с нарезкой исчезла.
      // Режем заново, но уже распознанный текст переносим — он оплачен.
      final fresh = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
      );
      session = _mergeRecognized(fresh: fresh, previous: session);
    }

    session = await _recognizeAll(
      session: session,
      report: report,
      sleep: sleep,
      cancelled: cancelled,
    );
    session = await _translateAll(
      session: session,
      report: report,
      sleep: sleep,
      cancelled: cancelled,
    );

    session = session.copyWith(cues: applyAutoFlags(session.cues));
    final saved = await store.save(session);
    log.info('Готово. Реплик ${session.cues.length}, '
        'на проверку ${session.cues.where((c) => c.flags.isNotEmpty).length}. '
        'Сессия: $saved');
    report(const PipelineProgress(PipelineStage.done));
    return session;
  }

  /// Извлекает звук, ищет паузы, режет сегменты и заводит пустые реплики.
  Future<Session> _prepare({
    required String videoPath,
    required String lang,
    required double duration,
    required SourceFingerprint fingerprint,
    required void Function(PipelineProgress) report,
  }) async {
    report(const PipelineProgress(PipelineStage.extractingAudio));
    final audioPath = '$workDir${Platform.pathSeparator}audio.wav';
    final extracted = await runner
        .run(FfmpegCommands.extractAudio(input: videoPath, output: audioPath));
    if (!extracted.ok) {
      throw StateError('Не удалось извлечь звук: ${extracted.log}');
    }

    report(const PipelineProgress(PipelineStage.detectingSilence));
    final scan = await SilenceScanner(runner)
        .scan(audioPath: audioPath, duration: duration);
    if (scan.segments.isEmpty) {
      log.error('Речь не найдена ни на одном пороге тишины');
      throw const NoSpeechFoundException();
    }
    log.info('Порог тишины ${scan.threshold}, сегментов ${scan.segments.length}'
        '${scan.forcedSplit ? ' (пауз нет, нарезка принудительная)' : ''}');
    for (final s in scan.segments) {
      log.debug('сегмент ${s.start.toStringAsFixed(2)}–'
          '${s.end.toStringAsFixed(2)} (${s.duration.toStringAsFixed(2)} с)');
    }

    final files = await SegmentCutter(runner).cut(
      audioPath: audioPath,
      segments: scan.segments,
      outputDir: _segmentsDir,
    );

    return Session(
      videoPath: videoPath,
      fingerprint: fingerprint,
      lang: lang,
      silenceThreshold: scan.threshold,
      forcedSplit: scan.forcedSplit,
      cues: [
        for (final file in files)
          Cue(
            index: file.index,
            range: file.range,
            orig: '',
            ru: '',
            status: CueStatus.pending,
            flags: scan.forcedSplit ? const {CueFlag.forcedSplit} : const {},
          ),
      ],
    );
  }

  String get _segmentsDir => '$workDir${Platform.pathSeparator}segments';

  String _segmentPath(int index) =>
      '$_segmentsDir${Platform.pathSeparator}'
      'seg_${index.toString().padLeft(3, '0')}.ogg';

  /// Есть ли на диске файлы сегментов, которые ещё предстоит распознать.
  bool _segmentsPresent(Session session) {
    final todo = session.cues.where(
        (c) => c.status == CueStatus.pending || c.status == CueStatus.failed);
    if (todo.isEmpty) return true; // распознавать нечего — файлы не нужны
    return todo.every((c) => File(_segmentPath(c.index)).existsSync());
  }

  /// Переносит уже полученные тексты на свежую нарезку по совпадающим границам.
  Session _mergeRecognized({required Session fresh, required Session previous}) {
    final byIndex = {for (final cue in previous.cues) cue.index: cue};
    return fresh.copyWith(
      cues: fresh.cues.map((cue) {
        final old = byIndex[cue.index];
        final sameRange = old != null &&
            (old.range.start - cue.range.start).abs() < 0.01 &&
            (old.range.end - cue.range.end).abs() < 0.01;
        if (!sameRange || old.status == CueStatus.pending) return cue;
        return cue.copyWith(
          orig: old.orig,
          ru: old.ru,
          status: old.status,
          flags: old.flags,
        );
      }).toList(),
    );
  }

  Future<Session> _recognizeAll({
    required Session session,
    required void Function(PipelineProgress) report,
    required Future<void> Function(Duration)? sleep,
    required bool Function() cancelled,
  }) async {
    final cues = [...session.cues];
    final todo = cues
        .where((c) =>
            c.status == CueStatus.pending || c.status == CueStatus.failed)
        .toList();
    var done = 0;

    for (final cue in todo) {
      if (cancelled()) break;
      report(PipelineProgress(PipelineStage.recognizing,
          done: done, total: todo.length));

      final bytes = File(_segmentPath(cue.index)).readAsBytesSync();
      final position = cues.indexWhere((c) => c.index == cue.index);
      try {
        final text = await withRetry(
          () => stt.recognize(oggBytes: bytes, lang: session.lang),
          sleep: sleep,
        );
        cues[position] = cue.copyWith(
          orig: text,
          status: text.trim().isEmpty ? CueStatus.empty : CueStatus.ok,
        );
        log.info(text.trim().isEmpty
            ? 'реплика ${cue.index}: речи нет'
            : 'реплика ${cue.index}: $text');
      } on AuthException catch (e) {
        log.error('Остановка: $e');
        await store.save(session.copyWith(cues: cues));
        rethrow; // ключ или роль — продолжать бессмысленно
      } on ApiException catch (e) {
        log.warn('реплика ${cue.index}: не распозналась ($e)');
        cues[position] = cue.copyWith(status: CueStatus.failed);
      }

      done++;
      // Инкрементальная запись: обрыв не обнуляет уже оплаченное.
      session = session.copyWith(cues: cues);
      await store.save(session);
    }
    return session.copyWith(cues: cues);
  }

  Future<Session> _translateAll({
    required Session session,
    required void Function(PipelineProgress) report,
    required Future<void> Function(Duration)? sleep,
    required bool Function() cancelled,
  }) async {
    if (cancelled()) return session;

    final cues = [...session.cues];
    final pending = cues
        .where((c) => c.status == CueStatus.ok && c.ru.trim().isEmpty)
        .toList();
    if (pending.isEmpty) return session;

    report(PipelineProgress(PipelineStage.translating,
        done: 0, total: pending.length));

    try {
      final translations = await withRetry(
        () => translate.translate(
          texts: pending.map((c) => c.orig).toList(),
          sourceLang: session.lang,
        ),
        sleep: sleep,
      );
      log.info('Переведено реплик: ${translations.length}');
      for (var i = 0; i < pending.length && i < translations.length; i++) {
        final position = cues.indexWhere((c) => c.index == pending[i].index);
        cues[position] = cues[position].copyWith(ru: translations[i]);
      }
    } on AuthException catch (e) {
      log.error('Перевод остановлен: $e');
      await store.save(session.copyWith(cues: cues));
      rethrow;
    } on ApiException catch (e) {
      log.warn('Перевод не получен: $e');
      // Перевод не получен: распознанный текст не теряем, а реплики
      // получат пометку в applyAutoFlags.
    }

    session = session.copyWith(cues: cues);
    await store.save(session);
    return session;
  }
}
