import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/review/review_header.dart';

/// Смена языка — платное действие контроллера, поэтому шапка проверяется
/// отдельно: вместо контроллера — запись вызовов.

LanguageChoice _choice(
  String code,
  String name, {
  bool ready = false,
  bool runnerUp = false,
}) => LanguageChoice(
  code: code,
  name: name,
  ready: ready,
  probedCues: 0,
  isRunnerUp: runnerUp,
);

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  group('Плашка сомнения в языке', () {
    testWidgets('кнопка переключает на второй язык', (tester) async {
      final switched = <String>[];
      await _pump(
        tester,
        LanguageDoubtPlate(
          languageTitle: 'турецкий',
          confidence: LanguageConfidence.low,
          runnerUp: _choice('uz-UZ', 'узбекский', runnerUp: true),
          enabled: true,
          onSwitch: switched.add,
        ),
      );

      await tester.tap(find.text('Распознать как узбекский'));
      expect(switched, ['uz-UZ']);
    });

    testWidgets('второй язык уже распознан — «бесплатно»', (tester) async {
      await _pump(
        tester,
        LanguageDoubtPlate(
          languageTitle: 'турецкий',
          confidence: LanguageConfidence.low,
          runnerUp: _choice('uz-UZ', 'узбекский', ready: true, runnerUp: true),
          enabled: true,
          onSwitch: (_) {},
        ),
      );
      expect(find.text('уже готово — бесплатно'), findsOneWidget);
      expect(find.text('оплачивается'), findsNothing);
    });

    testWidgets('пока идёт работа, кнопка не нажимается', (tester) async {
      final switched = <String>[];
      await _pump(
        tester,
        LanguageDoubtPlate(
          languageTitle: 'турецкий',
          confidence: LanguageConfidence.low,
          runnerUp: _choice('uz-UZ', 'узбекский', runnerUp: true),
          enabled: false,
          onSwitch: switched.add,
        ),
      );
      await tester.tap(find.text('Распознать как узбекский'));
      expect(switched, isEmpty);
    });

    testWidgets('язык не определился — подсказка про меню', (tester) async {
      await _pump(
        tester,
        LanguageDoubtPlate(
          languageTitle: 'турецкий',
          confidence: LanguageConfidence.none,
          runnerUp: null,
          enabled: true,
          onSwitch: (_) {},
        ),
      );
      expect(
        find.textContaining('определить не удалось — выбран турецкий'),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('Меню «Не тот язык?»', () {
    Widget header(List<String> switched, {bool enabled = true}) => ReviewHeader(
      total: 5,
      toCheck: 3,
      languageTitle: 'турецкий',
      choices: [
        _choice('uz-UZ', 'узбекский', runnerUp: true),
        _choice('kk-KZ', 'казахский'),
      ],
      allChoices: [
        _choice('uz-UZ', 'узбекский', runnerUp: true),
        _choice('kk-KZ', 'казахский'),
        _choice('he-IL', 'иврит', ready: true),
      ],
      hasEdits: false,
      enabled: enabled,
      onSwitch: switched.add,
    );

    testWidgets('пункт меню переключает на свой язык', (tester) async {
      final switched = <String>[];
      await _pump(tester, header(switched));

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('казахский'));
      await tester.pumpAndSettle();
      expect(switched, ['kk-KZ']);
    });

    testWidgets('«Другой язык…» — диалог со всеми языками', (tester) async {
      final switched = <String>[];
      await _pump(tester, header(switched));

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Другой язык…'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialogOption), findsNWidgets(3));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('other-language-he-IL')),
          matching: find.text('готово'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('иврит'));
      await tester.pumpAndSettle();
      expect(switched, ['he-IL']);
      expect(find.byType(SimpleDialog), findsNothing);
    });

    testWidgets('пока идёт работа, меню не открывается', (tester) async {
      await _pump(tester, header([], enabled: false));
      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      expect(find.text('Другой язык…'), findsNothing);
    });

    testWidgets('нечего проверять — в шапке только число реплик', (
      tester,
    ) async {
      await _pump(
        tester,
        ReviewHeader(
          total: 5,
          toCheck: 0,
          languageTitle: 'турецкий',
          choices: const [],
          allChoices: const [],
          hasEdits: false,
          enabled: true,
          onSwitch: (_) {},
          onNextToCheck: () {},
        ),
      );
      expect(find.text('Реплик 5'), findsOneWidget);
      expect(find.byTooltip('Следующая на проверку'), findsNothing);
    });
  });
}
