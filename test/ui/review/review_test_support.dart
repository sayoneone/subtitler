/// Общее для виджет-тестов экрана предпросмотра: контроллер на подделках,
/// поддельный плеер и поиск строк списка.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/player/preview_player.dart';
import 'package:subtitler/ui/player/subtitle_overlay.dart';
import 'package:subtitler/ui/review/cue_list.dart';
import 'package:subtitler/ui/review/review_view.dart';

import '../../support/app_harness.dart';
import '../../support/fake_preview_player.dart';

/// Экран предпросмотра на контроллере-подделке. Каждый плеер, который экран
/// попросил у фабрики, остаётся в [players].
class ReviewRig {
  ReviewRig(this.h);

  final AppHarness h;
  final List<FakePreviewPlayer> players = [];

  AppController get controller => h.controller;

  /// Последний созданный плеер — тот, что сейчас на экране.
  FakePreviewPlayer get player => players.last;

  PreviewPlayer create({DebugLog? log}) {
    final player = FakePreviewPlayer()
      ..loaded(duration: const Duration(minutes: 2));
    players.add(player);
    return player;
  }
}

/// Широкое окно: плеер слева, список справа, все пять реплик видны.
const Size kWideWindow = Size(1280, 900);

Future<ReviewRig> pumpReview(
  WidgetTester tester, {
  Session? session,
  AppSettings settings = const AppSettings(),
  bool isMobile = false,
  Size window = kWideWindow,
  void Function(AppController controller)? setup,
}) async {
  await tester.binding.setSurfaceSize(window);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final h = makeTestController(settings: settings, isMobile: isMobile);
  await h.controller.init();
  h.controller.debugEmulate(
    stage: AppStage.review,
    session: session ?? sampleSession(),
  );
  setup?.call(h.controller);
  final rig = ReviewRig(h);
  await tester.pumpWidget(
    MaterialApp(
      home: ReviewView(controller: h.controller, playerFactory: rig.create),
    ),
  );
  return rig;
}

/// Убирает экран и освобождает контроллер: таймер правок не должен
/// пережить тест.
Future<void> finishReview(WidgetTester tester, ReviewRig rig) async {
  await tester.pumpWidget(const SizedBox());
  await rig.h.dispose();
}

Finder cueRowFinder(int index) =>
    find.byWidgetPredicate((w) => w is CueRow && w.cue.index == index);

CueRow cueRow(WidgetTester tester, int index) =>
    tester.widget<CueRow>(cueRowFinder(index));

Finder translationField(int index) => find.byKey(ValueKey('cue-ru-$index'));

/// Текст, который сейчас нарисован поверх кадра, или `null`.
String? shownSubtitle(WidgetTester tester) {
  final found = find.byType(OutlinedSubtitleText);
  if (found.evaluate().isEmpty) return null;
  return tester.widget<OutlinedSubtitleText>(found).text;
}

Future<void> moveTo(
  WidgetTester tester,
  FakePreviewPlayer player,
  Duration position,
) async {
  player.positionValue.value = position;
  await tester.pump();
}
