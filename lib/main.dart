import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_controller.dart';
import 'app/diagnostics.dart';
import 'app/launch_args.dart';
import 'app/services.dart';
import 'core/logging.dart';
import 'ui/app_shell.dart';
import 'ui/help/help_view.dart';
import 'ui/help/help_window.dart' as help;
import 'ui/player/preview_player.dart';
import 'ui/strings.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final log = DebugLog.instance;
  // Первым делом: всё, что упадёт дальше, должно попасть в журнал, а не
  // только в консоль, которой у следователя нет.
  installErrorLogging(log);
  initPreviewPlayers(log: log);
  // Настоящие сервисы (AppServices.real). Отладочный стенд открывается из
  // меню и берёт у контроллера уже готовые папки, ffmpeg и хранилище.
  final controller = launchController(args, log: log);
  // Бросили видео на значок, когда окно уже открыто: второй копии нет,
  // запускалка передаёт путь этой.
  unawaited(listenForOtherLaunches(controller.receiveFromAnotherLaunch));
  runApp(SubtitlerApp(controller: controller));
}

/// Окно «Как пользоваться»: отдельное окно со своим движком Flutter.
/// Запускалка (windows/runner/help_window.cpp, macos/Runner/HelpWindow.swift)
/// ищет эту функцию по имени в главной библиотеке; `vm:entry-point` не
/// даёт сборке выбросить её как неиспользуемую.
@pragma('vm:entry-point')
void helpMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HelpApp());
}

/// Контроллер программы, запущенной с аргументами [args]: видео,
/// перетащенное на значок или ярлык, приходит аргументом запуска и
/// открывается само. Отдельной функцией — чтобы связку «аргумент → видео»
/// проверял тест: раньше main() аргументы вовсе не читал.
AppController launchController(
  List<String> args, {
  DebugLog? log,
  AppServices? services,
}) =>
    AppController(
      log: log,
      services: services,
      openOnStart: videoArgument(args),
    );

class SubtitlerApp extends StatelessWidget {
  final AppController controller;

  /// Плеер предпросмотра; в тестах — подделка.
  final PreviewPlayer Function({DebugLog? log}) playerFactory;

  /// Отдельное окно руководства; в тестах — подделка.
  final Future<bool> Function() openHelpWindow;

  const SubtitlerApp({
    super.key,
    required this.controller,
    this.playerFactory = createPreviewPlayer,
    this.openHelpWindow = help.openHelpWindow,
  });

  @override
  Widget build(BuildContext context) => _app(
        title: AppStrings.appTitle,
        home: AppShell(
          controller: controller,
          playerFactory: playerFactory,
          openHelpWindow: openHelpWindow,
        ),
      );
}

/// Приложение окна «Как пользоваться» ([helpMain]).
class HelpApp extends StatelessWidget {
  const HelpApp({super.key});

  @override
  Widget build(BuildContext context) => _app(
        title: AppStrings.helpWindowTitle,
        home: const HelpScreen(),
      );
}

/// Общее для главного окна и окна руководства: русская локаль и тема.
MaterialApp _app({required String title, required Widget home}) =>
    MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: home,
    );
