/// Запись файла, оборванная на середине: программу закрыли или она упала
/// между открытием файла и записью данных.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Процесс «умер» посреди записи. Не [FileSystemException]: код, который
/// пишет файл, не должен принять это за отказ в доступе и уйти в запасную
/// папку — после настоящего обрыва он уже ничего не делает.
class InterruptedWrite implements Exception {
  final String path;
  const InterruptedWrite(this.path);

  @override
  String toString() => 'Запись $path оборвана';
}

/// Выполняет [body] так, будто каждая запись файла целиком
/// (`writeAsString`) обрывается сразу после открытия файла.
///
/// Открытие в режиме [FileMode.write] сразу обнуляет существующий файл
/// (документация [FileMode.write]: «The file is overwritten if it already
/// exists»), а данные пишутся следующей операцией. Обрыв между ними
/// оставляет пустой файл — это и воспроизводится: файл обнуляется, затем
/// бросается [InterruptedWrite]. Остальные операции с файлами настоящие.
Future<T> interruptingWrites<T>(Future<T> Function() body) =>
    IOOverrides.runZoned(
      body,
      createFile: (path) => _InterruptedFile(Zone.root.run(() => File(path))),
    );

/// Настоящий файл, у которого обрывается только запись целиком. Методы,
/// которые хранилищу сессий не нужны, не реализованы — тест, который на
/// них наткнётся, упадёт с понятным сообщением.
class _InterruptedFile implements File {
  _InterruptedFile(this._real);

  final File _real;

  @override
  String get path => _real.path;

  @override
  Uri get uri => _real.uri;

  @override
  File get absolute => _real.absolute;

  @override
  Directory get parent => _real.parent;

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<bool> exists() => _real.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _real.readAsString(encoding: encoding);

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _real.readAsStringSync(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    _real.writeAsStringSync(''); // открытие на запись уже обнулило файл
    throw InterruptedWrite(path);
  }

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);

  @override
  File renameSync(String newPath) => _real.renameSync(newPath);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  void deleteSync({bool recursive = false}) =>
      _real.deleteSync(recursive: recursive);

  @override
  DateTime lastModifiedSync() => _real.lastModifiedSync();

  @override
  Future<DateTime> lastModified() => _real.lastModified();

  @override
  FileStat statSync() => _real.statSync();

  @override
  Future<FileStat> stat() => _real.stat();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'interruptingWrites: ${invocation.memberName} не поддержан');
}
