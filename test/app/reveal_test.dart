import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/reveal.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  group('revealCommand', () {
    test('Windows: ключ и путь — два отдельных аргумента', () {
      const path = r'C:\Users\Иван Петров\Видео\ролик 1_ru.mp4';
      final command = revealCommand(path, operatingSystem: 'windows')!;
      expect(command.executable, 'explorer.exe');
      // Одним аргументом «/select,C:\…» Dart берёт в кавычки целиком, и
      // Проводник ключа не видит.
      expect(command.arguments, ['/select,', path]);
    });

    test('Windows: прямые слеши превращаются в обратные', () {
      final command = revealCommand('C:/дело/clip_ru.mp4',
          operatingSystem: 'windows')!;
      expect(command.arguments.last.trimRight(), r'C:\дело\clip_ru.mp4');
    });

    test('Windows: путь без пробелов тоже уходит в кавычках — запятая и «=» '
        'его не режут', () {
      // Проводник считает запятую и «=» разделителями, если путь не в
      // кавычках, и открывает Рабочий стол вместо папки с файлом. Dart
      // берёт аргумент в кавычки, только если в нём есть пробел
      // (табуляция, кавычка), поэтому в аргументе должен быть пробел: в
      // конце пути его отбрасывает сам Проводник.
      for (final path in [
        r'C:\Дела\12,13\VID_0001_ru.mp4',
        r'C:\Дела\a=b\VID_0001_ru.mp4',
        r'C:\Дела\VID,3_ru.mp4',
        r'C:\Дела\VID_0001_ru.mp4',
      ]) {
        final command = revealCommand(path, operatingSystem: 'windows')!;
        expect(command.arguments.first, '/select,');
        final argument = command.arguments.last;
        expect(argument, contains(' '),
            reason: 'без пробела Dart не возьмёт в кавычки $path');
        expect(argument.trimRight(), path);
      }
    });

    test('Windows: путь с пробелом не меняется — кавычки поставит Dart', () {
      const path = r'C:\Дела\12, 13\VID_0001_ru.mp4';
      expect(revealCommand(path, operatingSystem: 'windows')!.arguments.last,
          path);
    });

    test('Windows: код возврата 1 Проводника — не ошибка', () {
      final command = revealCommand(r'C:\a.mp4', operatingSystem: 'windows')!;
      expect(command.okExitCodes, containsAll([0, 1]));
    });

    test('macOS: open -R', () {
      final command =
          revealCommand('/Users/a/clip_ru.mp4', operatingSystem: 'macos')!;
      expect(command.executable, 'open');
      expect(command.arguments, ['-R', '/Users/a/clip_ru.mp4']);
      expect(command.okExitCodes, {0});
    });

    test('Linux: открывается папка', () {
      final command =
          revealCommand('/home/a/clip_ru.mp4', operatingSystem: 'linux')!;
      expect(command.executable, 'xdg-open');
      expect(command.arguments, ['/home/a']);
    });

    test('Android: показывать нечем — там «Поделиться»', () {
      expect(revealCommand('/data/a.mp4', operatingSystem: 'android'), isNull);
    });
  });

  group('revealInFileManager', () {
    test('код 1 от Проводника считается успехом', () async {
      final calls = <List<String>>[];
      final ok = await revealInFileManager(
        r'C:\дело\clip_ru.mp4',
        operatingSystem: 'windows',
        log: DebugLog(),
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(1, 1, '', '');
        },
      );
      expect(ok, isTrue);
      // Пробел в конце — чтобы Dart взял путь в кавычки (см. revealCommand).
      expect(calls.single, ['explorer.exe', '/select,', r'C:\дело\clip_ru.mp4 ']);
    });

    test('ненулевой код на macOS — неудача, но без исключения', () async {
      final ok = await revealInFileManager('/a.mp4',
          operatingSystem: 'macos',
          log: DebugLog(),
          run: (_, _) async => ProcessResult(1, 1, '', ''));
      expect(ok, isFalse);
    });

    test('программа не запустилась — неудача, причина в журнале', () async {
      final log = DebugLog();
      final ok = await revealInFileManager('/a.mp4',
          operatingSystem: 'linux',
          log: log,
          run: (_, _) async => throw const ProcessException('xdg-open', []));
      expect(ok, isFalse);
      expect(log.asText(), contains('Не удалось показать файл'));
    });
  });
}
