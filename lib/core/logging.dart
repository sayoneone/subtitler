import 'dart:async';
import 'dart:io';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  const LogEntry(this.time, this.level, this.message);

  String get stamp {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  @override
  String toString() => '$stamp ${level.name.toUpperCase().padRight(5)} $message';
}

/// Журнал для отладки: держит записи в памяти и раздаёт их интерфейсу.
///
/// Главное требование — в журнал НИКОГДА не должен попасть API-ключ.
/// Поэтому все секреты регистрируются через [redact] и вырезаются из
/// каждого сообщения, даже если их случайно подставили в текст ошибки.
class DebugLog {
  static final DebugLog instance = DebugLog();

  static const int maxEntries = 5000;

  final List<LogEntry> entries = [];
  final Set<String> _secrets = {};
  final _controller = StreamController<LogEntry>.broadcast();

  IOSink? _fileSink;
  String? filePath;

  Stream<LogEntry> get stream => _controller.stream;

  /// Дублирует журнал в файл, чтобы разбирать проблему можно было и после
  /// закрытия приложения. Старый файл перезаписывается: интересен последний
  /// запуск, а не история за месяц.
  void attachFile(String path) {
    try {
      _fileSink?.close();
      final file = File(path);
      file.parent.createSync(recursive: true);
      _fileSink = file.openWrite(mode: FileMode.write);
      filePath = path;
      for (final entry in entries) {
        _fileSink!.writeln(entry);
      }
      info('Журнал пишется в файл: $path');
    } catch (e) {
      filePath = null;
      warn('Не удалось открыть файл журнала $path: $e');
    }
  }

  /// Помечает строку как секрет: дальше она нигде не появится в журнале.
  void redact(String? secret) {
    if (secret != null && secret.length >= 8) _secrets.add(secret);
  }

  String _mask(String message) {
    var result = message;
    for (final secret in _secrets) {
      result = result.replaceAll(secret, '***КЛЮЧ***');
    }
    return result;
  }

  void add(LogLevel level, String message) {
    final entry = LogEntry(DateTime.now(), level, _mask(message));
    entries.add(entry);
    if (entries.length > maxEntries) entries.removeAt(0);
    if (!_controller.isClosed) _controller.add(entry);
    try {
      _fileSink?.writeln(entry);
    } catch (_) {
      // Файл журнала — вспомогательная вещь, ронять из-за него работу нельзя.
    }
  }

  void debug(String message) => add(LogLevel.debug, message);
  void info(String message) => add(LogLevel.info, message);
  void warn(String message) => add(LogLevel.warn, message);
  void error(String message) => add(LogLevel.error, message);

  void clear() => entries.clear();

  String asText() => entries.join('\n');
}
