// test/core/session_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/session_store.dart';

void main() {
  late Directory tmp;
  late Directory fallback;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_test_');
    fallback = Directory.systemTemp.createTempSync('session_fallback_');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
    fallback.deleteSync(recursive: true);
  });

  Session sessionFor(String videoPath, {int size = 100}) => Session(
        videoPath: videoPath,
        fingerprint: SourceFingerprint(sizeBytes: size, durationSec: 34.8),
        lang: 'tr-TR',
        silenceThreshold: '-30dB',
        forcedSplit: false,
        cues: const [
          Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi', ru: 'брат',
              status: CueStatus.ok, flags: {}),
        ],
      );

  test('Файл сессии кладётся рядом с видео', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);

    final saved = await store.save(sessionFor(video));
    expect(saved, '${tmp.path}/clip.mp4.subtitler.json');
    expect(File(saved).existsSync(), isTrue);
  });

  test('Сессия читается обратно при совпадении отпечатка', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);
    await store.save(sessionFor(video));

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 100, durationSec: 34.8));
    expect(loaded, isNotNull);
    expect(loaded!.cues.single.orig, 'abi');
  });

  test('Чужая сессия отбрасывается: другой файл с тем же именем', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final store = SessionStore(fallbackDir: fallback.path);
    await store.save(sessionFor(video));

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 999, durationSec: 12.0));
    expect(loaded, isNull, reason: 'подстановка чужих реплик недопустима');
  });

  test('Отсутствие файла сессии — это null, а не исключение', () async {
    final store = SessionStore(fallbackDir: fallback.path);
    expect(
        await store.load('${tmp.path}/нет.mp4',
            const SourceFingerprint(sizeBytes: 1, durationSec: 1)),
        isNull);
  });

  test('Битый JSON не роняет приложение', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    File('${tmp.path}/clip.mp4.subtitler.json').writeAsStringSync('{не json');
    final store = SessionStore(fallbackDir: fallback.path);
    expect(
        await store.load(video,
            const SourceFingerprint(sizeBytes: 100, durationSec: 34.8)),
        isNull);
  });

  test('Папка только на чтение — сессия уходит в запасной каталог', () async {
    final readOnly = Directory('${tmp.path}/ro')..createSync();
    final video = '${readOnly.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    Process.runSync('chmod', ['555', readOnly.path]);
    addTearDown(() => Process.runSync('chmod', ['755', readOnly.path]));

    final store = SessionStore(fallbackDir: fallback.path);
    final saved = await store.save(sessionFor(video));

    expect(saved, startsWith(fallback.path));
    expect(File(saved).existsSync(), isTrue);

    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 100, durationSec: 34.8));
    expect(loaded, isNotNull, reason: 'запасная сессия тоже должна читаться');
  });
}
