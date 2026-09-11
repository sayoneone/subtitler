// test/core/library/library_entry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/library_entry.dart';

LibraryEntry _entry(String id, {int bytes = 1000, bool pinned = false}) =>
    LibraryEntry(
      id: id,
      sourceName: '$id.mp4',
      createdAt: DateTime.utc(2026, 9, 11),
      lang: 'tr-TR',
      cueCount: 6,
      flaggedCount: 1,
      pinned: pinned,
      mediaRemoved: false,
      mediaBytes: bytes,
    );

void main() {
  test('Запись переживает сериализацию', () {
    final restored = LibraryEntry.fromJson(_entry('a').toJson());
    expect(restored.id, 'a');
    expect(restored.sourceName, 'a.mp4');
    expect(restored.lang, 'tr-TR');
    expect(restored.cueCount, 6);
    expect(restored.flaggedCount, 1);
    expect(restored.pinned, isFalse);
    expect(restored.mediaRemoved, isFalse);
    expect(restored.mediaBytes, 1000);
    expect(restored.createdAt, DateTime.utc(2026, 9, 11));
  });

  test('Индекс считает занятое место', () {
    final index = LibraryIndex(entries: [
      _entry('a', bytes: 1500),
      _entry('b', bytes: 2500),
    ]);
    expect(index.totalBytes, 4000);
  });

  test('Запись без медиа места не занимает', () {
    final entry = _entry('a', bytes: 5000).copyWith(
      mediaRemoved: true,
      mediaBytes: 0,
    );
    expect(LibraryIndex(entries: [entry]).totalBytes, 0);
    expect(entry.mediaRemoved, isTrue);
  });

  test('Индекс переживает сериализацию', () {
    final index = LibraryIndex(entries: [_entry('a'), _entry('b')]);
    final restored = LibraryIndex.fromJson(index.toJson());
    expect(restored.entries.map((e) => e.id), ['a', 'b']);
  });

  test('Битый индекс читается как пустой, а не роняет приложение', () {
    expect(LibraryIndex.fromJson(const {}).entries, isEmpty);
  });
}
