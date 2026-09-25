import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/retry.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';

/// Подставной STT: отдаёт заранее заданные тексты по порядку и считает вызовы.
///
/// [failCalls] первых обращений падают с [failWith]. Считаются именно
/// обращения, а не сегменты: чтобы сегмент действительно провалился,
/// уронить надо все его попытки, иначе повтор молча всё починит и тест
/// проверит не то, что заявлено.
class FakeStt implements SpeechKitClient {
  final List<String> texts;
  int calls = 0;
  int failCalls = 0;
  Object? failWith;

  FakeStt(this.texts);

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    calls++;
    if (calls <= failCalls) throw failWith!;
    final index = calls - failCalls - 1;
    return index < texts.length ? texts[index] : '';
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

/// Подставной STT для определения языка: ответ зависит от пары
/// (язык, реплика), а не от порядка вызовов — порядок проб меняется
/// вместе с алгоритмом, и тест не должен на него опираться.
///
/// Какая это реплика, узнаём по байтам: сравниваем тело запроса с файлами
/// сегментов в рабочей папке.
class ScriptedStt implements SpeechKitClient {
  final String workDir;
  final Map<String, Map<int, String>> texts;

  /// Пары (язык, реплика), на которых сервис отвечает ошибкой всегда —
  /// то есть и на все повторы.
  final Set<(String, int)> failing;
  final List<(String, int)> calls = [];

  ScriptedStt(this.workDir, this.texts, {this.failing = const {}});

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    final cue = _cueIndexOf(oggBytes);
    calls.add((lang, cue));
    if (failing.contains((lang, cue))) {
      throw const TransientException(statusCode: 500, message: 'boom');
    }
    return texts[lang]?[cue] ?? '';
  }

  int _cueIndexOf(List<int> bytes) {
    final dir = Directory('$workDir${Platform.pathSeparator}segments');
    for (final file in dir.listSync().whereType<File>()) {
      final content = file.readAsBytesSync();
      if (content.length != bytes.length) continue;
      var same = true;
      for (var i = 0; i < content.length; i++) {
        if (content[i] != bytes[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        return int.parse(
            RegExp(r'seg_(\d+)\.ogg$').firstMatch(file.path)!.group(1)!);
      }
    }
    throw StateError('Запрос не совпал ни с одним сегментом');
  }

  List<(String, int)> callsFor(String lang) =>
      calls.where((c) => c.$1 == lang).toList();

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

class FakeTranslate implements TranslateClient {
  int calls = 0;
  List<String> lastTexts = const [];

  @override
  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLang,
  }) async {
    calls++;
    lastTexts = texts;
    return texts.map((t) => 'RU:$t').toList();
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

void main() {
  late Directory tmp;
  late String video;
  late String probeVideo;
  final runner = ProcessFfmpegRunner.fromEnvironment();
  var workCounter = 0;
  var copyCounter = 0;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('pipeline_test_');
    video = '${tmp.path}/clip.mp4';
    // Звук идёт первые 3 с каждой пятисекундки: получаем три речевых куска
    // с паузами между ними.
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=15',
      '-f', 'lavfi',
      '-i', 'aevalsrc=0.5*sin(440*2*PI*t)*between(mod(t\\,5)\\,0\\,3):d=15',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      video,
    ]);
    expect(made.ok, isTrue, reason: made.log);

    // Для определения языка нужны реплики разной длины, чтобы выбор проб
    // был однозначным: 4 с (реплика 1), 2 с (реплика 2), 3.5 с (реплика 3).
    probeVideo = '${tmp.path}/probe.mp4';
    final madeProbe = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=15',
      '-f', 'lavfi',
      '-i', 'aevalsrc=0.5*sin(440*2*PI*t)*(between(t\\,0\\,4)'
          '+between(t\\,6\\,8)+between(t\\,10\\,13.5)):d=15',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      probeVideo,
    ]);
    expect(madeProbe.ok, isTrue, reason: madeProbe.log);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// Копия ролика под новым именем: рядом с ней ещё нет файла сессии,
  /// оставленного другими тестами.
  String freshCopy(String source) {
    final copy = '${tmp.path}/copy${copyCounter++}.mp4';
    File(source).copySync(copy);
    return copy;
  }

  /// Каждому прогону — своя рабочая папка, кроме случаев, когда тест
  /// намеренно продолжает предыдущий (тогда путь передаётся явно).
  Pipeline build(SpeechKitClient stt, FakeTranslate tr, {String? workDir}) =>
      Pipeline(
        runner: runner,
        stt: stt,
        translate: tr,
        store: SessionStore(fallbackDir: tmp.path),
        workDir: workDir ?? '${tmp.path}/work${workCounter++}',
      );

  test('Успешный прогон заполняет реплики и переводы', () async {
    final stt = FakeStt(['bir', 'iki', 'üç']);
    final tr = FakeTranslate();
    final session =
        await build(stt, tr).process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});

    expect(session.cues, isNotEmpty);
    expect(session.lang, 'tr-TR');
    final recognized =
        session.cues.where((c) => c.status == CueStatus.ok).toList();
    expect(recognized, isNotEmpty);
    expect(recognized.first.ru, startsWith('RU:'));
    expect(tr.calls, 1, reason: 'все реплики уходят одним батчем');
  });

  test('Пустой ответ распознавания даёт статус empty, а не ошибку', () async {
    final tr = FakeTranslate();
    final session = await build(FakeStt(const ['', '', '']), tr)
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    expect(session.cues, isNotEmpty);
    expect(session.cues.every((c) => c.status == CueStatus.empty), isTrue);
    expect(tr.calls, 0, reason: 'переводить нечего — в сеть не ходим');
  });

  test('Возобновление не отправляет в API уже распознанные сегменты', () async {
    final workDir = '${tmp.path}/resume_work';
    final first = FakeStt(['bir', 'iki', 'üç']);
    final session = await build(first, FakeTranslate(), workDir: workDir)
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    expect(first.calls, greaterThan(0));

    final second = FakeStt(['НЕ ДОЛЖНО ВЫЗЫВАТЬСЯ']);
    await build(second, FakeTranslate(), workDir: workDir).process(
      videoPath: video,
      lang: 'tr-TR',
      resumeFrom: session,
      sleep: (_) async {},
    );
    expect(second.calls, 0, reason: 'повторная оплата уже распознанного');
  });

  test('Возобновление без файлов сегментов не теряет распознанный текст',
      () async {
    final workDir = '${tmp.path}/lost_work';
    final stt = FakeStt(['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate(), workDir: workDir)
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});
    final recognized =
        session.cues.where((c) => c.status == CueStatus.ok).length;
    expect(recognized, greaterThan(0));

    // Имитируем перезапуск приложения: временная папка исчезла.
    Directory(workDir).deleteSync(recursive: true);

    final second = FakeStt(['НЕ ДОЛЖНО ВЫЗЫВАТЬСЯ']);
    final resumed = await build(second, FakeTranslate(), workDir: workDir).process(
      videoPath: video,
      lang: 'tr-TR',
      resumeFrom: session,
      sleep: (_) async {},
    );
    expect(second.calls, 0, reason: 'заново платить за распознавание нельзя');
    expect(resumed.cues.where((c) => c.status == CueStatus.ok).length,
        recognized);
  });

  test('Ошибка авторизации останавливает весь прогон', () async {
    final stt = FakeStt(['bir'])
      ..failCalls = 1
      ..failWith = const AuthException(statusCode: 403, message: 'нет роли');
    await expectLater(
      build(stt, FakeTranslate())
          .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {}),
      throwsA(isA<AuthException>()),
    );
    expect(stt.calls, 1,
        reason: 'ошибка ключа не повторяется и не пускает следующие запросы');
  });

  test('Временная ошибка после повторов помечает реплику failed, прогон идёт дальше',
      () async {
    // Роняем все попытки первого сегмента: одной мало — повтор её исправит.
    final attemptsPerCue = kRetryDelays.length + 1;
    final stt = FakeStt(['bir', 'iki'])
      ..failCalls = attemptsPerCue
      ..failWith = const TransientException(statusCode: 500, message: 'boom');

    final session = await build(stt, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});

    expect(session.cues.any((c) => c.status == CueStatus.failed), isTrue,
        reason: 'сегмент, исчерпавший повторы, помечается провалившимся');
    expect(session.cues.any((c) => c.status == CueStatus.ok), isTrue,
        reason: 'соседние сегменты всё равно обработаны');
  });

  test('Отмена прерывает прогон и сохраняет уже готовое', () async {
    final stt = FakeStt(['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      sleep: (_) async {},
      // Первый сегмент успел распознаться — дальше отмена. Раньше здесь
      // считались сами проверки отмены, но теперь она проверяется и при
      // подготовке звука, и счёт проверок перестал означать «один сегмент».
      isCancelled: () => stt.calls >= 1,
    );
    expect(session.cues.any((c) => c.status == CueStatus.ok), isTrue,
        reason: 'успевшее до отмены должно сохраниться');
    expect(session.cues.any((c) => c.status == CueStatus.pending), isTrue,
        reason: 'остальное осталось необработанным и будет доделано позже');
  });

  test('Прогресс сообщает этапы по порядку', () async {
    final stages = <PipelineStage>[];
    await build(FakeStt(['bir']), FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      sleep: (_) async {},
      onProgress: (p) => stages.add(p.stage),
    );
    expect(stages.first, PipelineStage.extractingAudio);
    expect(stages, contains(PipelineStage.detectingSilence));
    expect(stages, contains(PipelineStage.recognizing));
    expect(stages.last, PipelineStage.done);
  });

  test('Сессия сохраняется на диск и переживает перезагрузку', () async {
    final stt = FakeStt(['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate())
        .process(videoPath: video, lang: 'tr-TR', sleep: (_) async {});

    final store = SessionStore(fallbackDir: tmp.path);
    final loaded = await store.load(
      video,
      SourceFingerprint(
        sizeBytes: File(video).lengthSync(),
        durationSec: await runner.probeDuration(video),
      ),
    );
    expect(loaded, isNotNull);
    expect(loaded!.cues.length, session.cues.length);
    expect(loaded.silenceThreshold, isNotEmpty);
  });

  group('Определение языка', () {
    /// Конвейер и подставной STT с общей рабочей папкой: по ней STT узнаёт,
    /// какую реплику ему прислали.
    (Pipeline, ScriptedStt) scripted(
      Map<String, Map<int, String>> texts, {
      Set<(String, int)> failing = const {},
    }) {
      final workDir = '${tmp.path}/work${workCounter++}';
      final stt = ScriptedStt(workDir, texts, failing: failing);
      return (build(stt, FakeTranslate(), workDir: workDir), stt);
    }

    test('Реплика с ошибкой API не сдвигает сравнение', () async {
      // Речь узбекская. Узбекская модель на самой длинной реплике 1
      // упала с ошибкой сервиса, турецкая написала там кальку своими
      // буквами. Сравнивать можно только реплики, распознанные обеими.
      final copy = freshCopy(probeVideo);
      final (pipeline, stt) = scripted({
        'uz-UZ': {
          2: 'ertaga ertalab bozorga boramiz',
          3: 'bugun kechqurun uyga kech qaytaman shuning uchun kutmang',
        },
        'tr-TR': {
          1: 'kışta çarçap kaldım şunun için işe barolmadım',
          2: 'ertaga ertalap bazarga baramız',
          3: 'bugün keçkurun uyga keç kaytaman şunung uçun kutmang',
        },
      }, failing: {('uz-UZ', 1)});

      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );

      expect(probe.session.lang, 'uz-UZ');
      expect(stt.callsFor('uz-UZ').where((c) => c.$2 == 1), isNotEmpty,
          reason: 'реплика 1 действительно пробовалась');
    });
  });

  test('Видео без звуковой дорожки — отдельная понятная ошибка', () async {
    final silent = '${tmp.path}/no_audio.mp4';
    final made = await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=3',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
      silent,
    ]);
    expect(made.ok, isTrue, reason: made.log);

    final stt = FakeStt(const []);
    await expectLater(
      build(stt, FakeTranslate())
          .process(videoPath: silent, lang: 'tr-TR', sleep: (_) async {}),
      throwsA(isA<NoAudioStreamException>()),
    );
    await expectLater(
      build(stt, FakeTranslate())
          .detectLanguage(videoPath: silent, sleep: (_) async {}),
      throwsA(isA<NoAudioStreamException>()),
    );
    expect(stt.calls, 0);
    expect(const NoAudioStreamException().toString(), 'В этом видео нет звука');
  });

  test('После нарезки audio.wav удаляется, а возобновление не ломается',
      () async {
    final workDir = '${tmp.path}/work${workCounter++}';
    final copy = freshCopy(video);
    final session = await build(FakeStt(['bir', 'iki', 'üç']), FakeTranslate(),
            workDir: workDir)
        .process(videoPath: copy, lang: 'tr-TR', sleep: (_) async {});
    expect(File('$workDir/audio.wav').existsSync(), isFalse,
        reason: 'сотни мегабайт на час видео, после нарезки не нужны');

    // Сегменты пропали, а нераспознанная реплика осталась: звук
    // извлекается заново и режется снова.
    Directory('$workDir/segments').deleteSync(recursive: true);
    final unfinished = session.copyWith(cues: [
      session.cues.first.copyWith(status: CueStatus.pending, orig: ''),
      ...session.cues.skip(1),
    ]);
    final stt = FakeStt(['bir']);
    final resumed = await build(stt, FakeTranslate(), workDir: workDir).process(
      videoPath: copy,
      lang: 'tr-TR',
      resumeFrom: unfinished,
      sleep: (_) async {},
    );
    expect(stt.calls, 1, reason: 'распознана только недостающая реплика');
    expect(resumed.cues.first.status, CueStatus.ok);
    expect(File('$workDir/audio.wav').existsSync(), isFalse);
  });

  test('Отмена во время подготовки звука не доходит до нарезки и распознавания',
      () async {
    final copy = freshCopy(video);
    final stt = FakeStt(['bir']);
    final workDir = '${tmp.path}/work${workCounter++}';
    await expectLater(
      build(stt, FakeTranslate(), workDir: workDir).process(
        videoPath: copy,
        lang: 'tr-TR',
        sleep: (_) async {},
        isCancelled: () => true,
      ),
      throwsA(isA<PipelineCancelledException>()),
    );
    expect(stt.calls, 0);
    expect(Directory('$workDir/segments').existsSync(), isFalse,
        reason: 'после отмены ffmpeg не должен резать сегменты');
    expect(File('$copy.subtitler.json').existsSync(), isFalse);
  });
}
