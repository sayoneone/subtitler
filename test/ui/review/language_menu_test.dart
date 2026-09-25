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
  LanguageCopy? copy,
  bool runnerUp = false,
}) => LanguageChoice(
  code: code,
  name: name,
  copy: copy ?? (ready ? LanguageCopy.ready : LanguageCopy.none),
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

    // Замечание ревью P5: начатое на втором языке оплачено и не пропало —
    // «оплачивается» без оговорки звучало бы как «распознать заново».
    testWidgets('второй язык начат или распознан — платно только оставшееся',
        (tester) async {
      for (final (copy, mark) in [
        (LanguageCopy.started, 'уже начато — оплачивается только оставшееся'),
        (
          LanguageCopy.recognized,
          'уже распознано — оплачивается только перевод',
        ),
      ]) {
        await _pump(
          tester,
          LanguageDoubtPlate(
            languageTitle: 'турецкий',
            confidence: LanguageConfidence.low,
            runnerUp: _choice('uz-UZ', 'узбекский', copy: copy, runnerUp: true),
            enabled: true,
            onSwitch: (_) {},
          ),
        );
        expect(find.text(mark), findsOneWidget, reason: '$copy');
        expect(find.text('оплачивается'), findsNothing, reason: '$copy');
      }
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

    // Замечание ревью P5: язык, на котором обработку остановили, был
    // подписан «распознать заново — оплачивается», как язык, на котором
    // нет ничего.
    testWidgets('начатый и распознанный без перевода языки подписаны честно',
        (tester) async {
      final choices = [
        _choice('uz-UZ', 'узбекский', copy: LanguageCopy.started),
        _choice('kk-KZ', 'казахский', copy: LanguageCopy.recognized),
        _choice('ru-RU', 'русский'),
      ];
      await _pump(
        tester,
        ReviewHeader(
          total: 5,
          toCheck: 0,
          languageTitle: 'турецкий',
          choices: choices,
          allChoices: choices,
          hasEdits: false,
          enabled: true,
          onSwitch: (_) {},
        ),
      );
      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();

      Finder mark(String language, String text) => find.descendant(
        of: find.widgetWithText(PopupMenuItem<String>, language),
        matching: find.text(text),
      );
      expect(
        mark('узбекский', 'начато — доделать, оплачивается только оставшееся'),
        findsOneWidget,
      );
      expect(
        mark(
          'казахский',
          'распознано — осталось перевести, оплачивается только перевод',
        ),
        findsOneWidget,
      );
      expect(
        mark('русский', 'распознать заново — оплачивается'),
        findsOneWidget,
      );

      await tester.tap(find.text('Другой язык…'));
      await tester.pumpAndSettle();
      Finder short(String code, String text) => find.descendant(
        of: find.byKey(ValueKey('other-language-$code')),
        matching: find.text(text),
      );
      expect(short('uz-UZ', 'начато'), findsOneWidget);
      expect(short('kk-KZ', 'распознано'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('other-language-ru-RU')),
          matching: find.byType(Text),
        ),
        findsOneWidget,
        reason: 'у языка без копии — только название',
      );
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
