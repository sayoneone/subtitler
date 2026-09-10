import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/debug_controller.dart';
import 'ui/debug_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SubtitlerApp(controller: DebugController()));
}

class SubtitlerApp extends StatelessWidget {
  final DebugController controller;
  const SubtitlerApp({super.key, required this.controller});

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
      home: DebugScreen(controller: controller),
    );
  }
}
