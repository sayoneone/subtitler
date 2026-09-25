// Файл сессии есть, но прочитать его нельзя: записан более новой версией
// программы или обрезан обрывом записи. Определение языка не должно
// молча затирать его новой сессией.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';

import '../../support/fakes.dart';
import '../../support/media.dart';

void main() {
  late Directory tmp;
  late String probeClip;
  var counter = 0;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('unreadable_session_');
    probeClip = await makeProbeClip(p.join(tmp.path, 'probe.mp4'));
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// Выдуманная сессия этого ролика, записанная «другой версией».
  String sessionJson(String video) => const JsonEncoder.withIndent(' ')
      .convert(Session(
        videoPath: video,
        fingerprint: const SourceFingerprint(sizeBytes: 1, durationSec: 15),
        lang: 'uz-UZ',
        silenceThreshold: '-30dB',
        forcedSplit: false,
        cues: const [
          Cue(index: 1, range: TimeRange(0, 4), orig: 'ertaga ertalab',
              ru: 'правка следователя', status: CueStatus.ok, flags: {}),
        ],
      ).toJson());

  Future<(LanguageProbe, DebugLog, Directory)> detect(
      String Function(String video) unreadable) async {
    final folder = Directory(p.join(tmp.path, 'дело${counter++}'))
      ..createSync();
    final video = p.join(folder.path, 'clip.mp4');
    File(probeClip).copySync(video);
    File('$video.subtitler.json').writeAsStringSync(unreadable(video));

    final log = DebugLog();
    final workDir = p.join(tmp.path, 'work${counter++}');
    final pipeline = Pipeline(
      runner: testRunner,
      stt: ScriptedStt(workDir, const {
        'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz', 3: 'tamam'},
        'uz-UZ': {1: 'yarin sabah erkandan charshiga', 3: 'tamom'},
      }),
      translate: FakeTranslate(),
      store: SessionStore(
          fallbackDir: p.join(tmp.path, 'запасная${counter++}'), log: log),
      workDir: workDir,
      log: log,
    );
    final probe = await pipeline.detectLanguage(
      videoPath: video,
      candidates: const ['tr-TR', 'uz-UZ'],
      sleep: (_) async {},
    );
    return (probe, log, folder);
  }

  /// Отложенные файлы: `clip.mp4.subtitler.broken-<время>.json`.
  List<File> setAside(Directory folder) => folder
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'^clip\.mp4\.subtitler\.broken-\d{8}-\d{6}.*\.json$')
          .hasMatch(p.basename(f.path)))
      .toList();

  void expectKept(Directory folder, String original, DebugLog log,
      LanguageProbe probe) {
    final aside = setAside(folder);
    expect(aside, hasLength(1),
        reason: 'нечитаемый файл не затирается, а откладывается');
    expect(aside.single.readAsStringSync(), original,
        reason: 'содержимое сохранено как было — его можно открыть '
            'новой версией или восстановить');
    expect(
        log.entries.map((e) => e.message),
        contains(allOf(contains('clip.mp4.subtitler.json'),
            contains(p.basename(aside.single.path)))),
        reason: 'в журнале видно, куда делся прежний файл');

    // Работа продолжается: язык определён, новая сессия записана.
    expect(probe.reusedSession, isFalse);
    final fresh = File(p.join(folder.path, 'clip.mp4.subtitler.json'));
    final saved = Session.fromJson(
        jsonDecode(fresh.readAsStringSync()) as Map<String, dynamic>);
    expect(saved.lang, probe.session.lang);
  }

  test('Сессия более новой версии программы откладывается, а не затирается',
      () async {
    late String original;
    final (probe, log, folder) = await detect((video) {
      final json = jsonDecode(sessionJson(video)) as Map<String, dynamic>
        ..['schemaVersion'] = Session.currentSchemaVersion + 1;
      return original = const JsonEncoder.withIndent(' ').convert(json);
    });
    expectKept(folder, original, log, probe);
  });

  test('Обрезанная запись откладывается, а не затирается', () async {
    late String original;
    final (probe, log, folder) = await detect((video) {
      final full = sessionJson(video);
      return original = full.substring(0, full.length ~/ 2);
    });
    expectKept(folder, original, log, probe);
  });

  test('Неизвестный статус реплики — тоже нечитаемый файл, а не сбой',
      () async {
    late String original;
    final (probe, log, folder) = await detect((video) => original =
        sessionJson(video).replaceFirst('"ok"', '"reviewed"'));
    expectKept(folder, original, log, probe);
  });
}
