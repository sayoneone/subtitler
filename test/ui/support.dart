/// Общее для виджет-тестов оболочки и экранов: приложение целиком
/// (`SubtitlerApp` с русской локалью) на контроллере из подделок.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/main.dart';

import '../support/app_harness.dart';
import '../support/fake_preview_player.dart';

/// Контроллер после `init()`: по умолчанию ключ сохранён — главный экран.
Future<AppHarness> started({
  String? storedKey = kTestApiKey,
  bool noFfmpeg = false,
  bool isMobile = false,
  AppSettings settings = const AppSettings(),
  Object? runtimeError,
  bool keyStorageWorks = true,
}) async {
  final h = makeTestController(
    storedKey: storedKey,
    noFfmpeg: noFfmpeg,
    isMobile: isMobile,
    settings: settings,
    runtimeError: runtimeError,
  );
  h.keyStore.selfTestResult = keyStorageWorks;
  await h.controller.init();
  return h;
}

/// Приложение на [controller] в окне [size]; плеер — подделка.
Future<void> pumpApp(
  WidgetTester tester,
  AppController controller, {
  Size size = const Size(1280, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(SubtitlerApp(
    controller: controller,
    playerFactory: ({DebugLog? log}) => FakePreviewPlayer(),
  ));
  await tester.pump();
}

/// Снимает приложение с экрана и освобождает контроллер с его папкой.
Future<void> closeApp(WidgetTester tester, AppHarness h) async {
  await tester.pumpWidget(const SizedBox());
  await h.dispose();
}

/// Весь текст, который сейчас на экране: обычный текст и текст
/// выделяемых полей. Скрытые поля (ввод ключа) не читаются — их
/// содержимое на экране не видно.
List<String> visibleTexts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText(),
      for (final w in tester.widgetList<EditableText>(find.byType(EditableText)))
        if (!w.obscureText) w.controller.text,
    ];

/// Ctrl+Shift+L.
Future<void> pressLogShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Открывает меню «⋮».
Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('menu')));
  await tester.pumpAndSettle();
}

/// Открывает «⚙ Настройки».
Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('settings')));
  await tester.pumpAndSettle();
}

/// «Назад» из открытого экрана. `pageBack` ищет подсказку «Back», а
/// приложение говорит по-русски.
Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}
