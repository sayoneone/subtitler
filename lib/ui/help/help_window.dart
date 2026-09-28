import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logging.dart';
import '../strings.dart';

/// Канал запускалки, которая открывает руководство отдельным окном
/// (windows/runner/help_window.cpp, macos/Runner/HelpWindow.swift).
///
/// Метод `open` с заголовком окна: окно создаётся со своим движком Flutter
/// и точкой входа `helpMain` (lib/main.dart), а если оно уже открыто —
/// выводится вперёд. Ответ `true` — окно на экране.
const MethodChannel kHelpChannel = MethodChannel('ru.subtitler/help');

/// Открывает руководство отдельным окном. `false` — на этой платформе
/// отдельных окон нет (Android, виджет-тесты) или окно не открылось:
/// тогда руководство показывается экраном внутри программы.
Future<bool> openHelpWindow({
  MethodChannel channel = kHelpChannel,
  DebugLog? log,
}) async {
  try {
    final opened = await channel.invokeMethod<bool>(
        'open', {'title': AppStrings.helpWindowTitle});
    return opened ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    (log ?? DebugLog.instance)
        .warn('Окно руководства не открылось: ${e.code} ${e.message ?? ''}');
    return false;
  }
}

/// Команда, которая открывает [url] в браузере на платформе
/// [operatingSystem] (значения `Platform.operatingSystem`). `null` — на
/// этой платформе браузер отсюда не открыть (Android) или адрес не
/// http(s).
///
/// Windows: `rundll32 url.dll,FileProtocolHandler` — адрес уходит
/// браузеру по умолчанию одним аргументом, без разбора командной
/// строкой `cmd`, для которой `&` в адресе — разделитель команд.
({String executable, List<String> arguments})? linkCommand(
  String url, {
  required String operatingSystem,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
    return null;
  }
  return switch (operatingSystem) {
    'windows' => (
        executable: 'rundll32.exe',
        arguments: ['url.dll,FileProtocolHandler', url],
      ),
    'macos' => (executable: 'open', arguments: [url]),
    'linux' => (executable: 'xdg-open', arguments: [url]),
    _ => null,
  };
}

/// Открывает [url] в браузере. `false` — не вышло: адрес тогда
/// копируется, а человек открывает его сам.
Future<bool> openLinkInBrowser(
  String url, {
  String? operatingSystem,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
      run,
}) async {
  final command = linkCommand(url,
      operatingSystem: operatingSystem ?? Platform.operatingSystem);
  if (command == null) return false;
  try {
    final result =
        await (run ?? Process.run)(command.executable, command.arguments);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
