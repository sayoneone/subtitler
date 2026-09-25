import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import 'strings.dart';

/// Действия с журналом, общие для боковой панели, настроек и сообщений об
/// ошибке. Разработчику нужен файл, а человеку — понятно, где он лежит,
/// поэтому сохранённый журнал сразу показывается в Проводнике (на
/// телефоне — отдаётся в «Поделиться»).

/// Подпись кнопки сохранения журнала на этой платформе.
String saveLogLabel(AppController c) =>
    c.isMobile ? AppStrings.shareLog : AppStrings.saveLog;

/// Подпись кнопки «папка с журналом» на этой платформе.
String logFolderLabel(AppController c) =>
    c.isMobile ? AppStrings.logShare : AppStrings.logOpenFolder;

/// «Сохранить журнал»: весь журнал запуска — в файл в папке программы, и
/// этот файл сразу показан.
Future<void> saveLogAndShow(BuildContext context, AppController c) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final path = await c.exportLog();
    await c.showInFolder(path);
    messenger?.showSnackBar(SnackBar(content: Text(AppStrings.logSaved(path))));
  } catch (e) {
    c.log.error('Не удалось сохранить журнал: $e');
    messenger?.showSnackBar(
        const SnackBar(content: Text(AppStrings.logSaveFailed)));
  }
}

/// «Открыть папку с журналом»: файл журнала этого запуска в Проводнике.
Future<void> showLogFile(BuildContext context, AppController c) async {
  final path = c.logFilePath;
  if (path == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(AppStrings.logFileMissing)));
    return;
  }
  await c.showInFolder(path);
}

/// «Скопировать» с подтверждением.
Future<void> copyText(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(const SnackBar(content: Text(AppStrings.copied)));
}
