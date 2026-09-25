import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/retry.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';

import '../../support/fakes.dart';

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

    test('Сохранённая сессия не перезаписывается и не оплачивается повторно',
        () async {
      final copy = freshCopy(video);
      final done = await build(FakeStt(['bir', 'iki', 'üç']), FakeTranslate())
          .process(videoPath: copy, lang: 'tr-TR', sleep: (_) async {});

      // Следователь поправил перевод первой реплики.
      final store = SessionStore(fallbackDir: tmp.path);
      final edited = done.copyWith(cues: [
        done.cues.first.copyWith(ru: 'правка следователя'),
        ...done.cues.skip(1),
      ]);
      final path = await store.save(edited);

      // Тот же файл перетащили снова.
      final (pipeline, stt) = scripted({
        'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz'},
        'uz-UZ': {1: 'ertaga ertalab bozorga boramiz'},
      });
      await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );

      final onDisk = Session.fromJson(
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);
      expect(onDisk.cues.first.ru, 'правка следователя',
          reason: 'ручные правки не должны пропадать');
      expect(stt.calls, isEmpty, reason: 'за готовую сессию платить нельзя');
    });

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
      expect(probe.verdict!.comparedCues, isNot(contains(1)));
      // Турецкая проба реплики 1 оплачена — она сохранена, хоть и не
      // сравнивалась; у узбекской модели реплики 1 нет, и она остаётся
      // нераспознанной — её распознает основная обработка.
      expect(probe.session.probeTexts['tr-TR'], contains(1));
      expect(probe.session.probeTexts['uz-UZ'], isNot(contains(1)));
      expect(probe.session.cues.firstWhere((c) => c.index == 1).status,
          CueStatus.pending);
    });

    /// Турецкая речь на репликах 1 и 3 (самые длинные), узбекская модель
    /// пишет кальку. 18 слов у лидера — хватает для уверенности.
    const turkishSpeech = {
      'tr-TR': {
        1: 'yarın sabah erkenden çarşıya gideceğiz çünkü evde ekmek yok',
        2: 'tamam',
        3: 'akşam eve geç geleceğim sen beni bekleme tamam mı',
      },
      'uz-UZ': {
        1: 'yarin sabah erkandan charshiga gidajakmiz chunki evda ekmak yoq',
        2: 'tamom',
        3: 'aqsham eve gech gelajagim sen beni beklama tamom mi',
      },
    };

    test('Уверенный выбор обходится первыми пробами', () async {
      final copy = freshCopy(probeVideo);
      final (pipeline, stt) = scripted(turkishSpeech);
      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );

      expect(probe.verdict!.lang, 'tr-TR');
      expect(probe.verdict!.confidence, LanguageConfidence.high);
      expect(stt.calls.map((c) => c.$2).toSet(), {1, 3},
          reason: 'две самые длинные реплики из разных частей ролика');
      expect(stt.calls, hasLength(4), reason: 'второй этап не нужен');

      final session = probe.session;
      expect(session.lang, 'tr-TR');
      expect(session.langConfidence, LanguageConfidence.high);
      expect(session.langRunnerUp, 'uz-UZ');
      expect(session.cues.firstWhere((c) => c.index == 1).orig,
          startsWith('yarın sabah'));
      expect(session.cues.firstWhere((c) => c.index == 2).status,
          CueStatus.pending);
    });

    test('Пробы всех языков сохраняются в сессию на диске', () async {
      final copy = freshCopy(probeVideo);
      final (pipeline, _) = scripted(turkishSpeech);
      await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );

      final onDisk = Session.fromJson(
          jsonDecode(File('$copy.subtitler.json').readAsStringSync())
              as Map<String, dynamic>);
      expect(onDisk.probeTexts['uz-UZ'], {
        1: turkishSpeech['uz-UZ']![1],
        3: turkishSpeech['uz-UZ']![3],
      }, reason: 'пробы проигравшего языка оплачены — выбрасывать нельзя');
      expect(onDisk.probeTexts['tr-TR'], hasLength(2));
      expect(onDisk.langConfidence, LanguageConfidence.high);
    });

    test('Обработка после определения не платит за пробы победителя',
        () async {
      final copy = freshCopy(probeVideo);
      final (pipeline, stt) = scripted(turkishSpeech);
      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );
      stt.calls.clear();

      final session = await pipeline.process(
        videoPath: copy,
        lang: probe.session.lang,
        resumeFrom: probe.session,
        sleep: (_) async {},
      );
      expect(stt.calls, [('tr-TR', 2)]);
      expect(session.cues.every((c) => c.status == CueStatus.ok), isTrue);
    });

    test('Мало уверенности — ещё реплики, и только двумя лидерами', () async {
      final copy = freshCopy(probeVideo);
      // Короткие реплики: слов мало, уверенного выбора после первого этапа
      // нет. Русская модель на турецкой речи не услышала ничего.
      final (pipeline, stt) = scripted({
        'tr-TR': {
          1: 'masada on beş kalem var',
          2: 'yarın sabah erkenden çarşıya gideceğiz',
          3: 'akşam vardiyası başladı',
        },
        'uz-UZ': {
          1: 'masada onbesh qalam bor',
          2: 'yarin sabah erkandan charshiga gidajakmiz',
          3: 'aqsham vardiyasi boshladi',
        },
        'ru-RU': {1: '', 2: '', 3: ''},
      });
      final stages = <PipelineStage>[];
      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ', 'ru-RU'],
        sleep: (_) async {},
        onProgress: (p) => stages.add(p.stage),
      );

      expect(probe.verdict!.lang, 'tr-TR');
      expect(stt.callsFor('ru-RU').map((c) => c.$2).toSet(), {1, 3},
          reason: 'отставший язык во втором этапе не участвует');
      expect(stt.callsFor('tr-TR').map((c) => c.$2).toSet(), {1, 2, 3});
      expect(stt.callsFor('uz-UZ').map((c) => c.$2).toSet(), {1, 2, 3});
      expect(probe.session.probeTexts.keys,
          containsAll(['tr-TR', 'uz-UZ', 'ru-RU']));

      expect(stages, contains(PipelineStage.detectingLanguage));
      expect(stages, isNot(contains(PipelineStage.recognizing)));
      expect(stages.last, isNot(PipelineStage.done),
          reason: 'после определения языка обработка только начинается');
    });

    test('Все модели молчат — язык прошлой обработки, без вопросов',
        () async {
      final copy = freshCopy(probeVideo);
      final (pipeline, stt) = scripted({
        'tr-TR': {1: '', 2: '', 3: ''},
        'uz-UZ': {1: '', 2: '', 3: ''},
      });
      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        previousLang: 'uz-UZ',
        sleep: (_) async {},
      );

      expect(probe.session.lang, 'uz-UZ');
      expect(probe.session.langConfidence, LanguageConfidence.none);
      expect(probe.session.langRunnerUp, 'tr-TR');
      // Самые длинные куски в шумном ролике часто оказываются техникой:
      // перед тем как сдаться, пробуем ещё одну часть записи.
      expect(stt.calls.map((c) => c.$2).toSet(), {1, 2, 3});
    });

    test('Отмена во время определения языка останавливает пробы', () async {
      final copy = freshCopy(probeVideo);
      final (pipeline, stt) = scripted({
        'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz'},
        'uz-UZ': {1: 'ertaga ertalab bozorga boramiz'},
      });
      await expectLater(
        pipeline.detectLanguage(
          videoPath: copy,
          candidates: const ['tr-TR', 'uz-UZ'],
          sleep: (_) async {},
          // Человек нажал «Отмена», пока шла первая проба.
          isCancelled: () => stt.calls.isNotEmpty,
        ),
        throwsA(isA<PipelineCancelledException>()),
      );
      expect(stt.calls, hasLength(1),
          reason: 'после отмены платные запросы не отправляются');
      expect(File('$copy.subtitler.json').existsSync(), isFalse,
          reason: 'язык не определён — сессию с догадкой не записываем');
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

  group('Смена языка', () {
    test('Пробы нового языка переиспользуются, прежний вариант — в копию',
        () async {
      final copy = freshCopy(probeVideo);
      final workDir = '${tmp.path}/work${workCounter++}';
      final stt = ScriptedStt(workDir, {
        'tr-TR': {
          1: 'yarın sabah erkenden çarşıya gideceğiz çünkü evde ekmek yok',
          2: 'tamam',
          3: 'akşam eve geç geleceğim sen beni bekleme tamam mı',
        },
        'uz-UZ': {
          1: 'yarin sabah erkandan charshiga gidajakmiz chunki evda ekmak yoq',
          2: 'tamom',
          3: 'aqsham eve gech gelajagim sen beni beklama tamom mi',
        },
      });
      final pipeline = build(stt, FakeTranslate(), workDir: workDir);
      final probe = await pipeline.detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );
      final turkish = await pipeline.process(
        videoPath: copy,
        lang: 'tr-TR',
        resumeFrom: probe.session,
        sleep: (_) async {},
      );
      // Следователь поправил перевод и решил, что язык всё-таки узбекский.
      final edited = turkish.copyWith(cues: [
        turkish.cues.first.copyWith(ru: 'правка следователя'),
        ...turkish.cues.skip(1),
      ]);
      stt.calls.clear();

      final uzbek = await pipeline.process(
        videoPath: copy,
        lang: 'uz-UZ',
        resumeFrom: edited,
        sleep: (_) async {},
      );

      expect(stt.calls, [('uz-UZ', 2)],
          reason: 'реплики 1 и 3 на узбекском уже оплачены пробами');
      expect(uzbek.lang, 'uz-UZ');
      expect(uzbek.cues.first.orig, startsWith('yarin sabah'));
      expect(uzbek.cues.every((c) => c.status == CueStatus.ok), isTrue);
      expect(uzbek.langConfidence, isNull, reason: 'язык выбрал человек');
      expect(uzbek.langRunnerUp, 'tr-TR');
      expect(uzbek.probeTexts.keys, containsAll(['tr-TR', 'uz-UZ']));

      final store = SessionStore(fallbackDir: tmp.path);
      final backup = await store.loadBackup(copy, 'tr-TR', uzbek.fingerprint);
      expect(backup!.cues.first.ru, 'правка следователя',
          reason: 'турецкий вариант с правками можно вернуть бесплатно');
      expect((await store.load(copy, uzbek.fingerprint))!.lang, 'uz-UZ');

      // Передумал ещё раз: обратно на турецкий — без единого запроса.
      stt.calls.clear();
      final back = await pipeline.process(
        videoPath: copy,
        lang: 'tr-TR',
        resumeFrom: uzbek,
        sleep: (_) async {},
      );
      expect(stt.calls, isEmpty);
      expect(back.lang, 'tr-TR');
      expect(back.cues.first.ru, 'правка следователя');
      expect(back.langRunnerUp, 'uz-UZ');
      expect(await store.backupLanguages(copy, back.fingerprint),
          {'tr-TR', 'uz-UZ'});
    });

    test('Пропажа сегментов не стирает пробы и уверенность', () async {
      final copy = freshCopy(probeVideo);
      final workDir = '${tmp.path}/work${workCounter++}';
      final stt = ScriptedStt(workDir, {
        'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz', 2: 'tamam'},
        'uz-UZ': {1: 'yarin sabah erkandan charshiga gidajakmiz'},
      });
      final probe = await build(stt, FakeTranslate(), workDir: workDir)
          .detectLanguage(
        videoPath: copy,
        candidates: const ['tr-TR', 'uz-UZ'],
        sleep: (_) async {},
      );
      Directory(workDir).deleteSync(recursive: true);

      final session = await build(stt, FakeTranslate(), workDir: workDir)
          .process(
        videoPath: copy,
        lang: probe.session.lang,
        resumeFrom: probe.session,
        sleep: (_) async {},
      );
      expect(session.probeTexts, probe.session.probeTexts);
      expect(session.langConfidence, probe.session.langConfidence);
      expect(session.langRunnerUp, probe.session.langRunnerUp);
    });

    test('Сессия другого файла для продолжения не используется', () async {
      final foreign = await build(FakeStt(['bir', 'iki', 'üç']), FakeTranslate())
          .process(videoPath: freshCopy(video), lang: 'tr-TR',
              sleep: (_) async {});
      final copy = freshCopy(probeVideo);
      final stt = FakeStt(['bir', 'iki', 'üç']);
      final session = await build(stt, FakeTranslate()).process(
        videoPath: copy,
        lang: 'tr-TR',
        resumeFrom: foreign,
        sleep: (_) async {},
      );
      expect(stt.calls, greaterThan(0), reason: 'чужие реплики не подставлены');
      expect(session.videoPath, copy);
    });
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
