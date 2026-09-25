import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/logging.dart';

/// Команда, которая показывает файл в файловом менеджере.
class RevealCommand {
  final String executable;
  final List<String> arguments;

  /// Коды возврата, которые не значат ошибку. Проводник возвращает 1 даже
  /// тогда, когда окно открылось и файл выделен.
  final Set<int> okExitCodes;

  const RevealCommand(this.executable, this.arguments,
      {this.okExitCodes = const {0}});

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

/// Как показать [path] на платформе [operatingSystem] (значения
/// `Platform.operatingSystem`). `null` — на этой платформе показывать
/// файлы нечем (Android: там вместо этого «Поделиться»).
///
/// Windows: `explorer.exe /select, <путь>` — ключ и путь ДВУМЯ
/// аргументами. Одним аргументом (`/select,C:\…`) Dart при пробеле в пути
/// берёт в кавычки всё целиком, и Проводник ключа не видит — открывает
/// «Документы». Проверено на этой машине. Путь с прямыми слешами
/// Проводник тоже не понимает, поэтому он нормализуется.
RevealCommand? revealCommand(String path, {required String operatingSystem}) {
  switch (operatingSystem) {
    case 'windows':
      return RevealCommand(
        'explorer.exe',
        ['/select,', p.windows.normalize(path)],
        okExitCodes: const {0, 1},
      );
    case 'macos':
      return RevealCommand('open', ['-R', path]);
    case 'linux':
      // Выделить файл xdg-open не умеет — открываем папку.
      return RevealCommand('xdg-open', [p.posix.dirname(path)]);
  }
  return null;
}

/// Показывает [path] в Проводнике (Finder, файловом менеджере).
/// `false` — не получилось; причина уходит в журнал, а не человеку:
/// путь к файлу всё равно виден на экране.
Future<bool> revealInFileManager(
  String path, {
  String? operatingSystem,
  DebugLog? log,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
      run,
}) async {
  final journal = log ?? DebugLog.instance;
  final command = revealCommand(path,
      operatingSystem: operatingSystem ?? Platform.operatingSystem);
  if (command == null) {
    journal.warn('Показать файл в папке на этой платформе нельзя: $path');
    return false;
  }
  try {
    final result = await (run ?? Process.run)(
        command.executable, command.arguments);
    if (command.okExitCodes.contains(result.exitCode)) {
      journal.info('Показан в папке: $path');
      return true;
    }
    journal.warn('Не удалось показать файл ($command): код ${result.exitCode}');
    return false;
  } on ProcessException catch (e) {
    journal.warn('Не удалось показать файл ($command): $e');
    return false;
  }
}
