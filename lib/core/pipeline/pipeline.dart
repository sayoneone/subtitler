import 'dart:io';

import '../cloud/api_errors.dart';
import '../cloud/retry.dart';
import '../cloud/speechkit_client.dart';
import '../cloud/translate_client.dart';
import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../logging.dart';
import '../languages.dart';
import '../models.dart';
import '../session_store.dart';
import 'errors.dart';
import 'language_detector.dart';
import 'probe_cues.dart';
import 'segment_cutter.dart';
import 'silence_scanner.dart';
import 'validation.dart';

export 'errors.dart';

enum PipelineStage {
  extractingAudio,
  detectingSilence,

  /// Пробы на нескольких языках. `done`/`total` — пробные запросы;
  /// `total` может вырасти, если после первых проб уверенности мало.
  detectingLanguage,
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

/// Сколько запросов подряд должно остаться без ответа (каждый — со всеми
/// повторами), чтобы решить, что сети нет.
///
/// Один такой отказ — сбой одного запроса: реплика помечается
/// нераспознанной, обработка идёт дальше. Два подряд — это восемь попыток
/// за 30 с и больше без единого ответа. Дальше ждать бессмысленно: каждая
/// следующая реплика стоила бы ещё 15 с и больше, а в конце человек
/// получил бы редактор из одних жёлтых строк вместо «Нет доступа к
/// интернету».
const int kNoNetworkStreak = 2;

/// Отвечает ли сервис вообще: считает запросы, оставшиеся без ответа.
class _Connection {
  int _streak = 0;
  bool _answered = false;
  TransientException? _lost;

  /// Сервис ответил — текстом или кодом ошибки: связь есть.
  void answered() {
    _streak = 0;
    _answered = true;
  }

  /// Запрос не удался со всеми повторами. `true` — сети нет.
  bool failed(ApiException e) {
    if (e is TransientException && e.noResponse) {
      _streak++;
      _lost = e;
      return _streak >= kNoNetworkStreak;
    }
    answered();
    return false;
  }

  /// Последний отказ без ответа — с ним человек увидит «Нет доступа к
  /// интернету».
  TransientException get lost => _lost!;

  /// Запросы были, но ни на один не пришло ответа — сети нет, даже если
  /// запросов меньше [kNoNetworkStreak].
  bool get neverAnswered => !_answered && _lost != null;
}

/// Итог определения языка.
class LanguageProbe {
  /// С чего продолжать обработку. Либо новая сессия — с выбранным языком,
  /// пробами ВСЕХ языков и уже распознанными репликами выбранного, — либо
  /// сессия, сохранённая для этого видео раньше.
  final Session session;

  /// Как выбран язык. `null` — для видео уже была сохранённая сессия: она
  /// возвращена как есть, ничего не распознавалось и не записывалось.
  final LanguageVerdict? verdict;

  const LanguageProbe({required this.session, this.verdict});

  bool get reusedSession => verdict == null;
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

  /// Распознаёт и переводит весь ролик на языке [lang].
  ///
  /// [resumeFrom] — сессия, с которой продолжать (из [detectLanguage] или
  /// с диска): уже распознанные реплики повторно не оплачиваются. Сессия
  /// другого файла (не совпал отпечаток) не используется.
  ///
  /// Если язык [resumeFrom] не [lang] — это смена языка. Прежняя сессия
  /// уходит в резервную копию (`SessionStore.saveBackup`) вместе с ручными
  /// правками. Если на [lang] ролик уже распознавался, его копия
  /// восстанавливается бесплатно (`SessionStore.swapWithBackup`); иначе
  /// ролик распознаётся заново на [lang] — кроме реплик, для которых на
  /// этом языке уже есть пробы ([Session.probeTexts]): за них заплачено.
  /// Язык после смены выбран человеком: уверенность `null`, второй язык —
  /// прежний.
  ///
  /// Отмена ([isCancelled]) во время распознавания или перевода возвращает
  /// то, что успели; во время подготовки звука, когда показывать ещё
  /// нечего, — [PipelineCancelledException]. Видео без звука —
  /// [NoAudioStreamException], звук без речи — [NoSpeechFoundException].
  ///
  /// Сбой одной реплики помечает её `failed`, и обработка идёт дальше. Но
  /// если сети нет — [kNoNetworkStreak] реплик подряд остались без ответа,
  /// сервис не ответил ни разу или без ответа остался перевод, —
  /// бросается [TransientException] без кода («Нет доступа к интернету»).
  /// Уже распознанное к этому моменту записано: повтор за него не платит.
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
    if (session != null && !session.fingerprint.matches(fingerprint)) {
      log.warn('Сессия относится к другому файлу (не совпал отпечаток) — '
          'начинаем заново');
      session = null;
    }
    if (session != null && session.lang != lang) {
      final restored = await store.swapWithBackup(session, lang);
      if (restored != null) {
        log.info('Смена языка: ${session.lang} → $lang. На $lang ролик уже '
            'распознавался — берём резервную копию, прежний вариант '
            'откладываем в свою');
        session = restored;
      } else {
        final backup = await store.saveBackup(session);
        log.info('Смена языка: ${session.lang} → $lang. '
            'Прежний вариант сохранён: $backup');
        session = _switchLanguage(session, lang);
        final reused =
            session.cues.where((c) => c.status != CueStatus.pending).length;
        log.info('Готовые пробы на $lang: $reused реплик — повторно не платим');
      }
    } else if (session != null) {
      log.info('Продолжаем прежнюю сессию');
    }

    if (session == null) {
      session = await _prepare(
        videoPath: videoPath,
        lang: lang,
        duration: duration,
        fingerprint: fingerprint,
        report: report,
        cancelled: cancelled,
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
        cancelled: cancelled,
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

  /// Определяет язык ролика пробами и возвращает сессию, с которой
  /// продолжать ([process] с `resumeFrom: probe.session`). Человека ни о
  /// чём не спрашивает: язык выбирается всегда, а уверенность выбора
  /// сохраняется в сессии.
  ///
  /// Если для видео уже есть сохранённая сессия (совпал отпечаток), она
  /// возвращается как есть: без проб, без оплаты и без перезаписи — в ней
  /// могут быть ручные правки.
  ///
  /// Пробы идут в два этапа:
  /// 1. [probeSegments] самых длинных реплик из разных частей ролика
  ///    распознаются моделями всех [candidates];
  /// 2. если уверенность не высокая — ещё [extraProbeSegments] реплик,
  ///    и только двумя лидерами.
  /// Сравниваются только реплики, распознанные всеми сравниваемыми
  /// моделями. Тексты проб всех языков сохраняются в сессию
  /// ([Session.probeTexts]): при смене языка за них не платим повторно.
  ///
  /// [previousLang] — язык прошлой обработки: его берём, если все модели
  /// промолчали (ответили пустым текстом). Отмена ([isCancelled]) до конца
  /// проб бросает [PipelineCancelledException] и ничего не записывает:
  /// сессия с неопределённым языком хуже, чем несколько копеек за пробы.
  /// По той же причине ничего не записывается, если сервис не ответил:
  /// [kNoNetworkStreak] проб подряд без ответа или ни одна проба первого
  /// этапа не получила текста из-за временной ошибки — тогда бросается
  /// эта [TransientException].
  /// Этап [PipelineStage.done] здесь не сообщается — обработка после
  /// определения языка только начинается.
  Future<LanguageProbe> detectLanguage({
    required String videoPath,
    List<String> candidates = kDefaultDetectionCandidates,
    String? previousLang,
    int probeSegments = 2,
    int extraProbeSegments = 2,
    void Function(PipelineProgress)? onProgress,
    Future<void> Function(Duration)? sleep,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final report = onProgress ?? (_) {};
    final langs = <String>[];
    for (final lang in candidates) {
      if (!langs.contains(lang)) langs.add(lang);
    }
    if (langs.isEmpty) {
      throw ArgumentError('Не выбрано ни одного языка для определения');
    }
    Directory(workDir).createSync(recursive: true);

    final duration = await runner.probeDuration(videoPath);
    final fingerprint = SourceFingerprint(
      sizeBytes: File(videoPath).lengthSync(),
      durationSec: duration,
    );

    final saved = await store.load(videoPath, fingerprint);
    if (saved != null) {
      log.info('Для видео уже есть сохранённая сессия (язык ${saved.lang}) — '
          'открываем её без проб');
      return LanguageProbe(session: saved);
    }

    final base = await _prepare(
      videoPath: videoPath,
      lang: langs.first,
      duration: duration,
      fingerprint: fingerprint,
      report: report,
      cancelled: cancelled,
    );

    final recognized = <String, Map<int, String>>{};
    var done = 0;
    var total = 0;
    final connection = _Connection();
    TransientException? lastTransient;

    Future<void> probe(List<Cue> cues, List<String> models) async {
      total += cues.length * models.length;
      for (final cue in cues) {
        final bytes = File(_segmentPath(cue.index)).readAsBytesSync();
        for (final lang in models) {
          throwIfCancelled(cancelled);
          report(PipelineProgress(PipelineStage.detectingLanguage,
              done: done, total: total));
          try {
            // Отмена между повторами — PipelineCancelledException: она
            // не ApiException и летит наружу, как и положено при пробах.
            final text = await withRetry(
              () => stt.recognize(oggBytes: bytes, lang: lang),
              sleep: sleep,
              isCancelled: cancelled,
            );
            connection.answered();
            (recognized[lang] ??= {})[cue.index] = text;
            log.info('[$lang] реплика ${cue.index}: '
                '${text.isEmpty ? '(пусто)' : text}');
          } on AuthException {
            rethrow;
          } on ApiException catch (e) {
            // Реплика без ответа одной из моделей просто не сравнивается.
            log.warn('[$lang] реплика ${cue.index}: ошибка ($e)');
            if (e is TransientException) lastTransient = e;
            if (connection.failed(e)) {
              log.error('Сервис распознавания не отвечает — сети нет, '
                  'определение языка остановлено');
              rethrow;
            }
          }
          done++;
        }
      }
      report(PipelineProgress(PipelineStage.detectingLanguage,
          done: done, total: total));
    }

    final first = pickProbeCues(base.cues, count: probeSegments);
    log.info('Определение языка: реплики '
        '${first.map((c) => c.index).join(', ')}; '
        'языки: ${langs.map(languageName).join(', ')}');
    await probe(first, langs);
    // Ни одна модель не прислала текста — не потому, что в записи тишина
    // (тогда пришли бы пустые ответы), а потому, что сервис не ответил.
    // Язык наугад не выбираем и сессию не пишем: выбор закрепился бы, и
    // весь ролик распознавался бы на догадке. Пусть человек повторит.
    if (recognized.isEmpty && lastTransient != null) {
      log.error('Ни одна проба не получила ответа — язык не определяем');
      throw lastTransient!;
    }
    var verdict = judgeLanguage(recognized,
        candidates: langs, previousLang: previousLang);
    log.info('Язык по первым пробам: ${verdict.describe()}');

    if (verdict.confidence != LanguageConfidence.high &&
        langs.length > 1 &&
        extraProbeSegments > 0) {
      final leaders = verdict.candidates
          .map((c) => c.lang)
          .where(langs.contains)
          .take(2)
          .toList();
      final extra =
          pickProbeCues(base.cues, count: extraProbeSegments, taken: first);
      if (extra.isNotEmpty) {
        log.info('Уверенности мало — ещё реплики '
            '${extra.map((c) => c.index).join(', ')}, '
            'языки: ${leaders.map(languageName).join(', ')}');
        await probe(extra, leaders);
        final second = judgeLanguage(
          {for (final lang in leaders) lang: recognized[lang] ?? const {}},
          candidates: leaders,
          previousLang: previousLang,
        );
        // Остальные языки отстали уже на первом этапе — оставляем их
        // оценки для журнала, но решают лидеры.
        verdict = LanguageVerdict(
          lang: second.lang,
          confidence: second.confidence,
          runnerUp: second.runnerUp,
          candidates: [
            ...second.candidates,
            ...verdict.candidates.where((c) => !leaders.contains(c.lang)),
          ],
          comparedCues: second.comparedCues,
          mixed: second.mixed,
        );
        log.info('Язык по всем пробам: ${verdict.describe()}');
      }
    }
    // Отмену могли нажать, пока шла последняя проба.
    throwIfCancelled(cancelled);

    // Уже распознанное выигравшей моделью не распознаётся повторно.
    final winnerTexts = recognized[verdict.lang] ?? const <int, String>{};
    final session = base.copyWith(
      lang: verdict.lang,
      langConfidence: verdict.confidence,
      langRunnerUp: verdict.runnerUp,
      probeTexts: recognized,
      cues: _withTexts(base.cues, winnerTexts),
    );
    // Подходящей сессии для этого видео нет (проверено выше). Файл, который
    // есть, но не читается (схема новее, обрезанная запись), хранилище не
    // затирает, а откладывает в сторону — см. SessionStore._keepUnreadable.
    await store.save(session);
    return LanguageProbe(session: session, verdict: verdict);
  }

  /// Реплики с распознанными текстами из [texts] (номер → текст).
  static List<Cue> _withTexts(List<Cue> cues, Map<int, String> texts) =>
      cues.map((cue) {
        final text = texts[cue.index];
        if (text == null) return cue;
        return cue.copyWith(
          orig: text,
          status: text.trim().isEmpty ? CueStatus.empty : CueStatus.ok,
        );
      }).toList();

  /// Сессия того же ролика на другом языке: реплики сбрасываются в
  /// «не распознано», кроме тех, для которых есть пробы этого языка.
  Session _switchLanguage(Session session, String lang) {
    final blank = [
      for (final cue in session.cues)
        Cue(
          index: cue.index,
          range: cue.range,
          orig: '',
          ru: '',
          status: CueStatus.pending,
          flags: session.forcedSplit ? const {CueFlag.forcedSplit} : const {},
        ),
    ];
    return session.copyWith(
      lang: lang,
      langConfidence: null,
      langRunnerUp: session.lang,
      cues: _withTexts(blank, session.probeTexts[lang] ?? const {}),
    );
  }

  /// Извлекает звук, ищет паузы, режет сегменты и заводит пустые реплики.
  Future<Session> _prepare({
    required String videoPath,
    required String lang,
    required double duration,
    required SourceFingerprint fingerprint,
    required void Function(PipelineProgress) report,
    required bool Function() cancelled,
  }) async {
    throwIfCancelled(cancelled);
    report(const PipelineProgress(PipelineStage.extractingAudio));
    final audioPath = '$workDir${Platform.pathSeparator}audio.wav';
    try {
      final extracted = await runner.run(
          FfmpegCommands.extractAudio(input: videoPath, output: audioPath));
      if (!extracted.ok) {
        if (NoAudioStreamException.matches(extracted.log)) {
          log.error('В видео нет звуковой дорожки');
          throw const NoAudioStreamException();
        }
        throw StateError('Не удалось извлечь звук: ${extracted.log}');
      }

      throwIfCancelled(cancelled);
      report(const PipelineProgress(PipelineStage.detectingSilence));
      final scan = await SilenceScanner(runner).scan(
          audioPath: audioPath, duration: duration, isCancelled: cancelled);
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
        isCancelled: cancelled,
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
    } finally {
      // Звук нужен только для поиска пауз и нарезки — распознаются уже
      // сегменты, — а весит он около 345 МБ на час видео. Если сегменты
      // потом пропадут, _prepare извлечёт его заново.
      _deleteQuietly(audioPath);
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException catch (e) {
      log.warn('Не удалось удалить $path: $e');
    }
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
  /// Язык, уверенность и пробы остаются от прежней сессии: нарезка
  /// меняется, а они — нет.
  Session _mergeRecognized({required Session fresh, required Session previous}) {
    final byIndex = {for (final cue in previous.cues) cue.index: cue};
    return previous.copyWith(
      silenceThreshold: fresh.silenceThreshold,
      forcedSplit: fresh.forcedSplit,
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
    final connection = _Connection();

    for (final cue in todo) {
      if (cancelled()) break;
      report(PipelineProgress(PipelineStage.recognizing,
          done: done, total: todo.length));

      final bytes = File(_segmentPath(cue.index)).readAsBytesSync();
      final position = cues.indexWhere((c) => c.index == cue.index);
      var noNetwork = false;
      try {
        final text = await withRetry(
          () => stt.recognize(oggBytes: bytes, lang: session.lang),
          sleep: sleep,
          isCancelled: cancelled,
        );
        connection.answered();
        cues[position] = cue.copyWith(
          orig: text,
          status: text.trim().isEmpty ? CueStatus.empty : CueStatus.ok,
        );
        log.info(text.trim().isEmpty
            ? 'реплика ${cue.index}: речи нет'
            : 'реплика ${cue.index}: $text');
      } on PipelineCancelledException {
        // Отмена в паузе между повторами: повторы не исчерпаны, реплика
        // остаётся какой была и распознается при продолжении.
        break;
      } on AuthException catch (e) {
        log.error('Остановка: $e');
        await store.save(session.copyWith(cues: cues));
        rethrow; // ключ или роль — продолжать бессмысленно
      } on ApiException catch (e) {
        log.warn('реплика ${cue.index}: не распозналась ($e)');
        cues[position] = cue.copyWith(status: CueStatus.failed);
        noNetwork = connection.failed(e);
      }

      done++;
      // Инкрементальная запись: обрыв не обнуляет уже оплаченное.
      session = session.copyWith(cues: cues);
      await store.save(session);
      if (noNetwork) {
        log.error('Сервис распознавания не отвечает — сети нет, '
            'обработка остановлена');
        throw connection.lost;
      }
    }
    if (connection.neverAnswered && !cancelled()) {
      log.error('Сервис распознавания не ответил ни разу — сети нет');
      throw connection.lost;
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
        isCancelled: cancelled,
      );
      log.info('Переведено реплик: ${translations.length}');
      for (var i = 0; i < pending.length && i < translations.length; i++) {
        final position = cues.indexWhere((c) => c.index == pending[i].index);
        cues[position] = cues[position].copyWith(ru: translations[i]);
      }
    } on PipelineCancelledException {
      // Отмена в паузе между повторами: перевод доделается при следующем
      // открытии видео.
      return session;
    } on AuthException catch (e) {
      log.error('Перевод остановлен: $e');
      await store.save(session.copyWith(cues: cues));
      rethrow;
    } on ApiException catch (e) {
      if (e is TransientException && e.noResponse) {
        // Весь перевод — один запрос на все реплики (батчами), и он со
        // всеми повторами остался без ответа: сети нет. Распознанное
        // сохраняем; «Повторить» доделает только перевод.
        log.error('Сервис перевода не отвечает — сети нет');
        await store.save(session.copyWith(cues: cues));
        rethrow;
      }
      log.warn('Перевод не получен: $e');
      // Перевод не получен: распознанный текст не теряем, а реплики
      // получат пометку в applyAutoFlags.
    }

    session = session.copyWith(cues: cues);
    await store.save(session);
    return session;
  }
}
