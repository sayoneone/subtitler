import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/debug_controller.dart';
import 'package:subtitler/ui/debug_screen.dart';
import 'package:subtitler/ui/log_panel.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('стенд в широком окне закрывается без ошибки', (tester) async {
    final h = makeTestController();
    // Как из меню приложения: готовые папки, ffmpeg и хранилище ключа.
    final stand = DebugController(
      runtime: h.runtime,
      ffmpeg: kTestFfmpeg,
      keyStore: h.keyStore,
      log: h.log,
    );
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: DebugScreen(controller: stand)));
    await tester.pumpAndSettle();

    expect(find.text('Subtitler — отладочный стенд'), findsOneWidget);
    // Широкое окно: журнал рядом, вкладок нет.
    expect(find.byType(LogPanel), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);

    await tester.pumpWidget(const SizedBox()); // стенд закрыли
    expect(tester.takeException(), isNull);

    stand.dispose();
    await h.dispose();
  });
}
