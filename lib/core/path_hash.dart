/// FNV-1a от пути. `String.hashCode` не обещает одинаковых значений между
/// версиями Dart, а имена рабочей и запасной папки и файлов в ней должны
/// пережить обновление приложения: иначе после него уже нарезанное
/// пришлось бы резать заново, сессия из запасной папки не нашлась бы, а
/// результат ложился бы в новую папку.
String stablePathHash(String path) {
  var hash = 0x811c9dc5;
  for (final unit in path.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
