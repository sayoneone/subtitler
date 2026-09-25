import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';

import '../support/app_harness.dart';
import 'support.dart';

const _video = '/видео/дело 7/беседа во дворе.mp4';

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
    expect(find.textContaining('ищем паузы в речи'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);

    await closeApp(tester, h);
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
