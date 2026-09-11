import 'library_entry.dart';

/// Ищет по имени исходника и по тексту реплик.
///
/// Поиск по тексту здесь главный: через месяц имя файла не помнит никто,
/// а фразу из разговора — вполне.
List<LibraryEntry> searchLibrary(
  List<LibraryEntry> entries,
  String query, {
  required String Function(String id) textOf,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return entries;
  return entries.where((entry) {
    if (entry.sourceName.toLowerCase().contains(needle)) return true;
    return textOf(entry.id).toLowerCase().contains(needle);
  }).toList();
}
