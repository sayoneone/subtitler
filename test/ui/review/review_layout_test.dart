/// Экран предпросмотра в тесных окнах: окно, приставленное к углу экрана,
/// масштаб Windows 125–150 %, крупный шрифт, телефон. Экран не должен
/// падать, переполняться и сжимать видео или список в ноль, а нужные
/// кнопки — уходить туда, откуда их не достать.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/main.dart';
import 'package:subtitler/ui/review/cue_list.dart';

import '../../support/app_harness.dart';
import '../../support/fake_preview_player.dart';

/// Где и как показан экран: клиентская часть окна в логических точках,
/// масштаб экрана и масштаб шрифта.
class _Screen {
  const _Screen(this.name, this.size, {this.scale = 1, this.text = 1,
      this.isMobile = false});

  /// Окно Windows [window] (внешний размер в пикселях экрана) при масштабе
  /// [scale]: без заголовка (около 31 точки) и рамок (около 8 с каждой
  /// стороны).
  factory _Screen.window(Size window, double scale, {double text = 1}) =>
      _Screen(
        'окно ${window.width.round()}×${window.height.round()}, масштаб '
        '${(scale * 100).round()} %${text == 1 ? '' : ', шрифт '
            '${(text * 100).round()} %'}',
        Size(window.width / scale - 16, window.height / scale - 39),
        scale: scale,
        text: text,
      );

  final String name;
  final Size size;
  final double scale;
  final double text;
  final bool isMobile;
}

final _screens = [
  for (final window in const [
    Size(800, 600),
    Size(1024, 640),
    Size(1280, 720),
  ]) ...[
    for (final scale in const [1.0, 1.25, 1.5]) _Screen.window(window, scale),
    _Screen.window(window, 1, text: 1.5),
  ],
  // Четверть экрана 1920×1080 при 150 %: окно приставлено к углу. Раньше
  // здесь весь экран предпросмотра становился серым прямоугольником.
  const _Screen('угол экрана 1920×1080 при 150 %', Size(640, 344),
      scale: 1.5),
  // Телефон: без строки состояния Android (24 точки).
  const _Screen('телефон 360×640', Size(360, 616), scale: 3, isMobile: true),
  const _Screen('телефон 360×640, шрифт 130 %', Size(360, 616),
      scale: 3, text: 1.3, isMobile: true),
];

enum _Save { idle, saving, savedInFallback, viewingResult, failedWithDetails }

/// Сессия, где сверху видны все плашки сразу: язык под вопросом, нарезка
/// без пауз, остановленная обработка.
Session _allPlates() {
  final s = sampleSession(
    confidence: LanguageConfidence.low,
    forcedSplit: true,
  );
  return s.copyWith(cues: [
    for (final c in s.cues)
      c.index == 5
          ? c.copyWith(status: CueStatus.pending, flags: const {})
          : c,
  ]);
}

final _sessions = {
  'обычная сессия': sampleSession,
  'все плашки': _allPlates,
};

Future<AppHarness> _show(
  WidgetTester tester,
  _Screen screen,
  Session session,
  _Save save,
) async {
  tester.view.devicePixelRatio = screen.scale;
  tester.view.physicalSize = screen.size * screen.scale;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = screen.text;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final h = makeTestController(isMobile: screen.isMobile);
  await h.controller.init();
  // «Технические детали» ошибки показывают последние 40 строк журнала —
  // после обработки ролика они там всегда есть.
  for (var i = 0; i < 60; i++) {
    h.log.info('выдуманная строка журнала номер $i: сегмент обработан');
  }
  final c = h.controller;
  c.debugEmulate(stage: AppStage.review, session: session);
  switch (save) {
    case _Save.idle:
      break;
    case _Save.saving:
      c.debugEmulate(saveStatus: SaveStatus.burning, saveProgress: 0.47);
    case _Save.savedInFallback:
    case _Save.viewingResult:
      c.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: const SaveResult(
          videoPath: '/программа/output/clip_ru.mp4',
          origSrtPath: '/программа/output/clip_orig.srt',
          ruSrtPath: '/программа/output/clip_ru.srt',
          inFallback: true,
        ),
      );
    case _Save.failedWithDetails:
      c.debugEmulate(
        saveStatus: SaveStatus.failed,
        saveError: describeError(
          StateError('Не удалось вшить субтитры: выдуманный вывод ffmpeg'),
          mask: h.log.mask,
        ),
      );
  }
  await tester.pumpWidget(SubtitlerApp(
    controller: c,
    playerFactory: ({DebugLog? log}) => FakePreviewPlayer()..loaded(),
  ));
  await tester.pump();
  final press = switch (save) {
    _Save.failedWithDetails => 'Технические детали',
    _Save.viewingResult => 'Посмотреть результат',
    _ => null,
  };
  if (press != null) {
    await tester.ensureVisible(find.text(press));
    await tester.pumpAndSettle();
    await tester.tap(find.text(press));
    await tester.pumpAndSettle();
  }
  return h;
}

/// Кнопку можно нажать: её можно докрутить до видимого места, и там её
/// ничто не заслоняет.
Future<void> _expectReachable(WidgetTester tester, String text) async {
  final button = find.text(text);
  expect(button, findsOneWidget, reason: '«$text» на экране');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  final window = Offset.zero &
      (tester.view.physicalSize / tester.view.devicePixelRatio);
  final rect = tester.getRect(button);
  expect(window.contains(rect.center), isTrue,
      reason: '«$text» за краем окна: $rect');
  expect(button.hitTestable(), findsOneWidget, reason: '«$text» заслонён');
}

void main() {
  for (final screen in _screens) {
    for (final MapEntry(key: sessionName, value: session) in _sessions.entries) {
      for (final save in _Save.values) {
        testWidgets('${screen.name}; $sessionName; ${save.name}',
            (tester) async {
          final h = await _show(tester, screen, session(), save);
          expect(tester.takeException(), isNull);

          // Видео и список не сжаты в полоску.
          final frame =
              tester.getRect(find.byKey(FakePreviewPlayer.frameKey));
          expect(frame.height, greaterThanOrEqualTo(60), reason: 'видео');
          final list = tester.getRect(find.byType(CueList));
          expect(list.height, greaterThanOrEqualTo(60), reason: 'список');

          switch (save) {
            case _Save.idle:
              await _expectReachable(tester, 'Сохранить видео с субтитрами');
              await _expectReachable(tester, 'Другое видео');
            case _Save.saving:
              // Между числом и знаком процента — неразрывный пробел.
              await _expectReachable(
                  tester, 'Сохраняем видео с субтитрами… 47 %');
            case _Save.savedInFallback:
              await _expectReachable(tester, 'Посмотреть результат');
              await _expectReachable(tester, 'Другое видео');
            case _Save.viewingResult:
              await _expectReachable(tester, 'Вернуться к правке');
              await _expectReachable(tester, 'Другое видео');
            case _Save.failedWithDetails:
              await _expectReachable(tester, 'Повторить');
              await _expectReachable(tester, 'Сохранить журнал');
              await _expectReachable(tester, 'Другое видео');
          }
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox());
          await h.dispose();
        });
      }
    }
  }
}
