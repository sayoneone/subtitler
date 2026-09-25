import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_controller.dart';
import 'app/diagnostics.dart';
import 'app/launch_args.dart';
import 'app/services.dart';
import 'core/logging.dart';
import 'ui/app_shell.dart';
import 'ui/player/preview_player.dart';

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

  const SubtitlerApp({
    super.key,
    required this.controller,
    this.playerFactory = createPreviewPlayer,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Subtitler',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: AppShell(controller: controller, playerFactory: playerFactory),
    );
  }
}
