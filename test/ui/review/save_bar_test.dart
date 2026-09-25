import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/ui/review/save_bar.dart';

/// Полоса сохранения без контроллера: сохранение — это ffmpeg и диск, здесь
/// проверяется, какое действие зовёт каждая кнопка и что видно человеку.

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

SaveBar _bar({
  SaveStatus status = SaveStatus.idle,
  UserError? error,
  bool canSave = true,
  void Function()? onSave,
  void Function(UserErrorAction)? onErrorAction,
}) => SaveBar(
  status: status,
  progress: 0,
  result: null,
  error: error,
  errorLog: '12:00:00 ERROR выдуманная строка журнала',
  isMobile: false,
  canSave: canSave,
  showingResult: false,
  onSave: onSave ?? () {},
  onReveal: () {},
  onViewResult: () {},
  onOtherVideo: () {},
  onErrorAction: onErrorAction ?? (_) {},
);

void main() {
  testWidgets('«Сохранить» вызывает сохранение; пока занято — нет', (
    tester,
  ) async {
    var saves = 0;
    await _pump(tester, _bar(onSave: () => saves++));
    await tester.tap(find.text('Сохранить видео с субтитрами'));
    expect(saves, 1);

    await _pump(tester, _bar(onSave: () => saves++, canSave: false));
    await tester.tap(find.text('Сохранить видео с субтитрами'));
    expect(saves, 1);
  });

  testWidgets('кнопка ошибки — действие по смыслу', (tester) async {
    final actions = <UserErrorAction>[];
    for (final action in [
      UserErrorAction.retry,
      UserErrorAction.changeKey,
      UserErrorAction.home,
    ]) {
      await _pump(
        tester,
        _bar(
          status: SaveStatus.failed,
          error: UserError(title: 'Сбой', hint: 'Что делать', action: action),
          onErrorAction: actions.add,
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, action.label));
    }
    expect(actions, [
      UserErrorAction.retry,
      UserErrorAction.changeKey,
      UserErrorAction.home,
    ]);
  });

  testWidgets('ошибка без действия — без кнопки, «Сохранить» остаётся', (
    tester,
  ) async {
    await _pump(
      tester,
      _bar(
        status: SaveStatus.failed,
        error: const UserError(
          title: 'Субтитры не отрисовались — сообщите разработчику',
          hint: 'Видео не сохранено.',
          details: 'SubtitlesInvisibleException: выдуманные подробности',
        ),
      ),
    );
    expect(find.text('Сохранить видео с субтитрами'), findsOneWidget);
    expect(
      find.bySubtype<FilledButton>(),
      findsOneWidget,
      reason: 'только «Сохранить»',
    );

    // Сырой текст и журнал — только в раскрытых «Технических деталях».
    expect(find.textContaining('выдуманные подробности'), findsNothing);
    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('выдуманные подробности'), findsOneWidget);
    expect(find.textContaining('выдуманная строка журнала'), findsOneWidget);
  });
}
