import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/ui/log_panel.dart';

import '../support/counting_log.dart';

Future<void> showPanel(WidgetTester tester, DebugLog log) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LogPanel(log: log, onSave: () {})),
    ));

Future<void> hidePanel(WidgetTester tester) =>
    tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

void main() {
  testWidgets('закрытая панель отписывается от журнала', (tester) async {
    final log = CountingLog();
    for (var i = 0; i < 3; i++) {
      await showPanel(tester, log);
      expect(log.listeners, 1, reason: 'открытие №${i + 1}');
      await hidePanel(tester);
      expect(log.listeners, 0,
          reason: 'после закрытия №${i + 1} подписка должна сниматься, '
              'а не копиться при каждом показе журнала');
    }
  });

  testWidgets('подробные записи скрыты, пока их не включили',
      (tester) async {
    final log = DebugLog()
      ..info('Видео принято')
      ..debug('подробность для разработчика');
    await showPanel(tester, log);

    expect(find.textContaining('Видео принято'), findsOneWidget);
    expect(find.textContaining('подробность для разработчика'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.textContaining('подробность для разработчика'), findsOneWidget);
  });

  testWidgets('новая запись появляется в открытой панели', (tester) async {
    final log = DebugLog()..info('первая запись');
    await showPanel(tester, log);
    log.warn('вторая запись');
    await tester.pump();
    expect(find.textContaining('вторая запись'), findsOneWidget);
  });
}
