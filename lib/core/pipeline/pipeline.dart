import 'dart:io';

import '../cloud/api_errors.dart';
import '../cloud/retry.dart';
import '../cloud/speechkit_client.dart';
import '../cloud/translate_client.dart';
import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
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

  Pipeline({
    required this.runner,
    required this.stt,
    required this.translate,
    required this.store,
    required this.workDir,
  });

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
    final duration = await runner.probeDuration(videoPath);
    final fingerprint = SourceFingerprint(
      sizeBytes: File(videoPath).lengthSync(),
      durationSec: duration,
    );

    var session = resumeFrom;
    if (session == null || session.lang != lang) {
      session = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
      );
    } else if (!_segmentsPresent(session)) {
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
    await store.save(session);
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
    if (scan.segments.isEmpty) throw const NoSpeechFoundException();

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
      } on AuthException {
        await store.save(session.copyWith(cues: cues));
        rethrow; // ключ или роль — продолжать бессмысленно
      } on ApiException {
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
      for (var i = 0; i < pending.length && i < translations.length; i++) {
        final position = cues.indexWhere((c) => c.index == pending[i].index);
        cues[position] = cues[position].copyWith(ru: translations[i]);
      }
    } on AuthException {
      await store.save(session.copyWith(cues: cues));
      rethrow;
    } on ApiException {
      // Перевод не получен: распознанный текст не теряем, а реплики
      // получат пометку в applyAutoFlags.
    }

    session = session.copyWith(cues: cues);
    await store.save(session);
    return session;
  }
}
