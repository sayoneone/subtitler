/// Видео из командной строки: первый аргумент, не похожий на ключ запуска.
///
/// Так Windows передаёт файл, перетащенный на значок программы или на её
/// ярлык, и файл из «Открыть с помощью». Проверять, видео ли это, здесь не
/// нужно: это сделает обычный путь открытия и скажет человеку понятно.
String? videoArgument(List<String> args) {
  for (final arg in args) {
    final value = arg.trim();
    if (value.isEmpty || value.startsWith('-')) continue;
    return value;
  }
  return null;
}
