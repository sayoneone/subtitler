import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/runtime.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/app/video_probe.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/ui/app_shell.dart';
import 'package:subtitler/ui/log_panel.dart';
import 'package:subtitler/ui/review/review_view.dart';

import '../support/app_harness.dart';
import '../support/counting_log.dart';
import '../support/fake_preview_player.dart';
import 'support.dart';

void main() {
  testWidgets('на экране предпросмотра сообщение и вопрос о длинном ролике '
      'показываются по одному разу', (tester) async {
    // Их показывает оболочка над любым экраном. Экран предпросмотра рисовал
    // их ещё раз у себя, и следователь видел одно и то же дважды: плашку
    // над экраном и такую же в шапке, диалог и плашку с теми же кнопками.
    final h = await started();
    final session = sampleSession();
    h.controller.debugEmulate(stage: AppStage.review, session: session);
    await pumpApp(tester, h.controller);

    h.controller.debugEmulate(
      notice: const UserError(
        title: 'Не удалось переключить язык',
        hint: 'Повторите через минуту.',
      ),
    );
    await tester.pump();
    expect(find.text('Не удалось переключить язык'), findsOneWidget);

    h.controller.dismissNotice();
    h.controller.debugEmulate(
      longVideoQuestion: LongVideoQuestion(
        videoPath: session.videoPath,
        duration: const Duration(minutes: 42),
      ),
    );
    // Не pumpAndSettle: плеер-подделка оболочки не «загружает» видео, и в
    // кадре крутится индикатор ожидания первого кадра.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Ролик длинный'), findsNothing,
        reason: 'вопрос задаёт диалог оболочки, второй плашки быть не должно');

    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Отмена')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.controller.longVideoQuestion, isNull);
    await closeApp(tester, h);
  });

  testWidgets('главный экран: ни слова про ffmpeg и язык, журнал закрыт',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);

    expect(find.text('Subtitler'), findsOneWidget);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);
    expect(find.text('Выбрать файл'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text.toLowerCase(), isNot(contains('ffmpeg')));
      expect(text.toLowerCase(), isNot(contains('язык')));
    }
    expect(find.byType(LogPanel), findsNothing,
        reason: 'журнал по умолчанию скрыт');

    await closeApp(tester, h);
  });

  testWidgets('«⋮ → Журнал работы» выдвигает журнал, «Закрыть» убирает',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);

    await openMenu(tester);
    await tester.tap(find.text('Журнал работы'));
    await tester.pumpAndSettle();
    expect(find.byType(LogPanel), findsOneWidget);
    expect(find.textContaining('Запуск приложения'), findsOneWidget);

    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.byType(LogPanel), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('Ctrl+Shift+L открывает и закрывает журнал', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);

    await pressLogShortcut(tester);
    expect(find.byType(LogPanel), findsOneWidget);
    await pressLogShortcut(tester);
    expect(find.byType(LogPanel), findsNothing);

    // Без Shift — не наше сочетание.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(LogPanel), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('Ctrl+Shift+L не выдвигает журнал под открытыми настройками',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    await openSettings(tester);

    await pressLogShortcut(tester);
    await goBack(tester);
    expect(find.byType(LogPanel), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('журнал, открытый и закрытый много раз, не копит подписки',
      (tester) async {
    final h = await started();
    final log = CountingLog();
    final controller = AppController(services: h.controller.services, log: log);
    await controller.init();
    await pumpApp(tester, controller);

    for (var i = 0; i < 3; i++) {
      await pressLogShortcut(tester);
      expect(log.listeners, 1);
      await pressLogShortcut(tester);
      expect(log.listeners, 0);
    }

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await h.dispose();
  });

  testWidgets('отладочный стенд в меню — только для разработчика',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    await openMenu(tester);
    expect(find.text('Журнал работы'), findsOneWidget);
    expect(find.text('Отладочный стенд'), findsNothing);
    await tester.tapAt(const Offset(10, 400)); // закрыть меню
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    // SUBTITLER_DEBUG=1 или отладочная сборка.
    final developer = AppController(
      services: h.controller.services.copyWith(debugStandAvailable: true),
      log: h.log,
    );
    await developer.init();
    await pumpApp(tester, developer);
    await openMenu(tester);
    expect(find.text('Отладочный стенд'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    developer.dispose();
    await h.dispose();
  });

  testWidgets('стенд из меню работает на готовых папках приложения',
      (tester) async {
    final h = await started();
    final developer = AppController(
      services: h.controller.services.copyWith(debugStandAvailable: true),
      log: h.log,
    );
    await developer.init();
    await pumpApp(tester, developer);

    await openMenu(tester);
    await tester.tap(find.text('Отладочный стенд'));
    await tester.pumpAndSettle();

    expect(find.text('Subtitler — отладочный стенд'), findsOneWidget);
    // Стенд не готовит папки заново: иначе журнал переоткрылся бы с нуля.
    expect(h.log.entries.map((e) => e.message),
        contains('Открыт отладочный стенд'));
    expect(h.log.entries.map((e) => e.message),
        isNot(contains('Запуск приложения (отладочный стенд)')));
    // Журнал на стенде — та же панель, подробные записи видны сразу.
    final panel = tester.widget<LogPanel>(find.byType(LogPanel));
    expect(panel.showDebugInitially, isTrue);
    expect(panel.onClear, isNotNull);

    // Закрыть стенд — назад к приложению, без ошибок при закрытии.
    await goBack(tester);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    developer.dispose();
    await h.dispose();
  });

  testWidgets('пока программа готовится — «Подготовка…», настройки закрыты',
      (tester) async {
    final h = makeTestController();
    final never = Completer<AppRuntime>();
    final controller = AppController(
      services: h.controller.services
          .copyWith(prepareRuntime: (_) => never.future),
      log: h.log,
    );
    await pumpApp(tester, controller);

    expect(find.text('Подготовка…'), findsOneWidget);
    final settings =
        tester.widget<TextButton>(find.byKey(const ValueKey('settings')));
    expect(settings.onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await h.dispose();
  });

  testWidgets('перетаскивание выключено, пока идёт работа и под настройками',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    bool dropEnabled() =>
        tester.widget<DropTarget>(find.byType(DropTarget)).enable;

    expect(dropEnabled(), isTrue);

    await openSettings(tester);
    await goBack(tester);
    expect(dropEnabled(), isTrue);

    h.controller.debugEmulate(
      stage: AppStage.processing,
      videoPath: '/видео/дело 3/беседа.mp4',
      progress: const ProcessingProgress(ProcessingStep.preparingAudio),
    );
    await tester.pump();
    expect(dropEnabled(), isFalse,
        reason: 'иначе результат одного видео запишется под именем другого');

    await closeApp(tester, h);
  });

  testWidgets('на экране предпросмотра перетаскивание выключено, пока '
      'сохраняется видео', (tester) async {
    // Замечание ревью c30: при сохранении этап остаётся review, и приём
    // файлов выключает только isBusy в canOpenVideo — раньше это не
    // проверял ни один тест.
    final h = await started();
    h.controller.debugEmulate(stage: AppStage.review, session: sampleSession());
    await pumpApp(tester, h.controller);
    bool dropEnabled() =>
        tester.widget<DropTarget>(find.byType(DropTarget)).enable;
    expect(dropEnabled(), isTrue);

    for (final status in [SaveStatus.burning, SaveStatus.verifying]) {
      h.controller.debugEmulate(saveStatus: status, saveProgress: 0.3);
      await tester.pump();
      expect(dropEnabled(), isFalse, reason: status.name);
    }

    h.controller.debugEmulate(saveStatus: SaveStatus.idle);
    await tester.pump();
    expect(dropEnabled(), isTrue, reason: 'сохранение кончилось');

    await closeApp(tester, h);
  });

  testWidgets('под открытыми настройками перетаскивание не принимается',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    await openSettings(tester);

    final drop = tester.widget<DropTarget>(
        find.byType(DropTarget, skipOffstage: false));
    expect(drop.enable, isFalse);

    await closeApp(tester, h);
  });

  testWidgets('не видео — короткое сообщение, экран тот же', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);

    h.controller.debugEmulate(
      notice: describeError(
        const NotAVideoException(
            '/документы/справка.docx', 'Invalid data found when processing input'),
        mask: h.log.mask,
      ),
    );
    await tester.pump();
    expect(find.text('Это не видео или файл повреждён'), findsOneWidget);
    expect(find.text('Выберите видеофайл: mp4, mov, mkv, avi и другие.'),
        findsOneWidget);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);
    expect(find.textContaining('Invalid data'), findsNothing);

    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pump();
    expect(find.text('Это не видео или файл повреждён'), findsNothing);
    expect(h.controller.notice, isNull);

    await closeApp(tester, h);
  });

  testWidgets('ролик длиннее 15 минут — сначала вопрос «Продолжить?»',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);

    h.controller.debugEmulate(
      longVideoQuestion: const LongVideoQuestion(
        videoPath: '/видео/дело 5/долгая беседа.mp4',
        duration: Duration(minutes: 42, seconds: 5),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
        find.textContaining('«долгая беседа.mp4» длится 42 мин 5 с — дольше '
            '15 минут'),
        findsOneWidget);
    expect(find.text('Продолжить'), findsOneWidget);

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.controller.longVideoQuestion, isNull);
    expect(h.controller.stage, AppStage.home);

    await closeApp(tester, h);
  });

  testWidgets('«Выбрать файл» открывает диалог выбора', (tester) async {
    final h = await started();
    var asked = 0;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        controller: h.controller,
        playerFactory: ({DebugLog? log}) => FakePreviewPlayer(),
        pickVideo: () async {
          asked++;
          return null; // человек передумал
        },
      ),
    ));
    await tester.tap(find.text('Выбрать файл'));
    await tester.pump();
    expect(asked, 1);
    expect(h.controller.stage, AppStage.home);

    await closeApp(tester, h);
  });

  testWidgets('Android: без перетаскивания, кнопка «Выбрать видео»',
      (tester) async {
    final h = await started(isMobile: true);
    await pumpApp(tester, h.controller, size: const Size(400, 800));

    expect(find.byType(DropTarget), findsNothing);
    expect(find.text('Перетащите видео сюда'), findsNothing);
    expect(find.text('Выбрать видео'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('предпросмотр получает контроллер и фабрику плеера оболочки',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
        stage: AppStage.review, session: sampleSession());
    await tester.pump();

    final review = tester.widget<ReviewView>(find.byType(ReviewView));
    expect(review.controller, same(h.controller));
    expect(review.playerFactory(), isA<FakePreviewPlayer>());

    await closeApp(tester, h);
  });

  testWidgets('телефон: все экраны помещаются в узкое окно', (tester) async {
    const phone = Size(360, 640);
    final h = await started(isMobile: true);
    await pumpApp(tester, h.controller, size: phone);
    final c = h.controller;

    void show(AppStage stage) {
      c.debugEmulate(
        stage: stage,
        videoPath: '/storage/видео/очень длинное имя файла беседы.mp4',
        partial: sampleSession(),
        progress: const ProcessingProgress(ProcessingStep.recognizing,
            done: 12, total: 130),
        error: describeError(
            const AuthException(
                statusCode: 403, message: 'У ключа нет роли ai.translate.user'),
            mask: h.log.mask),
        notice: describeError(
            const NotAVideoException('/storage/документ.pdf', 'не видео'),
            mask: h.log.mask),
      );
    }

    for (final stage in [
      AppStage.home,
      AppStage.needsKey,
      AppStage.processing,
      AppStage.cancelled,
      AppStage.failed,
    ]) {
      show(stage);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: stage.name);
    }

    show(AppStage.home);
    await tester.pump();
    await openSettings(tester);
    expect(tester.takeException(), isNull, reason: 'настройки');
    await goBack(tester);

    await pressLogShortcut(tester);
    expect(find.byType(LogPanel), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'журнал');

    await closeApp(tester, h);
  });

  testWidgets('закрытие окна дописывает отложенную правку и журнал',
      (tester) async {
    // Запись на диск — настоящий ввод-вывод, поэтому всё, что его
    // трогает, идёт в настоящем времени (runAsync), а не в поддельном.
    final h = (await tester.runAsync(started))!;
    final video = p.join(h.root.path, 'videos', 'беседа.mp4');
    Directory(p.dirname(video)).createSync(recursive: true);
    await pumpApp(tester, h.controller);
    await tester.runAsync(() async {
      h.controller.debugEmulate(
          stage: AppStage.review, session: sampleSession(videoPath: video));
      // Задержка записи правок в тестах — час: без закрытия окна правка
      // на диск не попала бы.
      h.controller.updateTranslation(1, 'правка перед закрытием окна');
    });

    final response = await tester
        .runAsync(() => tester.binding.handleRequestAppExit());

    expect(response, AppExitResponse.exit);
    expect(File('$video.subtitler.json').readAsStringSync(),
        contains('правка перед закрытием окна'));
    expect(h.log.entries.last.message, 'Окно закрыто');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.dispose);
  });
}
