import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('log_test_');
    path = '${tmp.path}${Platform.pathSeparator}subtitler.log';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> runOnce(String message) async {
    final log = DebugLog()..attachFile(path);
    log.info(message);
    await log.close();
  }

  test('Журнал прошлого запуска не затирается новым', () async {
    // Человек при сбое первым делом перезапускает программу. Раньше новый
    // запуск перезаписывал subtitler.log, и журнал сбоя пропадал.
    await runOnce('запуск со сбоем');
    await runOnce('следующий запуск');

    final previous = File(DebugLog.previousPath(path)).readAsStringSync();
    final current = File(path).readAsStringSync();
    expect(previous, contains('запуск со сбоем'));
    expect(current, contains('следующий запуск'));
    expect(current, isNot(contains('запуск со сбоем')));
  });

  test('Хранятся только два запуска', () async {
    await runOnce('первый');
    await runOnce('второй');
    await runOnce('третий');

    final previous = File(DebugLog.previousPath(path)).readAsStringSync();
    expect(previous, contains('второй'));
    expect(previous, isNot(contains('первый')));
    expect(File(path).readAsStringSync(), contains('третий'));
  });

  test('Имя файла прошлого запуска стоит рядом с текущим', () {
    expect(DebugLog.previousPath(r'C:\app\subtitler.log'),
        r'C:\app\subtitler.prev.log');
    expect(DebugLog.previousPath('/tmp/journal'), '/tmp/journal.prev');
  });
}
