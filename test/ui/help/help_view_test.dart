import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/ui/help/help_view.dart';
import 'package:subtitler/ui/help/help_window.dart';

import '../../support/fakes.dart';
import '../support.dart';

/// Экран руководства и его загрузка из ассетов (в виджет-тесте ассеты
/// читаются сразу, без настоящего ввода-вывода).
Future<void> settleGuide(WidgetTester tester) => tester.pumpAndSettle();

/// «Раздел · 3 из 14» в заголовке руководства.
String counter(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('help-counter'))).data!;

void main() {
  group('Первый запуск', () {
    testWidgets('руководство открывается само — один раз, и это '
        'запоминается', (tester) async {
      final h = await started(storedKey: null);
      final help = HelpWindowSpy();
      await pumpApp(tester, h.controller, helpWindow: help);
      await tester.pump();

      expect(help.opened, 1);
      expect(find.text('Ключ Яндекс Облака'), findsOneWidget,
          reason: 'в главном окне — экран ключа');
      final saved = await (h.settingsStore as MemorySettingsStore).load();
      expect(saved.helpShown, isTrue);

      // Дальнейшие изменения этапа руководство заново не открывают.
      h.controller.debugEmulate(stage: AppStage.home);
      await tester.pump();
      await tester.pump();
      expect(help.opened, 1);
      await closeApp(tester, h);
    });

    testWidgets('при следующих запусках само не открывается', (tester) async {
      final h = await started(settings: const AppSettings(helpShown: true));
      final help = HelpWindowSpy();
      await pumpApp(tester, h.controller, helpWindow: help);
      await tester.pump();

      expect(help.opened, 0);
      await closeApp(tester, h);
    });

    testWidgets('программа не может работать — руководство не открывается',
        (tester) async {
      final h = await started(noFfmpeg: true);
      expect(h.controller.stage, AppStage.broken);
      final help = HelpWindowSpy();
      await pumpApp(tester, h.controller, helpWindow: help);
      await tester.pump();

      expect(help.opened, 0);
      final saved = await (h.settingsStore as MemorySettingsStore).load();
      expect(saved.helpShown, isFalse, reason: 'откроется, когда починят');
      await closeApp(tester, h);
    });

    testWidgets('без отдельных окон — руководство экраном поверх ключа',
        (tester) async {
      final h = await started(storedKey: null, isMobile: true);
      await pumpApp(tester, h.controller,
          size: const Size(400, 800),
          helpWindow: HelpWindowSpy(available: false));
      await settleGuide(tester);

      expect(find.byType(HelpScreen), findsOneWidget);
      await goBack(tester);
      expect(find.byType(HelpScreen), findsNothing);
      expect(find.text('Ключ Яндекс Облака'), findsOneWidget);
      await closeApp(tester, h);
    });
  });

  group('Кнопка «Как пользоваться»', () {
    testWidgets('рядом с настройками, открывает отдельное окно',
        (tester) async {
      final h = await started(settings: const AppSettings(helpShown: true));
      final help = HelpWindowSpy();
      await pumpApp(tester, h.controller, helpWindow: help);

      final button = find.byKey(const ValueKey('help'));
      expect(find.descendant(of: button, matching: find.text('Как пользоваться')),
          findsOneWidget);
      expect(tester.getTopRight(button).dx,
          lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey('settings'))).dx),
          reason: 'слева от «Настроек»');

      await tester.tap(button);
      await tester.pump();
      expect(help.opened, 1);
      expect(find.byType(HelpScreen), findsNothing,
          reason: 'окно открылось — экран не нужен');
      await closeApp(tester, h);
    });

    testWidgets('работает и во время подготовки', (tester) async {
      final h = await started(settings: const AppSettings(helpShown: true));
      final help = HelpWindowSpy();
      await pumpApp(tester, h.controller, helpWindow: help);
      h.controller.debugEmulate(stage: AppStage.starting);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('help')));
      await tester.pump();
      expect(help.opened, 1);
      await closeApp(tester, h);
    });

    testWidgets('нет отдельных окон — руководство экраном поверх программы',
        (tester) async {
      final h = await started(settings: const AppSettings(helpShown: true));
      await pumpApp(tester, h.controller,
          helpWindow: HelpWindowSpy(available: false));

      await tester.tap(find.byKey(const ValueKey('help')));
      await settleGuide(tester);

      expect(find.byType(HelpScreen), findsOneWidget);
      expect(find.text('Как пользоваться Subtitler'), findsOneWidget,
          reason: 'обложка');
      expect(counter(tester), 'Начало · 1 из 14');
      await closeApp(tester, h);
    });
  });

  // Как «Советы» macOS: один шаг на экране, стрелки по бокам.
  group('Экран руководства', () {
    Future<void> pumpGuide(WidgetTester tester,
        {Future<bool> Function(String url)? openLink,
        Size size = const Size(1000, 860)}) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: HelpScreen(openLink: openLink ?? (_) async => true)));
      await settleGuide(tester);
    }

    Finder arrow(String key) => find.byKey(ValueKey(key));

    testWidgets('стрелки листают шаги, на краях — бледнеют', (tester) async {
      await pumpGuide(tester);
      expect(counter(tester), 'Начало · 1 из 14');
      expect(find.text('Как пользоваться Subtitler'), findsOneWidget);

      // Назад с обложки некуда.
      await tester.tap(arrow('help-previous'));
      await tester.pumpAndSettle();
      expect(counter(tester), 'Начало · 1 из 14');

      await tester.tap(arrow('help-next'));
      await tester.pumpAndSettle();
      expect(counter(tester), 'Ключ Яндекс Облака · 2 из 14');
      expect(find.text('Откройте Yandex AI Studio'), findsOneWidget);

      await tester.tap(arrow('help-previous'));
      await tester.pumpAndSettle();
      expect(counter(tester), 'Начало · 1 из 14');
    });

    testWidgets('клавиши ← → листают шаги', (tester) async {
      await pumpGuide(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(counter(tester), 'Ключ Яндекс Облака · 3 из 14');
      expect(find.text('Войдите с аккаунтом Яндекса'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(counter(tester), 'Ключ Яндекс Облака · 2 из 14');
    });

    testWidgets('меню разделов переходит к первому шагу раздела',
        (tester) async {
      await pumpGuide(tester);

      await tester.tap(find.byKey(const ValueKey('help-chapters')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Субтитры для видео').last);
      await tester.pumpAndSettle();
      expect(counter(tester), 'Субтитры для видео · 10 из 14');
      expect(find.text('Откройте видео'), findsOneWidget);

      // Последний шаг — «дальше» некуда.
      await tester.tap(find.byKey(const ValueKey('help-chapters')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Если что-то пошло не так').last);
      await tester.pumpAndSettle();
      await tester.tap(arrow('help-next'));
      await tester.pumpAndSettle();
      expect(counter(tester), 'Если что-то пошло не так · 14 из 14');
    });

    testWidgets('на телефоне шаги тоже помещаются', (tester) async {
      await pumpGuide(tester, size: const Size(360, 640));
      for (var i = 0; i < 14; i++) {
        expect(tester.takeException(), isNull, reason: 'шаг ${i + 1}');
        await tester.tap(arrow('help-next'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('ссылка открывается в браузере', (tester) async {
      final opened = <String>[];
      await pumpGuide(tester, openLink: (url) async {
        opened.add(url);
        return true;
      });
      await tester.tap(arrow('help-next'));
      await tester.pumpAndSettle();

      await tester.tapOnText(find.textRange.ofSubstring('aistudio.yandex.ru'));
      await tester.pump();
      expect(opened, ['https://aistudio.yandex.ru']);
    });

    testWidgets('браузер не открылся — ссылка копируется', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpGuide(tester, openLink: (_) async => false);
      await tester.tap(arrow('help-next'));
      await tester.pumpAndSettle();

      await tester.tapOnText(find.textRange.ofSubstring('aistudio.yandex.ru'));
      await tester.pump();
      expect(copied, 'https://aistudio.yandex.ru');
      expect(find.textContaining('Ссылка скопирована'), findsOneWidget);
    });

    testWidgets('снимок по щелчку открывается крупно', (tester) async {
      await pumpGuide(tester);
      await tester.tap(arrow('help-next'));
      await tester.pumpAndSettle();

      await tester.tap(
          find.bySemanticsLabel('Yandex AI Studio: кнопка «Войти» справа вверху'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });
  });

  group('Ссылки в браузере', () {
    test('Windows — rundll32, адрес одним аргументом', () {
      final c = linkCommand('https://aistudio.yandex.ru/?a=1&b=2',
          operatingSystem: 'windows')!;
      expect(c.executable, 'rundll32.exe');
      expect(c.arguments,
          ['url.dll,FileProtocolHandler', 'https://aistudio.yandex.ru/?a=1&b=2']);
    });

    test('macOS — open', () {
      expect(linkCommand('https://aistudio.yandex.ru', operatingSystem: 'macos')!
          .executable, 'open');
    });

    test('Android и не http(s) — не открываем', () {
      expect(linkCommand('https://aistudio.yandex.ru', operatingSystem: 'android'),
          isNull);
      expect(linkCommand('file:///C:/Windows/system32/calc.exe',
          operatingSystem: 'windows'), isNull);
    });
  });
}
