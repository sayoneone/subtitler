import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';

import '../support/app_harness.dart';

/// Помощник для виджет-тестов экранов должен работать внутри testWidgets:
/// без настоящего ввода-вывода и без висящих таймеров.
void main() {
  testWidgets('init() в testWidgets доходит до главного экрана', (tester) async {
    final h = makeTestController();
    await h.controller.init();
    expect(h.controller.stage, AppStage.home);
    await h.dispose();
  });

  testWidgets('без ключа — экран ключа', (tester) async {
    final h = makeTestController(storedKey: null);
    await h.controller.init();
    expect(h.controller.stage, AppStage.needsKey);
    await h.dispose();
  });

  testWidgets('состояние экрана выставляется напрямую, правки не оставляют '
      'таймеров', (tester) async {
    final h = makeTestController();
    await h.controller.init();
    final c = h.controller;
    c.debugEmulate(stage: AppStage.review, session: sampleSession());

    await tester.pumpWidget(MaterialApp(
      home: ListenableBuilder(
        listenable: c,
        builder: (_, _) => Text('${c.stage.name} ${c.session!.cues.first.ru}'),
      ),
    ));
    expect(find.text('review завтра рано утром пойдём на рынок'), findsOneWidget);

    c.updateTranslation(1, 'новый перевод');
    await tester.pump();
    expect(find.text('review новый перевод'), findsOneWidget);

    c.debugEmulate(
      stage: AppStage.processing,
      progress: const ProcessingProgress(ProcessingStep.recognizing,
          done: 4, total: 13),
    );
    await tester.pump();
    expect(c.progress!.label, 'Распознаём речь: 4 из 13');
    await h.dispose();
  });
}
