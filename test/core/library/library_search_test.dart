import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_entry.dart';
import 'package:subtitler/core/library/library_search.dart';

LibraryEntry _e(String id, String name) => LibraryEntry(
      id: id,
      sourceName: name,
      createdAt: DateTime.utc(2026, 9, 11),
      lang: 'tr-TR',
      cueCount: 3,
      flaggedCount: 0,
      pinned: false,
      mediaRemoved: false,
      mediaBytes: 10,
    );

void main() {
  final entries = [_e('1', 'встреча.mp4'), _e('2', 'склад.mp4')];
  final texts = {
    '1': 'Брат, доброе утро. Начинаем работу.',
    '2': 'Весы барахлят, завтра починим.',
  };
  String textOf(String id) => texts[id] ?? '';

  test('Пустой запрос возвращает всё', () {
    expect(searchLibrary(entries, '   ', textOf: textOf).length, 2);
  });

  test('Находит по тексту реплик, а не только по имени файла', () {
    final found = searchLibrary(entries, 'барахлят', textOf: textOf);
    expect(found.single.id, '2');
  });

  test('Находит по имени файла', () {
    expect(searchLibrary(entries, 'встреча', textOf: textOf).single.id, '1');
  });

  test('Регистр не важен', () {
    expect(searchLibrary(entries, 'БРАТ', textOf: textOf).single.id, '1');
  });

  test('Ничего не найдено — пустой список', () {
    expect(searchLibrary(entries, 'вертолёт', textOf: textOf), isEmpty);
  });
}
