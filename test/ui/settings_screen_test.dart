import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/ui/log_panel.dart';
import 'package:subtitler/ui/settings_screen.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';
import 'support.dart';

/// Настройки — длинный список: окно повыше, чтобы всё было на экране.
const _tall = Size(1280, 1800);

bool _chipSelected(WidgetTester tester, String code) => tester
    .widget<FilterChip>(find.byKey(ValueKey('language-$code')))
    .selected;

void main() {
  testWidgets('ключ: значение не показывается, удаление — только после '
      'подтверждения', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Ключ сохранён.'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text, isNot(contains(kTestApiKey)));
      expect(text, isNot(contains('AQVN-')));
    }

    // Передумал.
    await tester.tap(find.text('Удалить ключ'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить ключ?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(h.keyStore.value, kTestApiKey);
    expect(h.controller.hasKey, isTrue);
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Подтвердил.
    await tester.tap(find.text('Удалить ключ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(h.keyStore.value, isNull);
    expect(h.controller.hasKey, isFalse);
    expect(h.controller.stage, AppStage.needsKey);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Проверить и сохранить'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«Заменить ключ» — экран ключа, откуда можно вернуться',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    await tester.tap(find.text('Заменить ключ'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Проверить и сохранить'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    expect(h.controller.stage, AppStage.home);
    expect(h.keyStore.value, kTestApiKey);

    await closeApp(tester, h);
  });

  testWidgets('во время обработки ключ не трогается', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller, size: _tall);
    h.controller.debugEmulate(
      stage: AppStage.processing,
      videoPath: '/видео/дело 2/звонок.mp4',
      progress: const ProcessingProgress(ProcessingStep.recognizing,
          done: 1, total: 5),
    );
    await tester.pump();
    await openSettings(tester);

    for (final label in ['Заменить ключ', 'Удалить ключ']) {
      final button = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
      expect(button.onPressed, isNull, reason: label);
    }

    await closeApp(tester, h);
  });

  testWidgets('языки записей — чипы меняют настройку, слова «кандидаты» нет',
      (tester) async {
    final h = await started();
    final store = h.settingsStore as MemorySettingsStore;
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    expect(find.text('Языки ваших записей'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text.toLowerCase(), isNot(contains('кандидат')));
    }
    expect(_chipSelected(tester, 'tr-TR'), isTrue);
    expect(_chipSelected(tester, 'uz-UZ'), isTrue);
    expect(_chipSelected(tester, 'kk-KZ'), isFalse);
    expect(find.byType(FilterChip), findsNWidgets(16));

    await tester.tap(find.text('казахский'));
    await tester.pump();
    expect(h.controller.settings.detectionCandidates,
        ['tr-TR', 'uz-UZ', 'kk-KZ']);
    expect(store.value.detectionCandidates, ['tr-TR', 'uz-UZ', 'kk-KZ'],
        reason: 'настройка сохраняется, а не живёт до закрытия');
    expect(_chipSelected(tester, 'kk-KZ'), isTrue);

    await tester.tap(find.text('турецкий'));
    await tester.pump();
    expect(h.controller.settings.detectionCandidates, ['uz-UZ', 'kk-KZ']);
    expect(_chipSelected(tester, 'tr-TR'), isFalse);

    // Последний язык не снимается: выбирать было бы не из чего.
    await tester.tap(find.text('узбекский'));
    await tester.pump();
    await tester.tap(find.text('казахский'));
    await tester.pump();
    expect(h.controller.settings.detectionCandidates, ['kk-KZ']);
    expect(_chipSelected(tester, 'kk-KZ'), isTrue);
    expect(find.textContaining('Хотя бы один язык'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«О программе»: версия; ffmpeg — только в свёрнутых '
      'технических сведениях', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    expect(find.text('Subtitler, версия 0.0.0-test'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text.toLowerCase(), isNot(contains('ffmpeg')));
    }
    await tester.tap(find.text('Технические сведения'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Версия: ffmpeg (тестовый)'), findsOneWidget);
    expect(find.textContaining('libass: есть'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«Открыть журнал» закрывает настройки и выдвигает журнал',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    await tester.tap(find.text('Открыть журнал'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(LogPanel), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«Открыть папку с журналом» показывает файл журнала',
      (tester) async {
    final h = await started();
    // Как будто журнал этого запуска пишется в файл. Настоящий файл тут
    // не нужен: запись в него шла бы мимо поддельного времени теста.
    h.log.filePath = '${h.root.path}/support/subtitler.log';
    await pumpApp(tester, h.controller, size: _tall);
    await openSettings(tester);

    await tester.tap(find.text('Открыть папку с журналом'));
    await tester.pump();
    expect(h.revealed, [h.log.filePath]);

    await closeApp(tester, h);
  });
}
