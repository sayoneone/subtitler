import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';
import '../support/media.dart';
import 'support.dart';

const _video = '/видео/дело 7/беседа во дворе.mp4';

/// Держит извлечение звука, пока тест не вызовет [release]: так «Отмена»
/// нажимается ровно на шаге «Готовим звук».
class _HoldAudio implements FfmpegRunner {
  _HoldAudio(this.inner);

  final FfmpegRunner inner;
  final _reached = Completer<void>();
  final _gate = Completer<void>();

  Future<void> get reached => _reached.future;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    if (args.contains('pcm_s16le')) {
      if (!_reached.isCompleted) _reached.complete();
      await _gate.future;
    }
    return inner.run(args, onProgress: onProgress);
  }

  @override
  Future<double> probeDuration(String path) => inner.probeDuration(path);
}

/// Контроллер для настоящей обработки. Всё создаётся в настоящем времени
/// (runAsync): Future и Completer из поддельной зоны теста обработку, идущую
/// с настоящим ffmpeg, не разбудили бы — тест бы повис.
Future<(AppHarness, AppController)> _realTimeController(
  WidgetTester tester, {
  FfmpegRunner Function(FfmpegRunner inner)? runner,
  void Function(AppHarness h)? prepare,
}) async =>
    (await tester.runAsync(() async {
      final h = await started();
      prepare?.call(h);
      final used = runner?.call(h.runner) ?? h.runner;
      final c = AppController(
        services:
            h.controller.services.copyWith(runner: (_, _, _) async => used),
        log: h.log,
      );
      await c.init();
      return (h, c);
    }))!;

/// Открывает выдуманный ролик и ждёт, пока обработка дойдёт до [reached].
Future<({Future<void> job})> _openAndWait(
  WidgetTester tester,
  AppHarness h,
  AppController c,
  Future<void> Function() reached,
) async {
  late Future<void> job;
  await tester.runAsync(() async {
    final video = await makeSpeechClip(p.join(h.root.path, 'клип.mp4'));
    job = c.openVideo(video);
    await reached().timeout(const Duration(seconds: 30));
  });
  await tester.pump();
  return (job: job);
}

Future<void> _close(
    WidgetTester tester, AppHarness h, AppController c) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async {
    c.dispose();
    await h.dispose();
  });
}

void main() {
  testWidgets('шаги по-русски, текущий — «4 из 13», «Отмена» на месте',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.processing,
      videoPath: _video,
      processingSteps: ProcessingStep.values,
      progress: const ProcessingProgress(ProcessingStep.recognizing,
          done: 4, total: 13),
    );
    await tester.pump();

    expect(find.text('беседа во дворе.mp4'), findsOneWidget);
    expect(find.text('Готовим звук'), findsOneWidget);
    expect(find.text('Определяем язык'), findsOneWidget);
    expect(find.text('Распознаём речь: 4 из 13'), findsOneWidget);
    expect(find.text('Переводим на русский'), findsOneWidget);
    expect(find.text('Отмена'), findsOneWidget);
    // Два шага позади — с галочками; текущий — с полосой 4/13.
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(4 / 13, 1e-9));
    // Язык ещё не показан, пока не определён.
    expect(find.textContaining('Язык:'), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('язык виден, как только определён', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.processing,
      videoPath: _video,
      progress: const ProcessingProgress(ProcessingStep.detectingLanguage,
          done: 1, total: 4),
    );
    await tester.pump();
    expect(find.textContaining('Язык:'), findsNothing);

    h.controller.debugEmulate(
      session: sampleSession(videoPath: _video, lang: 'uz-UZ'),
      progress: const ProcessingProgress(ProcessingStep.recognizing,
          done: 2, total: 13),
    );
    await tester.pump();
    expect(find.text('Язык: узбекский'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('подготовка звука — с пояснением, что это надолго',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.processing,
      videoPath: _video,
      progress: const ProcessingProgress(ProcessingStep.preparingAudio),
    );
    await tester.pump();

    expect(find.text('Готовим звук'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    // Доли у этого шага нет — только крутилка. Подпись честно говорит,
    // сколько это может длиться, и без слов вроде «проходов»: на часовом
    // ролике шаг идёт минуты, и человек решал, что программа зависла.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        find.text('Делим запись на фразы — на длинном ролике это может '
            'занять несколько минут.'),
        findsOneWidget);
    expect(find.textContaining('проход'), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('«Отмена» на подготовке звука — без слов про запрос, которого '
      'нет', (tester) async {
    // Во время подготовки звука в Яндекс ничего не отправляется, а экран
    // писал «Дожидаемся ответа на текущий запрос».
    late _HoldAudio hold;
    final (h, c) = await _realTimeController(tester,
        runner: (inner) => hold = _HoldAudio(inner));
    await pumpApp(tester, c);
    final (:job) = await _openAndWait(tester, h, c, () => hold.reached);
    expect(c.progress?.step, ProcessingStep.preparingAudio);

    await tester.tap(find.text('Отмена'));
    await tester.pump();

    expect(find.text('Останавливаем…'), findsOneWidget);
    expect(find.textContaining('ответа на текущий запрос'), findsNothing);
    expect(
        find.text('Дожидаемся конца текущего шага подготовки звука — '
            'платных запросов ещё не было.'),
        findsOneWidget);

    await tester.runAsync(() async {
      hold.release();
      await job;
    });
    await tester.pump();
    expect(c.stage, AppStage.cancelled);
    await _close(tester, h, c);
  });

  testWidgets('«Отмена», когда запрос в Яндекс уже ушёл, — ждём ответа на '
      'него', (tester) async {
    late GatedStt stt;
    final (h, c) = await _realTimeController(tester, prepare: (h) {
      h.stt = stt = GatedStt(FakeStt(const ['bir', 'iki', 'üç']));
    });
    await pumpApp(tester, c);
    final (:job) = await _openAndWait(tester, h, c, () => stt.reached);
    expect(c.progress?.step, ProcessingStep.detectingLanguage);

    await tester.tap(find.text('Отмена'));
    await tester.pump();
    expect(
        find.text('Дожидаемся ответа на текущий запрос — новых платных '
            'запросов не будет.'),
        findsOneWidget);

    await tester.runAsync(() async {
      stt.release();
      await job;
    });
    await _close(tester, h, c);
  });

  testWidgets('платная смена языка — без шага «Определяем язык»',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.processing,
      session: sampleSession(videoPath: _video, lang: 'uz-UZ'),
      processingSteps: const [
        ProcessingStep.preparingAudio,
        ProcessingStep.recognizing,
        ProcessingStep.translating,
      ],
      progress: const ProcessingProgress(ProcessingStep.translating),
    );
    await tester.pump();

    expect(find.text('Определяем язык'), findsNothing);
    expect(find.text('Переводим на русский'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));

    await closeApp(tester, h);
  });

  testWidgets('после отмены — «Открыть, что успели» и «На главный экран»',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.cancelled,
      partial: sampleSession(videoPath: _video),
    );
    await tester.pump();

    expect(find.text('Обработка остановлена'), findsOneWidget);
    expect(find.textContaining('Уже распознанное сохранено'), findsOneWidget);
    expect(find.text('Открыть, что успели'), findsOneWidget);
    expect(find.text('На главный экран'), findsOneWidget);

    await tester.tap(find.text('На главный экран'));
    await tester.pump();
    await tester.pump();
    expect(h.controller.stage, AppStage.home);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('отменили до распознавания — открыть нечего', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(stage: AppStage.cancelled, videoPath: _video);
    await tester.pump();

    expect(find.text('Обработка остановлена'), findsOneWidget);
    expect(find.text('Распознать ничего не успели.'), findsOneWidget);
    expect(find.text('Открыть, что успели'), findsNothing);
    expect(find.text('На главный экран'), findsOneWidget);

    await closeApp(tester, h);
  });
}
