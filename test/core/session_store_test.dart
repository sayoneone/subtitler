// test/core/session_store_test.dart
import 'dart:convert';
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

  test('Сессия прежней версии (схема 1) читается, а не оплачивается заново',
      () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    // Ровно так файл записывала версия со схемой 1: полей про уверенность
    // и пробы в нём ещё нет.
    File('${tmp.path}/clip.mp4.subtitler.json').writeAsStringSync('''
{
 "schemaVersion": 1,
 "videoPath": "${video.replaceAll(r'\', r'\\')}",
 "fingerprint": {"sizeBytes": 100, "durationSec": 34.8},
 "lang": "uz-UZ",
 "silenceThreshold": "-25dB",
 "forcedSplit": false,
 "cues": [
  {"index": 1, "range": {"start": 0.0, "end": 2.5},
   "orig": "ertaga ertalab bozorga boramiz", "ru": "завтра утром поедем на рынок",
   "status": "ok", "flags": []}
 ]
}''');
    final store = SessionStore(fallbackDir: fallback.path);
    final loaded = await store.load(video,
        const SourceFingerprint(sizeBytes: 100, durationSec: 34.8));

    expect(loaded, isNotNull, reason: 'иначе весь ролик пришлось бы оплатить заново');
    expect(loaded!.lang, 'uz-UZ');
    expect(loaded.cues.single.ru, 'завтра утром поедем на рынок');
    expect(loaded.langConfidence, isNull,
        reason: 'в схеме 1 язык подтверждал человек — сомневаться не в чем');
    expect(loaded.langRunnerUp, isNull);
    expect(loaded.probeTexts, isEmpty);

    // При следующей записи файл переходит на текущую схему.
    await store.save(loaded);
    final raw = jsonDecode(
        File('${tmp.path}/clip.mp4.subtitler.json').readAsStringSync()) as Map;
    expect(raw['schemaVersion'], Session.currentSchemaVersion);
  });

  test('Сессия из будущей версии не подменяет данные догадками', () async {
    final video = '${tmp.path}/clip.mp4';
    File(video).writeAsBytesSync(List.filled(100, 0));
    final json = sessionFor(video).toJson()..['schemaVersion'] = 99;
    File('${tmp.path}/clip.mp4.subtitler.json')
        .writeAsStringSync(jsonEncode(json));
    final store = SessionStore(fallbackDir: fallback.path);
    expect(
        await store.load(video,
            const SourceFingerprint(sizeBytes: 100, durationSec: 34.8)),
        isNull);
  });

  group('Резервные копии при смене языка', () {
    const fp = SourceFingerprint(sizeBytes: 100, durationSec: 34.8);

    Session uzbek(String video) => Session(
          videoPath: video,
          fingerprint: fp,
          lang: 'uz-UZ',
          langConfidence: LanguageConfidence.low,
          langRunnerUp: 'tr-TR',
          probeTexts: const {
            'uz-UZ': {1: 'ertaga ertalab bozorga boramiz'},
          },
          silenceThreshold: '-30dB',
          forcedSplit: false,
          cues: const [
            Cue(index: 1, range: TimeRange(0, 1.7),
                orig: 'ertaga ertalab bozorga boramiz',
                ru: 'правка следователя', status: CueStatus.ok, flags: {}),
          ],
        );

    test('Копия пишется под именем языка и читается обратно', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      final path = await store.saveBackup(uzbek(video));
      expect(path, '${tmp.path}/clip.mp4.subtitler.uz-UZ.json');

      final restored = await store.loadBackup(video, 'uz-UZ', fp);
      expect(restored!.cues.single.ru, 'правка следователя');
      expect(await store.loadBackup(video, 'tr-TR', fp), isNull);
      expect(
          await store.loadBackup(video, 'uz-UZ',
              const SourceFingerprint(sizeBytes: 999, durationSec: 1)),
          isNull,
          reason: 'копия от другого файла с тем же именем не годится');
      expect(await store.backupLanguages(video, fp), {'uz-UZ'});
    });

    test('Копия не путается с основной сессией', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      await store.saveBackup(uzbek(video));
      expect(await store.load(video, fp), isNull);
    });

    test('Переключение на язык с копией бесплатно и обратимо', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      await store.saveBackup(uzbek(video));

      final turkish = sessionFor(video).copyWith(
        langConfidence: LanguageConfidence.low,
        langRunnerUp: 'uz-UZ',
        probeTexts: const {
          'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz'},
          'uz-UZ': {1: 'ertaga ertalab bozorga boramiz'},
        },
      );
      await store.save(turkish);

      final restored = await store.swapWithBackup(turkish, 'uz-UZ');
      expect(restored, isNotNull);
      expect(restored!.lang, 'uz-UZ');
      expect(restored.cues.single.ru, 'правка следователя');
      expect(restored.langConfidence, isNull,
          reason: 'язык выбрал человек — жёлтая плашка больше не нужна');
      expect(restored.langRunnerUp, 'tr-TR');
      expect(restored.probeTexts.keys, containsAll(['tr-TR', 'uz-UZ']),
          reason: 'оплаченные пробы не теряются');

      expect((await store.load(video, fp))!.lang, 'uz-UZ',
          reason: 'восстановленная копия стала основной сессией');
      expect((await store.loadBackup(video, 'tr-TR', fp))!.cues.single.ru,
          'брат', reason: 'турецкий вариант ушёл в копию вместе с правками');
    });

    test('Без копии переключение ничего не трогает', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      final turkish = sessionFor(video);
      await store.save(turkish);

      expect(await store.swapWithBackup(turkish, 'uz-UZ'), isNull);
      expect((await store.load(video, fp))!.lang, 'tr-TR');
      expect(await store.backupLanguages(video, fp), isEmpty);
    });
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
    // chmod управляет правами только в Unix; на Windows доступ устроен
    // иначе, и этот сценарий надо проверять отдельно.
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
  }, skip: Platform.isWindows ? 'chmod не управляет доступом на Windows' : null);
}
