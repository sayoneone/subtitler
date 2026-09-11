// test/core/library/cleanup_policy_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/library/cleanup_policy.dart';
import 'package:subtitler/core/library/library_entry.dart';

LibraryEntry _entry(String id, int day, int bytes, {bool pinned = false}) =>
    LibraryEntry(
      id: id,
      sourceName: '$id.mp4',
      createdAt: DateTime.utc(2026, 9, day),
      lang: 'tr-TR',
      cueCount: 5,
      flaggedCount: 0,
      pinned: pinned,
      mediaRemoved: false,
      mediaBytes: bytes,
    );

void main() {
  test('Пока места хватает, ничего не удаляется', () {
    final plan = planCleanup(
      LibraryIndex(entries: [_entry('a', 1, 100), _entry('b', 2, 100)]),
      limitBytes: 1000,
    );
    expect(plan.isEmpty, isTrue);
    expect(plan.freedBytes, 0);
  });

  test('Удаляются самые старые и ровно столько, сколько нужно', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('старая', 1, 400),
        _entry('средняя', 2, 400),
        _entry('свежая', 3, 400),
      ]),
      limitBytes: 900,
    );
    // 1200 > 900: хватит убрать одну самую старую.
    expect(plan.idsToStrip, ['старая']);
    expect(plan.freedBytes, 400);
    expect(plan.limitStillExceeded, isFalse);
  });

  test('Закреплённые записи не трогаются никогда', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('старая-закреплённая', 1, 500, pinned: true),
        _entry('свежая', 3, 500),
      ]),
      limitBytes: 600,
    );
    expect(plan.idsToStrip, isNot(contains('старая-закреплённая')));
    expect(plan.idsToStrip, ['свежая']);
  });

  test('Если чистить нечего, честно сообщаем что лимит превышен', () {
    final plan = planCleanup(
      LibraryIndex(entries: [
        _entry('a', 1, 800, pinned: true),
        _entry('b', 2, 800, pinned: true),
      ]),
      limitBytes: 1000,
    );
    expect(plan.isEmpty, isTrue);
    expect(plan.limitStillExceeded, isTrue,
        reason: 'закреплённое не удаляем, но и молчать нельзя');
  });

  test('Записи без медиа в план не попадают: удалять там нечего', () {
    final stripped = _entry('a', 1, 0).copyWith(mediaRemoved: true);
    final plan = planCleanup(
      LibraryIndex(entries: [stripped, _entry('b', 2, 2000)]),
      limitBytes: 1000,
    );
    expect(plan.idsToStrip, ['b']);
  });

  test('Предупреждаем заранее, с 80 % лимита', () {
    LibraryIndex at(int bytes) =>
        LibraryIndex(entries: [_entry('a', 1, bytes)]);
    expect(shouldWarnAboutSpace(at(700), limitBytes: 1000), isFalse);
    expect(shouldWarnAboutSpace(at(800), limitBytes: 1000), isTrue);
    expect(shouldWarnAboutSpace(at(950), limitBytes: 1000), isTrue);
  });
}
