import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/debug_controller.dart';
import '../app/user_error.dart';
import '../core/logging.dart';
import 'debug_screen.dart';
import 'error_panel.dart';
import 'help/help_view.dart';
import 'help/help_window.dart' as help;
import 'home_view.dart';
import 'log_actions.dart';
import 'log_panel.dart';
import 'onboarding_view.dart';
import 'player/preview_player.dart';
import 'processing_view.dart';
import 'review/review_view.dart';
import 'settings_screen.dart';
import 'strings.dart';

/// Оболочка приложения: заголовок «Subtitler», «Как пользоваться»,
/// «⚙ Настройки», меню «⋮» и один экран на этап контроллера.
///
/// Руководство открывается отдельным окном, а где его нет (Android) —
/// экраном поверх программы. При первом запуске оно открывается само
/// ([AppController.takeFirstLaunchHelp]).
///
/// Журнал работы по умолчанию скрыт: он живёт в боковой панели справа и
/// выдвигается пунктом «⋮ → Журнал работы» или сочетанием Ctrl+Shift+L.
/// Перетаскивание видео принимается здесь же, над любым экраном, — но
/// только когда контроллер готов взять новое видео (`canOpenVideo`): во
/// время работы `DropTarget` выключен, иначе результат одного ролика
/// записался бы под именем другого.
class AppShell extends StatefulWidget {
  final AppController controller;

  /// Плеер для предпросмотра; в виджет-тестах — подделка.
  final PreviewPlayer Function({DebugLog? log}) playerFactory;

  /// Диалог выбора видео; в виджет-тестах — подделка.
  final Future<String?> Function() pickVideo;

  /// Отдельное окно руководства: `false` — окна нет, руководство
  /// показывается экраном. В виджет-тестах — подделка.
  final Future<bool> Function() openHelpWindow;

  const AppShell({
    super.key,
    required this.controller,
    this.playerFactory = createPreviewPlayer,
    this.pickVideo = pickVideoFile,
    this.openHelpWindow = help.openHelpWindow,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

enum _MenuItem { log, debugStand }

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final AppLifecycleListener _lifecycle;

  /// Экран оболочки сейчас сверху: не закрыт настройками, стендом или
  /// диалогом. Иначе сочетание клавиш открывало бы невидимый журнал, а
  /// перетаскивание — видео «сквозь» настройки.
  bool _routeIsCurrent = true;

  bool _dragging = false;
  bool _longVideoDialogOpen = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onHide: () => unawaited(c.flush()),
    );
    help.kHelpChannel.setMethodCallHandler(_onHelpChannelCall);
    unawaited(c.init());
    _maybeAskLongVideo();
    _maybeShowFirstLaunchHelp();
  }

  @override
  void didUpdateWidget(covariant AppShell old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      unawaited(widget.controller.init());
    }
  }

  @override
  void dispose() {
    help.kHelpChannel.setMethodCallHandler(null);
    HardwareKeyboard.instance.removeHandler(_onKey);
    c.removeListener(_onChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeAskLongVideo();
    _maybeShowFirstLaunchHelp();
  }

  /// Окно закрывают: сохранение и подготовка звука останавливаются, их
  /// временные файлы удаляются, правки, которые ещё ждут своей задержки, —
  /// на диск, журнал — в файл. Дольше нескольких секунд закрытие не держим.
  Future<AppExitResponse> _onExitRequested() async {
    try {
      await c.prepareToExit().timeout(const Duration(seconds: 10));
    } catch (e) {
      c.log.warn('Подготовка к закрытию не закончилась: $e');
    }
    // Последняя строка журнала отличает обычное закрытие от падения.
    c.log.info('Окно закрыто');
    await c.log.close();
    return AppExitResponse.exit;
  }

  /// Главное окно закрывают, пока открыто руководство. Flutter в этом
  /// случае Dart о выходе не спрашивает (он спрашивает, только когда
  /// закрывается последнее окно процесса), поэтому запускалка Windows
  /// закрывает руководство сама и спрашивает здесь
  /// (windows/runner/flutter_window.cpp). Ответ — можно закрываться.
  Future<Object?> _onHelpChannelCall(MethodCall call) async {
    if (call.method != 'exit') throw MissingPluginException();
    await _onExitRequested();
    return null;
  }

  // -------------------------------------------------------------- журнал

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyL) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        !keyboard.isShiftPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    if (!mounted || !_routeIsCurrent) return false;
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return false;
    if (scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    } else {
      scaffold.openEndDrawer();
    }
    return true;
  }

  void _openLog() => _scaffoldKey.currentState?.openEndDrawer();

  // ------------------------------------------------------ другие экраны

  void _openSettings() {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        controller: c,
        onOpenLog: () {
          Navigator.of(context).pop();
          _openLog();
        },
      ),
    )));
  }

  /// «Как пользоваться»: отдельное окно, а если его нет — экран.
  Future<void> _openHelp() async {
    if (await widget.openHelpWindow()) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const HelpScreen(),
    ));
  }

  void _maybeShowFirstLaunchHelp() {
    if (!c.takeFirstLaunchHelp()) return;
    // После кадра: экран этапа (ключ или главный) уже на месте, и экран
    // руководства ляжет поверх него, а не под него.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openHelp());
    });
  }

  void _openDebugStand() {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _DebugStandPage(controller: c),
    )));
  }

  void _onMenu(_MenuItem item) => switch (item) {
        _MenuItem.log => _openLog(),
        _MenuItem.debugStand => _openDebugStand(),
      };

  /// Ролик длиннее 15 минут: спросить, продолжать ли (§5). Вопрос может
  /// появиться на любом экране, куда можно перетащить видео, поэтому
  /// диалог — дело оболочки.
  void _maybeAskLongVideo() {
    final question = c.longVideoQuestion;
    if (question == null || _longVideoDialogOpen) return;
    _longVideoDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _longVideoDialogOpen = false;
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(AppStrings.longVideoTitle),
          content: Text(AppStrings.longVideoText(
              question.fileName, question.duration, c.longVideoThreshold)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(AppStrings.longVideoContinue),
            ),
          ],
        ),
      );
      _longVideoDialogOpen = false;
      if (!mounted || !identical(c.longVideoQuestion, question)) return;
      if (go == true) {
        unawaited(c.confirmLongVideo());
      } else {
        c.declineLongVideo();
      }
    });
  }

  // ------------------------------------------------------------- сборка

  @override
  Widget build(BuildContext context) {
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text(AppStrings.appTitle),
        actions: [
          // На телефоне и в узком окне — только значок: две подписи и
          // меню в строку заголовка не помещаются.
          if (c.isMobile || width < 600)
            IconButton(
              key: const ValueKey('help'),
              tooltip: AppStrings.help,
              onPressed: () => unawaited(_openHelp()),
              icon: const Icon(Icons.help_outline),
            )
          else
            TextButton.icon(
              key: const ValueKey('help'),
              onPressed: () => unawaited(_openHelp()),
              icon: const Icon(Icons.help_outline),
              label: const Text(AppStrings.help),
            ),
          TextButton.icon(
            key: const ValueKey('settings'),
            onPressed: c.stage == AppStage.starting ? null : _openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text(AppStrings.settings),
          ),
          PopupMenuButton<_MenuItem>(
            key: const ValueKey('menu'),
            tooltip: AppStrings.more,
            icon: const Icon(Icons.more_vert),
            onSelected: _onMenu,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MenuItem.log,
                child: ListTile(
                  leading: Icon(Icons.article_outlined),
                  title: Text(AppStrings.menuLog),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (c.debugStandAvailable) ...[
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: _MenuItem.debugStand,
                  // Стенд без готовых папок сам вызвал бы
                  // AppRuntime.prepare и переоткрыл журнал с нуля.
                  enabled: c.stage != AppStage.starting,
                  child: const ListTile(
                    leading: Icon(Icons.developer_mode),
                    title: Text(AppStrings.menuDebugStand),
                    subtitle: Text(AppStrings.menuDebugStandHint),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      endDrawer: Drawer(
        width: math.min(560, width * 0.9),
        child: SafeArea(
          child: LogPanel(
            log: c.log,
            onSave: () => unawaited(saveLogAndShow(context, c)),
            onOpenFolder: () => unawaited(showLogFile(context, c)),
            openFolderLabel: logFolderLabel(c),
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          ),
        ),
      ),
      // Мышью у правого края журнал выдвигался бы случайно.
      endDrawerEnableOpenDragGesture: false,
      body: Column(children: [
        if (c.notice != null)
          _NoticeBanner(notice: c.notice!, onClose: c.dismissNotice),
        Expanded(child: _withDrop(_screen())),
      ]),
    );
  }

  Widget _screen() => switch (c.stage) {
        AppStage.starting => const _StartingView(),
        AppStage.broken => BrokenView(controller: c),
        AppStage.needsKey => OnboardingView(
            controller: c,
            onOpenHelp: () => unawaited(_openHelp()),
          ),
        AppStage.home => HomeView(
            controller: c,
            dragging: _dragging,
            pickVideo: widget.pickVideo,
          ),
        AppStage.processing => ProcessingView(controller: c),
        AppStage.cancelled => CancelledView(controller: c),
        AppStage.failed => FailedView(controller: c),
        AppStage.review =>
          ReviewView(controller: c, playerFactory: widget.playerFactory),
      };

  /// Перетаскивание — только на десктопе и только когда видео можно
  /// открыть. На других экранах, кроме главного, поверх показываем, что
  /// будет, если отпустить файл.
  Widget _withDrop(Widget screen) {
    if (c.isMobile) return screen;
    final enabled = c.canOpenVideo && _routeIsCurrent;
    final hovering = enabled && _dragging;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        if (details.files.isEmpty) return;
        // Не ждём: Future закончится только вместе с обработкой.
        unawaited(c.openVideo(details.files.first.path));
      },
      child: Stack(fit: StackFit.expand, children: [
        screen,
        if (hovering && c.stage != AppStage.home) const _DropOverlay(),
      ]),
    );
  }
}

class _StartingView extends StatelessWidget {
  const _StartingView();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(AppStrings.starting,
              style: Theme.of(context).textTheme.titleMedium),
        ]),
      );
}

/// Короткое сообщение, которое этап не меняет: «это не видео», «в этом
/// видео нет звука». Кнопки действия у него нет — только «Закрыть».
class _NoticeBanner extends StatelessWidget {
  final UserError notice;
  final VoidCallback onClose;

  const _NoticeBanner({required this.notice, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.amber.withValues(alpha: 0.22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          Icon(Icons.info_outline, color: Colors.orange.shade900),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(notice.title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text(notice.hint, style: theme.textTheme.bodyMedium),
            ]),
          ),
          IconButton(
            tooltip: AppStrings.close,
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ]),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Container(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        alignment: Alignment.center,
        child: Text(AppStrings.dropToOpen,
            style: theme.textTheme.headlineSmall
                ?.copyWith(color: theme.colorScheme.primary)),
      ),
    );
  }
}

/// Отладочный стенд из меню: те же папки, ffmpeg и хранилище ключа, что у
/// приложения (`AppController.debugStand`), — повторной подготовки нет.
class _DebugStandPage extends StatefulWidget {
  final AppController controller;
  const _DebugStandPage({required this.controller});

  @override
  State<_DebugStandPage> createState() => _DebugStandPageState();
}

class _DebugStandPageState extends State<_DebugStandPage> {
  late final DebugController _stand = widget.controller.debugStand();

  @override
  void dispose() {
    _stand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DebugScreen(controller: _stand);
}
