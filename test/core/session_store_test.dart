// test/core/session_store_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/path_hash.dart';
import 'package:subtitler/core/session_store.dart';

import '../support/interrupted_writes.dart';

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

  group('Запись целиком или никак', () {
    const fp = SourceFingerprint(sizeBytes: 100, durationSec: 34.8);

    Session edited(String video) => sessionFor(video).copyWith(cues: const [
          Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi',
              ru: 'правка следователя', status: CueStatus.ok, flags: {}),
        ]);

    test('Оборванная запись оставляет прежнюю сессию целой', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      await store.save(sessionFor(video));

      // Окно закрыли (или программа упала) посреди записи правки.
      await expectLater(
        interruptingWrites(() => store.save(edited(video))),
        throwsA(isA<InterruptedWrite>()),
      );

      final loaded = await store.load(video, fp);
      expect(loaded, isNotNull,
          reason: 'иначе весь ролик распознаётся заново за деньги, '
              'а ручные правки пропадают');
      expect(loaded!.cues.single.ru, 'брат');
    });

    test('Новая запись заменяет прежнюю, временных файлов не остаётся',
        () async {
      final video = '${tmp.path}/clip.mp4';
      File(video).writeAsBytesSync(List.filled(100, 0));
      final store = SessionStore(fallbackDir: fallback.path);
      await store.save(sessionFor(video));
      final saved = await store.save(edited(video));

      expect(saved, '${tmp.path}/clip.mp4.subtitler.json');
      expect((await store.load(video, fp))!.cues.single.ru,
          'правка следователя');
      expect(
          tmp.listSync().map((e) => e.uri.pathSegments.last).toSet(),
          {'clip.mp4', 'clip.mp4.subtitler.json'});
    });

    test('Прежний файл заменить нельзя — запись в запасную папку, '
        'временный файл не остаётся', () async {
      final folder = Directory('${tmp.path}/ro')..createSync();
      final video = '${folder.path}/clip.mp4';
      File(video).writeAsBytesSync(List.filled(100, 0));
      final store = SessionStore(fallbackDir: fallback.path);
      final primary = await store.save(sessionFor(video));
      addTearDown(protectFolder(folder.path, [primary]));

      final saved = await store.save(edited(video));

      expect(saved, startsWith(fallback.path));
      expect(folder.listSync().map((e) => e.uri.pathSegments.last).toSet(),
          {'clip.mp4', 'clip.mp4.subtitler.json'},
          reason: 'временный файл убран');
      expect(File(primary).readAsStringSync(), contains('брат'),
          reason: 'прежний файл не тронут');
    });
  });

  group('Запасная папка', () {
    const fpA = SourceFingerprint(sizeBytes: 100, durationSec: 34.8);
    const fpB = SourceFingerprint(sizeBytes: 200, durationSec: 34.8);

    // Рядом с видео писать нельзя: здесь — папки уже нет (носитель
    // отключили), с защищённым носителем запись так же уходит в
    // запасную папку.
    String caseVideo(String caseFolder) =>
        '${tmp.path}/отключённый носитель/$caseFolder/VID_0001.mp4';

    test('Одноимённые видео разных дел не затирают сессии друг друга',
        () async {
      final store = SessionStore(fallbackDir: fallback.path);
      final videoA = caseVideo('дело А');
      final videoB = caseVideo('дело Б');

      final savedA = await store.save(sessionFor(videoA));
      final savedB = await store.save(sessionFor(videoB, size: 200));
      expect(savedA, startsWith(fallback.path));
      expect(savedB, startsWith(fallback.path));

      expect(await store.load(videoA, fpA), isNotNull,
          reason: 'сессия дела А на месте — ролик не оплачивается заново');
      expect(await store.load(videoB, fpB), isNotNull);
    });

    test('Резервные копии языков одноимённых видео тоже раздельные',
        () async {
      final store = SessionStore(fallbackDir: fallback.path);
      final videoA = caseVideo('дело А');
      final videoB = caseVideo('дело Б');

      await store.saveBackup(sessionFor(videoA).copyWith(lang: 'uz-UZ'));
      await store.saveBackup(
          sessionFor(videoB, size: 200).copyWith(lang: 'uz-UZ'));

      expect(await store.loadBackup(videoA, 'uz-UZ', fpA), isNotNull);
      expect(await store.backupLanguages(videoA, fpA), {'uz-UZ'});
      expect(await store.loadBackup(videoB, 'uz-UZ', fpB), isNotNull);
    });

    test('Имя в запасной папке — имя видео и отпечаток полного пути', () {
      final store = SessionStore(fallbackDir: fallback.path);
      final video = caseVideo('дело А');
      final hash = stablePathHash(video);
      expect(store.fallbackPathFor(video),
          p.join(fallback.path, 'VID_0001.mp4.$hash.subtitler.json'));
      expect(store.fallbackBackupPathFor(video, 'uz-UZ'),
          p.join(fallback.path, 'VID_0001.mp4.$hash.subtitler.uz-UZ.json'));
    });

    test('Сессия и копия под прежним именем читаются, пишутся под новым',
        () async {
      final store = SessionStore(fallbackDir: fallback.path);
      final video = caseVideo('дело А');
      // Так их называла прежняя версия: только по имени видео.
      final legacy = p.join(fallback.path, 'VID_0001.mp4.subtitler.json');
      final legacyBackup =
          p.join(fallback.path, 'VID_0001.mp4.subtitler.uz-UZ.json');
      File(legacy).writeAsStringSync(jsonEncode(sessionFor(video).toJson()));
      File(legacyBackup).writeAsStringSync(
          jsonEncode(sessionFor(video).copyWith(lang: 'uz-UZ').toJson()));

      final loaded = await store.load(video, fpA);
      expect(loaded, isNotNull, reason: 'иначе оплачивать заново');
      expect((await store.loadBackup(video, 'uz-UZ', fpA))?.lang, 'uz-UZ');
      expect(await store.backupLanguages(video, fpA), {'uz-UZ'});

      final saved = await store.save(loaded!);
      expect(saved, store.fallbackPathFor(video));
      expect(File(legacy).readAsStringSync(),
          jsonEncode(sessionFor(video).toJson()),
          reason: 'прежний файл общий для всех видео с этим именем — '
              'в него больше не пишем');
    });
  });

  group('Сессия и рядом с видео, и в запасной папке', () {
    const fp = SourceFingerprint(sizeBytes: 100, durationSec: 34.8);
    final yesterday = DateTime.now().subtract(const Duration(days: 1));

    Session edited(String video) => sessionFor(video).copyWith(cues: const [
          Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi',
              ru: 'правка следователя', status: CueStatus.ok, flags: {}),
        ]);

    test('Правки, ушедшие в запасную папку, не теряются при повторном '
        'открытии', () async {
      // Видео обработали, пока в папку можно было писать; потом папку
      // дела записали на диск или защитили от записи и поправили реплику.
      final folder = Directory('${tmp.path}/дело')..createSync();
      final video = '${folder.path}/clip.mp4';
      File(video).writeAsBytesSync(List.filled(100, 0));
      final store = SessionStore(fallbackDir: fallback.path);
      final primary = await store.save(sessionFor(video));
      File(primary).setLastModifiedSync(yesterday);
      addTearDown(protectFolder(folder.path, [primary]));

      final saved = await store.save(edited(video));
      expect(saved, startsWith(fallback.path));

      final reopened = await store.load(video, fp);
      expect(reopened!.cues.single.ru, 'правка следователя',
          reason: 'иначе в редакторе и в следующем видео — старый текст');
    });

    test('Рядом с видео свежее запасной — берётся сессия рядом с видео',
        () async {
      // В запасную папку однажды ушла запись, потом в папку видео снова
      // стало можно писать, и следующие правки легли рядом с ним.
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      File(store.fallbackPathFor(video))
        ..writeAsStringSync(jsonEncode(sessionFor(video).toJson()))
        ..setLastModifiedSync(yesterday);
      await store.save(edited(video));

      expect((await store.load(video, fp))!.cues.single.ru,
          'правка следователя');
    });

    test('Резервная копия языка — тоже самая свежая', () async {
      final video = '${tmp.path}/clip.mp4';
      final store = SessionStore(fallbackDir: fallback.path);
      final uzbek = sessionFor(video).copyWith(lang: 'uz-UZ');
      File(store.backupPathFor(video, 'uz-UZ'))
        ..writeAsStringSync(jsonEncode(uzbek.toJson()))
        ..setLastModifiedSync(yesterday);
      File(store.fallbackBackupPathFor(video, 'uz-UZ')).writeAsStringSync(
          jsonEncode(edited(video).copyWith(lang: 'uz-UZ').toJson()));

      expect((await store.loadBackup(video, 'uz-UZ', fp))!.cues.single.ru,
          'правка следователя');
    });
  });

  group('Видео перенесли вместе с сессией', () {
    const fp = SourceFingerprint(sizeBytes: 100, durationSec: 34.8);

    // Папку дела скопировали (или флешка получила другую букву диска):
    // видео и файлы сессии лежат по новому пути, внутри JSON — прежний.
    late String videoA;
    late String videoB;
    setUp(() {
      videoA = '${(Directory('${tmp.path}/E')..createSync()).path}/VID.mp4';
      videoB = '${(Directory('${tmp.path}/F')..createSync()).path}/VID.mp4';
    });

    test('Сессия привязывается к пути, по которому её открыли, и пишется '
        'туда же', () async {
      final store = SessionStore(fallbackDir: fallback.path);
      await store.save(sessionFor(videoA));
      File('$videoA.subtitler.json').copySync('$videoB.subtitler.json');
      final beforeA = File('$videoA.subtitler.json').readAsStringSync();

      final loaded = await store.load(videoB, fp);
      expect(loaded!.videoPath, videoB);

      final saved = await store.save(loaded.copyWith(cues: const [
        Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi',
            ru: 'правка следователя', status: CueStatus.ok, flags: {}),
      ]));
      expect(saved, '$videoB.subtitler.json');
      expect((await store.load(videoB, fp))!.cues.single.ru,
          'правка следователя');
      expect(File('$videoA.subtitler.json').readAsStringSync(), beforeA,
          reason: 'прежняя копия вещдока не тронута');
    });

    test('Резервная копия языка — тоже по новому пути', () async {
      final store = SessionStore(fallbackDir: fallback.path);
      await store.save(sessionFor(videoA));
      await store.saveBackup(sessionFor(videoA).copyWith(lang: 'uz-UZ'));
      for (final name in ['subtitler.json', 'subtitler.uz-UZ.json']) {
        File('$videoA.$name').copySync('$videoB.$name');
      }

      expect((await store.loadBackup(videoB, 'uz-UZ', fp))!.videoPath, videoB);
      final current = (await store.load(videoB, fp))!;
      final restored = await store.swapWithBackup(current, 'uz-UZ');
      expect(restored!.videoPath, videoB);
      expect((await store.load(videoB, fp))!.lang, 'uz-UZ',
          reason: 'восстановленная копия стала основной сессией у B');
      expect((await store.load(videoA, fp))!.lang, 'tr-TR',
          reason: 'у A ничего не поменялось');
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

/// Делает так, что в [folder] ничего не заменить, и возвращает отмену.
///
/// На Unix — папка без права записи. На Windows права папки меняются
/// только через ACL; вместо этого уже лежащие там файлы [files] ставятся
/// «только для чтения»: и прямая запись в них, и замена переименованием
/// отклоняются тем же кодом 5 (нет доступа), что и в защищённой папке, —
/// проверено на Windows 11. Новые файлы в папке на Windows создать
/// по-прежнему можно, поэтому всё, что тест будет писать, должно уже
/// лежать там.
void Function() protectFolder(String folder, List<String> files) {
  if (Platform.isWindows) {
    for (final path in files) {
      Process.runSync('attrib', ['+R', path]);
    }
    return () {
      for (final path in files) {
        Process.runSync('attrib', ['-R', path]);
      }
    };
  }
  Process.runSync('chmod', ['555', folder]);
  return () => Process.runSync('chmod', ['755', folder]);
}
