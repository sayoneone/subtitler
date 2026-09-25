import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/player/preview_player.dart';
import 'package:subtitler/ui/review/review_view.dart';

import '../../support/app_harness.dart';
import '../../support/fake_preview_player.dart';
import 'review_test_support.dart';

/// Кнопки экрана, за которыми платная обработка, ffmpeg или диск (смена
/// языка, «Продолжить распознавание», сохранение). Настоящие методы
/// контроллера здесь подменены записью вызова: проверяется, что экран
/// зовёт нужное действие с нужным языком и в нужном порядке, а что делает
/// само действие — дело тестов контроллера.
class _SpyController extends AppController {
  _SpyController(AppHarness h, this.events)
    : super(
        services: h.controller.services,
        log: h.log,
        editSaveDelay: const Duration(hours: 1),
      );

  final List<String> events;

  /// Пока не завершён — «идёт работа» (как при бесплатной смене языка).
  Completer<void>? gate;

  bool _busy = false;

  @override
  bool get isBusy => _busy || super.isBusy;

  Future<void> _hold(String event) async {
    events.add(event);
    final wait = gate;
    if (wait == null) return;
    _busy = true;
    notifyListeners();
    await wait.future;
    _busy = false;
    notifyListeners();
  }

  @override
  Future<void> switchLanguage(String lang) => _hold('switch $lang');

  @override
  Future<void> openVideo(String path) => _hold('open $path');

  @override
  Future<void> confirmLongVideo() => _hold('confirm long');

  @override
  Future<void> save() => _hold('save');

  @override
  Future<void> goHome() => _hold('home');

  @override
  void changeKey() => events.add('change key');
}

class _LoggingPlayer extends FakePreviewPlayer {
  _LoggingPlayer(this.events);

  final List<String> events;

  @override
  Future<void> pause() {
    events.add('pause');
    return super.pause();
  }
}

class _Rig {
  _Rig(this.h, this.controller, this.events, this.player);

  final AppHarness h;
  final _SpyController controller;
  final List<String> events;
  final _LoggingPlayer player;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Задержанное действие должно доиграть до освобождения контроллера:
    // иначе оно оповестило бы уже освобождённый.
    final wait = controller.gate;
    if (wait != null && !wait.isCompleted) wait.complete();
    await tester.pump();
    controller.debugDiscardPendingEdits();
    controller.dispose();
    await h.dispose();
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Session? session,
  AppSettings settings = const AppSettings(),
}) async {
  await tester.binding.setSurfaceSize(kWideWindow);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final h = makeTestController(settings: settings);
  final events = <String>[];
  final controller = _SpyController(h, events);
  await controller.init();
  controller.debugEmulate(
    stage: AppStage.review,
    session: session ?? sampleSession(),
  );
  late _LoggingPlayer player;
  PreviewPlayer create({DebugLog? log}) =>
      player = _LoggingPlayer(events)..loaded();
  await tester.pumpWidget(
    MaterialApp(
      home: ReviewView(controller: controller, playerFactory: create),
    ),
  );
  return _Rig(h, controller, events, player);
}

void main() {
  group('Смена языка', () {
    testWidgets('пункт меню: пауза, смена на выбранный язык, пока идёт — '
        'полоса и правка закрыта', (tester) async {
      final rig = await _pump(
        tester,
        settings: const AppSettings(
          detectionCandidates: ['tr-TR', 'uz-UZ', 'kk-KZ'],
        ),
      );
      rig.controller.gate = Completer<void>();

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('казахский'));
      await tester.pump();
      await tester.pump();

      expect(rig.events, ['pause', 'switch kk-KZ']);
      expect(find.text('Переключаем язык на казахский…'), findsOneWidget);
      expect(tester.widget<TextField>(translationField(1)).enabled, isFalse);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('review-language-menu')),
            )
            .enabled,
        isFalse,
        reason: 'второй раз не переключить, пока идёт первый',
      );

      rig.controller.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Переключаем язык на казахский…'), findsNothing);
      expect(tester.widget<TextField>(translationField(1)).enabled, isTrue);
      rig.controller.gate = null;
      await rig.finish(tester);
    });

    testWidgets('кнопка на плашке низкой уверенности — второй язык', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        session: sampleSession(confidence: LanguageConfidence.low),
      );

      await tester.tap(find.text('Распознать как узбекский'));
      await tester.pump();
      expect(rig.events, ['pause', 'switch uz-UZ']);
      await rig.finish(tester);
    });

    testWidgets('«Другой язык…» — выбранный в диалоге язык', (tester) async {
      final rig = await _pump(tester);

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Другой язык…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('иврит'));
      await tester.pumpAndSettle();

      expect(rig.events, ['pause', 'switch he-IL']);
      await rig.finish(tester);
    });
  });

  testWidgets('«Продолжить распознавание» — то же видео, на паузе', (
    tester,
  ) async {
    final s = sampleSession();
    final partial = s.copyWith(
      cues: [
        for (final c in s.cues)
          c.index > 3
              ? c.copyWith(
                  orig: '',
                  ru: '',
                  status: CueStatus.pending,
                  flags: const {},
                )
              : c,
      ],
    );
    final rig = await _pump(tester, session: partial);

    await tester.tap(find.text('Продолжить распознавание'));
    await tester.pump();
    expect(rig.events, ['pause', 'open ${partial.videoPath}']);
    await rig.finish(tester);
  });

  testWidgets('длинный ролик: «Продолжить» подтверждает', (tester) async {
    final rig = await _pump(tester);
    rig.controller.debugEmulate(
      longVideoQuestion: const LongVideoQuestion(
        videoPath: '/видео/дело 1/clip.mp4',
        duration: Duration(hours: 1, minutes: 5),
      ),
    );
    await tester.pump();
    expect(find.text('Ролик длинный — 1 ч 5 мин'), findsOneWidget);

    await tester.tap(find.text('Продолжить'));
    await tester.pump();
    expect(rig.events, ['confirm long']);
    await rig.finish(tester);
  });

  group('Сохранение', () {
    testWidgets('сначала пауза, потом сохранение; повторное нажатие не '
        'запускает второе', (tester) async {
      final rig = await _pump(tester);
      rig.controller.gate = Completer<void>();

      await tester.tap(find.text('Сохранить видео с субтитрами'));
      await tester.pump();
      await tester.tap(
        find.text('Сохранить видео с субтитрами'),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(rig.events, ['pause', 'save']);
      rig.controller.gate!.complete();
      rig.controller.gate = null;
      await tester.pump();
      await rig.finish(tester);
    });

    testWidgets('«Повторить» в ошибке сохраняет заново', (tester) async {
      final rig = await _pump(tester);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.failed,
        saveError: const UserError(
          title: 'Нет доступа к файлу',
          hint: 'Закройте плеер.',
          action: UserErrorAction.retry,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Повторить'));
      await tester.pump();
      expect(rig.events, ['pause', 'save']);
      await rig.finish(tester);
    });

    testWidgets('«Другое видео» — на главный экран', (tester) async {
      final rig = await _pump(tester);
      await tester.tap(find.text('Другое видео'));
      await tester.pump();
      expect(rig.events, ['home']);
      await rig.finish(tester);
    });
  });
}
