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
///
/// Журнал человека просят сохранить и отправить разработчику, поэтому в
/// нём нет и материалов дела: текст записей в журнал не пишется, а папки
/// с видео прячутся так же, как ключ ([hideFolderOf]).
class DebugLog {
  static final DebugLog instance = DebugLog();

  static const int maxEntries = 5000;

  final List<LogEntry> entries = [];
  final Set<String> _secrets = {};

  /// Папки с видео, длинные первыми: вложенная папка прячется целиком, а
  /// не так, что от неё остаётся хвост после родительской.
  final List<String> _folders = [];
  final _controller = StreamController<LogEntry>.broadcast();

  IOSink? _fileSink;
  String? filePath;

  Stream<LogEntry> get stream => _controller.stream;

  /// Куда откладывается журнал прошлого запуска: рядом с [path].
  static String previousPath(String path) =>
      path.endsWith('.log')
          ? '${path.substring(0, path.length - 4)}.prev.log'
          : '$path.prev';

  /// Дублирует журнал в файл, чтобы разбирать проблему можно было и после
  /// закрытия приложения. Хранятся два запуска — текущий и прошлый: история
  /// за месяц не нужна, а вот журнал сбоя нужен и после перезапуска, ведь
  /// первое, что человек делает при ошибке, — перезапускает программу.
  void attachFile(String path) {
    try {
      _fileSink?.close();
      final file = File(path);
      file.parent.createSync(recursive: true);
      _keepPrevious(file);
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

  void _keepPrevious(File file) {
    if (!file.existsSync()) return;
    try {
      final previous = File(previousPath(file.path));
      if (previous.existsSync()) previous.deleteSync();
      file.renameSync(previous.path);
    } catch (_) {
      // Файл держит второй экземпляр приложения — тогда просто
      // перезапишем текущий, журнал всё равно важнее его истории.
    }
  }

  /// Дописывает всё в файл и закрывает его.
  Future<void> close() async {
    final sink = _fileSink;
    _fileSink = null;
    if (sink == null) return;
    await sink.flush();
    await sink.close();
  }

  /// Помечает строку как секрет: дальше она нигде не появится в журнале.
  void redact(String? secret) {
    if (secret != null && secret.length >= 8) _secrets.add(secret);
  }

  /// Прячет папку файла [filePath]: во всех записях журнала — в памяти, в
  /// файле, в «Технических деталях», в «Сохранить журнал» — вместо неё
  /// «…», а имя файла остаётся. В пути к видео бывают название дела и
  /// фамилии, разработчику они не нужны. Действует на записи, сделанные
  /// после вызова, — звать до первой записи с этим путём.
  void hideFolderOf(String filePath) {
    final folder = File(filePath).parent.path;
    // Корень диска или «.»: прятать там нечего, а маска съела бы любые
    // пути журнала.
    if (Directory(folder).parent.path == folder) return;
    final variants = {
      folder,
      // Тот же путь с другими разделителями: путь к одному и тому же
      // файлу приходит и с «/», и с «\».
      folder.replaceAll(r'\', '/'),
      folder.replaceAll('/', r'\'),
      // Так путь с апострофом выглядит в строке команды ffmpeg.
      folder.replaceAll("'", r"'\''"),
    };
    for (final variant in variants) {
      if (!_folders.contains(variant)) _folders.add(variant);
    }
    _folders.sort((a, b) => b.length.compareTo(a.length));
  }

  /// Вырезает из [message] все секреты, зарегистрированные через [redact],
  /// и папки с видео ([hideFolderOf]). Нужна не только журналу: текст
  /// ошибки, который интерфейс покажет в «Технических деталях», проходит
  /// через ту же маску.
  String mask(String message) {
    var result = message;
    for (final secret in _secrets) {
      result = result.replaceAll(secret, '***КЛЮЧ***');
    }
    for (final folder in _folders) {
      result = result.replaceAll(folder, '…');
    }
    return result;
  }

  void add(LogLevel level, String message) {
    final entry = LogEntry(DateTime.now(), level, mask(message));
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
