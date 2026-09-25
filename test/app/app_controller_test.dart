import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cue_timeline.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_locator.dart';
import 'package:subtitler/core/languages.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/srt.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';
import '../support/file_access.dart';
import '../support/media.dart';

/// Турецкая речь на репликах 1 и 3 (самые длинные в пробном ролике),
/// узбекская модель пишет кальку. Тексты выдуманные; с ними язык
/// выбирается уверенно уже после первых проб (см. pipeline_test).
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

void main() {
  late Directory sources;
  late String probeClip;
  late String speechClip;
  late String silentClip;
  final burnSkip = burnSkipReason();

  setUpAll(() async {
    sources = Directory.systemTemp.createTempSync('app_controller_src_');
    probeClip = await makeProbeClip(p.join(sources.path, 'probe.mp4'));
    speechClip = await makeSpeechClip(p.join(sources.path, 'speech.mp4'));
    silentClip = await makeSilentVideo(p.join(sources.path, 'silent.mp4'));
  });
  tearDownAll(() => sources.deleteSync(recursive: true));

  /// Контроллер после init(): по умолчанию ключ сохранён — главный экран.
  Future<AppHarness> started({
    String? storedKey = kTestApiKey,
    AppSettings settings = const AppSettings(),
    Duration longVideoThreshold = kLongVideoThreshold,
    bool isMobile = false,
    bool noFfmpeg = false,
    FfmpegInfo? ffmpeg,
    Object? runtimeError,
  }) async {
    final h = makeTestController(
      storedKey: storedKey,
      settings: settings,
      longVideoThreshold: longVideoThreshold,
      isMobile: isMobile,
      noFfmpeg: noFfmpeg,
      ffmpeg: ffmpeg,
      runtimeError: runtimeError,
    );
    addTearDown(h.dispose);
    await h.controller.init();
    return h;
  }

  /// Ролик с турецкой речью, распознаваемый [ScriptedStt].
  Future<(AppHarness, ScriptedStt, String)> turkishVideo({
    AppSettings settings = const AppSettings(),
  }) async {
    final h = await started(settings: settings);
    final stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
    h.stt = stt;
    return (h, stt, h.copyVideo(probeClip));
  }

  /// Этапы, через которые прошёл контроллер, без повторов подряд.
  List<AppStage> recordStages(AppController c) {
    final stages = <AppStage>[c.stage];
    c.addListener(() {
      if (stages.last != c.stage) stages.add(c.stage);
    });
    return stages;
  }

  String beside(String video, String suffix) =>
      p.join(p.dirname(video), '${p.basenameWithoutExtension(video)}$suffix');

  Session sessionOnDisk(String video) => Session.fromJson(
      jsonDecode(File('$video.subtitler.json').readAsStringSync())
          as Map<String, dynamic>);

  group('Старт', () {
    test('Ключа нет — экран ключа; в журнале версия и ОС', () async {
      final h = await started(storedKey: null);
      expect(h.controller.stage, AppStage.needsKey);
      expect(h.controller.hasKey, isFalse);
      expect(h.controller.appVersion, '0.0.0-test');
      expect(h.log.asText(), contains('Subtitler 0.0.0-test'));
      expect(h.log.asText(), contains('тестовая ОС 1.0'));
    });

    test('Ключ сохранён — сразу главный экран', () async {
      final h = await started();
      expect(h.controller.stage, AppStage.home);
      expect(h.controller.hasKey, isTrue);
      expect(h.controller.keySaved, isTrue);
      expect(h.controller.canOpenVideo, isTrue);
    });

    test('Хранилище не читается — «ключа нет» и честная плашка', () async {
      final h = makeTestController();
      addTearDown(h.dispose);
      h.keyStore
        ..failRead = true
        ..selfTestResult = false;
      await h.controller.init();
      expect(h.controller.stage, AppStage.needsKey);
      expect(h.controller.keyStorageWorks, isFalse);
    });

    test('ffmpeg не найден — экран поломки с перебранными путями', () async {
      final h = await started(noFfmpeg: true);
      expect(h.controller.stage, AppStage.broken);
      final error = h.controller.error!;
      expect(error.title, 'Не найден компонент обработки видео');
      expect(error.hint, contains('Распакуйте архив заново целиком'));
      expect(error.details,
          contains(p.join(h.root.path, 'app', 'tools', 'ffmpeg', 'ffmpeg.exe')));
      expect(h.controller.canOpenVideo, isFalse);
    });

    test('ffmpeg без libass — тоже поломка, с версией в деталях', () async {
      final h = await started(
          ffmpeg: const FfmpegInfo(
              ffmpegPath: 'ffmpeg',
              ffprobePath: 'ffprobe',
              version: 'ffmpeg version 4.4-без-libass',
              hasLibass: false,
              source: 'PATH'));
      expect(h.controller.stage, AppStage.broken);
      expect(h.controller.error!.details, contains('4.4-без-libass'));
      expect(h.controller.error!.details, contains('libass: нет'));
    });

    test('На телефоне libass не проверяется: ffmpeg встроен', () async {
      final h = await started(
          isMobile: true,
          ffmpeg: const FfmpegInfo(
              ffmpegPath: 'встроенный',
              ffprobePath: 'встроенный',
              version: 'ffmpeg-kit',
              hasLibass: false,
              source: 'bundled'));
      expect(h.controller.stage, AppStage.home);
    });

    // Дефект 6: отладочный стенд падал на `runtime!` при вшивании, если
    // папки приложения не подготовились.
    test('Папки не подготовились — экран поломки, а не падение на null',
        () async {
      final h = await started(
          runtimeError: const FileSystemException('нет места', r'C:\профиль'));
      final c = h.controller;
      expect(c.stage, AppStage.broken);
      expect(c.error!.title, 'Не удалось подготовить папки программы');
      expect(c.canOpenVideo, isFalse);
      // Ни одно действие не должно ронять приложение.
      await c.openVideo(h.copyVideo(speechClip));
      await c.save();
      await c.goHome();
      expect(c.stage, AppStage.broken);
    });
  });

  group('Запуск с видео', () {
    /// Контроллер, запущенный с видео в командной строке (его перетащили
    /// на значок программы). Видео лежит в своей временной папке.
    Future<(AppHarness, String)> launchedWith({String? storedKey = kTestApiKey})
        async {
      final dir = Directory.systemTemp.createTempSync('open_on_start_');
      final video = p.join(dir.path, 'запись 1.mp4');
      File(probeClip).copySync(video);
      final h = makeTestController(
          root: dir, storedKey: storedKey, openOnStart: video);
      addTearDown(() async {
        await h.dispose();
        dir.deleteSync(recursive: true);
      });
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      return (h, video);
    }

    Future<void> waitForStage(AppController c, AppStage stage) async {
      for (var i = 0; i < 600 && c.stage != stage; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.stage, stage);
    }

    test('Видео со значка открывается само, без «Выбрать файл»', () async {
      final (h, video) = await launchedWith();
      await h.controller.init();
      await waitForStage(h.controller, AppStage.review);
      expect(h.controller.videoPath, video);
      expect(h.log.asText(), contains('Видео передано при запуске'));
    });

    test('Без ключа видео ждёт ключа и открывается сразу после него',
        () async {
      final (h, video) = await launchedWith(storedKey: null);
      final c = h.controller;
      await c.init();
      expect(c.stage, AppStage.needsKey);
      expect(c.videoPath, isNull, reason: 'без ключа обрабатывать нечем');

      expect(await c.submitKey('AQVN-vydumannyj-novyj-klyuch-0004'), isTrue);
      await waitForStage(c, AppStage.review);
      expect(c.videoPath, video);
    });
  });

  group('Ключ', () {
    test('Обе проверки прошли — ключ сохранён, главный экран', () async {
      final h = await started(storedKey: null);
      final c = h.controller;
      const key = 'AQVN-vydumannyj-novyj-klyuch-0003';
      expect(await c.submitKey('  $key  '), isTrue);
      expect(c.stage, AppStage.home);
      expect(c.hasKey, isTrue);
      expect(c.keyCheck.translate, CheckState.ok);
      expect(c.keyCheck.stt, CheckState.ok);
      expect(h.keyStore.value, key);
      expect(h.log.asText(), isNot(contains(key)));
    });

    // Дефект 11: saveKey записывал ключ в память до проверки — неверный
    // ключ оставался, и кнопка обработки становилась доступной.
    test('Неверный ключ не остаётся ни в памяти, ни в хранилище', () async {
      final h = await started(storedKey: null);
      final c = h.controller;
      h.translate = FakeTranslate()
        ..failWith = const AuthException(
            statusCode: 401, message: 'Ключ неверный или отозван');
      expect(await c.submitKey('AQVN-vydumannyj-nevernyj-klyuch'), isFalse);
      expect(c.stage, AppStage.needsKey);
      expect(c.hasKey, isFalse);
      expect(c.canOpenVideo, isFalse);
      expect(h.keyStore.value, isNull);
      expect(c.keyCheck.error!.title, 'Ключ неверный или отозван');
      expect(c.keyCheck.error!.action, UserErrorAction.changeKey);
    });

    test('Замена ключа на неверный: прежний ключ продолжает работать',
        () async {
      final h = await started();
      final c = h.controller;
      c.changeKey();
      expect(c.stage, AppStage.needsKey);
      expect(c.canCancelKeyChange, isTrue);
      h.translate = FakeTranslate()
        ..failWith = const AuthException(
            statusCode: 401, message: 'Ключ неверный или отозван');
      expect(await c.submitKey('AQVN-vydumannyj-nevernyj-klyuch-2'), isFalse);
      c.cancelKeyChange();
      expect(c.stage, AppStage.home);
      expect(h.keyStore.value, kTestApiKey);

      // Обработка идёт с прежним ключом, а не с отвергнутым.
      h.translate = FakeTranslate();
      h.keysUsed.clear();
      await c.openVideo(h.copyVideo(speechClip));
      expect(h.keysUsed, isNotEmpty);
      expect(h.keysUsed.toSet(), {kTestApiKey});
    });

    test('Хранилище не пишет — ключ работает до закрытия программы', () async {
      final h = await started(storedKey: null);
      h.keyStore.failWrite = true;
      expect(await h.controller.submitKey(kTestApiKey), isTrue);
      expect(h.controller.stage, AppStage.home);
      expect(h.controller.keySaved, isFalse);
    });

    test('«Удалить ключ» — экран ключа, в хранилище пусто', () async {
      final h = await started();
      await h.controller.forgetKey();
      expect(h.controller.stage, AppStage.needsKey);
      expect(h.controller.hasKey, isFalse);
      expect(h.keyStore.value, isNull);
    });
  });

  group('Выбор видео', () {
    test('Не видео — короткое сообщение, этап не меняется', () async {
      final h = await started();
      final c = h.controller;
      final stt = FakeStt(const []);
      h.stt = stt;
      final fake = File(p.join(h.root.path, 'протокол.mp4'))
        ..writeAsStringSync('Выдуманный текст протокола, а не видео.');
      final stages = recordStages(c);

      await c.openVideo(fake.path);

      expect(stages, [AppStage.home]);
      expect(c.notice!.title, 'Это не видео или файл повреждён');
      expect(c.canOpenVideo, isTrue, reason: 'можно сразу выбрать другой файл');
      expect(stt.calls, 0);
      c.dismissNotice();
      expect(c.notice, isNull);
    });

    test('Видео без звука — сообщение на главном экране', () async {
      final h = await started();
      await h.controller.openVideo(h.copyVideo(silentClip));
      expect(h.controller.stage, AppStage.home);
      expect(h.controller.notice!.title, 'В этом видео нет звука');
    });

    test('Ролик длиннее порога — ждём подтверждения, ничего не платим',
        () async {
      final h = await started(longVideoThreshold: const Duration(seconds: 5));
      final c = h.controller;
      final stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      h.stt = stt;
      final video = h.copyVideo(probeClip);

      await c.openVideo(video);
      expect(c.stage, AppStage.home);
      expect(c.longVideoQuestion!.videoPath, video);
      expect(c.longVideoQuestion!.duration.inSeconds, 15);
      expect(stt.calls, isEmpty);

      c.declineLongVideo();
      expect(c.longVideoQuestion, isNull);
      expect(c.stage, AppStage.home);

      await c.openVideo(video);
      await c.confirmLongVideo();
      expect(c.stage, AppStage.review);
      expect(stt.calls, isNotEmpty);
    });

    test('Порог по умолчанию — 15 минут', () {
      expect(kLongVideoThreshold, const Duration(minutes: 15));
    });

    // Дефект 2: во время работы перетащенное видео подменяло videoPath,
    // и SRT старой сессии записывался под именем нового.
    test('Видео во время обработки не принимается', () async {
      final h = await started();
      final c = h.controller;
      final stt = GatedStt(ScriptedStt(h.runtime.workDir, turkishSpeech));
      h.stt = stt;
      final first = h.copyVideo(probeClip, name: 'первое.mp4');
      final second = h.copyVideo(speechClip, name: 'второе.mp4');

      final done = c.openVideo(first);
      await stt.reached;
      expect(c.canOpenVideo, isFalse);
      await c.openVideo(second);
      expect(c.videoPath, first);
      stt.release();
      await done;

      expect(c.stage, AppStage.review);
      expect(c.videoPath, first);
      expect(File(beside(first, '_ru.srt')).readAsStringSync(),
          contains('RU:yarın sabah'));
      expect(File(beside(second, '_ru.srt')).existsSync(), isFalse);
      expect(File('$second.subtitler.json').existsSync(), isFalse);
    });
  });

  group('Обработка', () {
    test('Язык уверенный — сразу редактор, без вопросов', () async {
      final (h, stt, video) = await turkishVideo();
      final c = h.controller;
      final stages = recordStages(c);
      final seen = <(ProcessingProgress?, String?)>[];
      c.addListener(() {
        if (c.stage == AppStage.processing) seen.add((c.progress, c.language));
      });

      await c.openVideo(video);

      expect(stages, [AppStage.home, AppStage.processing, AppStage.review]);
      expect(c.language, 'tr-TR');
      expect(c.languageTitle, 'турецкий');
      expect(c.languageConfidence, LanguageConfidence.high);
      expect(c.languageRunnerUp, 'uz-UZ');
      expect(c.session!.cues.every((cue) => cue.ru.startsWith('RU:')), isTrue);
      expect(File(beside(video, '_ru.srt')).readAsStringSync(),
          contains('RU:akşam eve'));

      final steps = seen.map((s) => s.$1?.step).toSet();
      expect(steps, containsAll(ProcessingStep.values));
      // Счёт распознавания — от всех реплик ролика: две из трёх уже
      // распознаны пробами.
      expect(seen.map((s) => s.$1?.label), contains('Распознаём речь: 2 из 3'));
      // Язык виден, пока распознаётся остальное.
      expect(
          seen.any((s) =>
              s.$1?.step == ProcessingStep.recognizing && s.$2 == 'tr-TR'),
          isTrue);
      expect(stt.callsFor('tr-TR').length + stt.callsFor('uz-UZ').length, 5);
    });

    test('Автоопределение идёт среди языков из настроек', () async {
      final h = await started(
          settings: const AppSettings(detectionCandidates: ['uz-UZ', 'kk-KZ']));
      final stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      h.stt = stt;
      await h.controller.openVideo(h.copyVideo(probeClip));
      expect(stt.calls.map((c) => c.$1).toSet(), {'uz-UZ', 'kk-KZ'});
    });

    test('Готовая сессия открывается без единого вызова распознавания',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      await c.goHome();

      final stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      final translate = FakeTranslate();
      h
        ..stt = stt
        ..translate = translate;
      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      expect(c.session!.cues.first.ru, startsWith('RU:'));
      expect(stt.calls, isEmpty);
      expect(translate.calls, 0);

      // И после перезапуска программы — тоже.
      final again = makeTestController(root: h.root, stt: stt);
      addTearDown(again.dispose);
      await again.controller.init();
      await again.controller.openVideo(video);
      expect(again.controller.stage, AppStage.review);
      expect(stt.calls, isEmpty);
    });

    // Дефект 1: отмена во время определения языка терялась — run()
    // сбрасывал флаг, и запускалась полная платная обработка.
    test('Отмена при определении языка — ни одного платного запроса после',
        () async {
      final h = await started();
      final c = h.controller;
      final stt = GatedStt(ScriptedStt(h.runtime.workDir, turkishSpeech));
      final translate = FakeTranslate();
      h
        ..stt = stt
        ..translate = translate;
      final video = h.copyVideo(probeClip);

      final done = c.openVideo(video);
      await stt.reached;
      expect(c.progress!.step, ProcessingStep.detectingLanguage);
      c.cancel();
      expect(c.cancelRequested, isTrue);
      stt.release();
      await done;

      expect(c.stage, AppStage.cancelled);
      expect(stt.calls, 1, reason: 'только запрос, который уже был в пути');
      expect(translate.calls, 0);
      expect(c.canOpenPartial, isFalse, reason: 'открывать нечего');
      expect(File('$video.subtitler.json').existsSync(), isFalse);

      await c.goHome();
      expect(c.stage, AppStage.home);
    });

    test('Отмена при распознавании — «Открыть, что успели»', () async {
      final h = await started();
      final c = h.controller;
      // 4 пробы (2 реплики × 2 языка), пятый запрос — первая реплика
      // основного распознавания.
      final stt =
          GatedStt(ScriptedStt(h.runtime.workDir, turkishSpeech), gateAt: 5);
      h.stt = stt;

      final done = c.openVideo(h.copyVideo(probeClip));
      await stt.reached;
      expect(c.progress!.step, ProcessingStep.recognizing);
      c.cancel();
      stt.release();
      await done;

      expect(c.stage, AppStage.cancelled);
      expect(c.canOpenPartial, isTrue);
      expect(stt.calls, 5);
      await c.openPartial();
      expect(c.stage, AppStage.review);
      expect(c.session!.cues.where((cue) => cue.orig.isNotEmpty), hasLength(3));
    });

    test('Остановленная до перевода сессия при повторном открытии доводится',
        () async {
      final h = await started();
      final c = h.controller;
      final stt =
          GatedStt(ScriptedStt(h.runtime.workDir, turkishSpeech), gateAt: 5);
      h.stt = stt;
      final video = h.copyVideo(probeClip);
      final done = c.openVideo(video);
      await stt.reached;
      c.cancel();
      stt.release();
      await done;
      await c.goHome();

      // Всё распознано, но перевести не успели: открыть «как готовую»
      // было бы ошибкой — перевода не появилось бы никогда.
      final again = ScriptedStt(h.runtime.workDir, turkishSpeech);
      final translate = FakeTranslate();
      h
        ..stt = again
        ..translate = translate;
      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      expect(again.calls, isEmpty, reason: 'распознанное повторно не оплачивается');
      expect(translate.calls, 1);
      expect(c.session!.cues.every((cue) => cue.ru.startsWith('RU:')), isTrue);
    });

    test('401 при обработке — ошибка с «Изменить ключ», затем продолжение',
        () async {
      final h = await started();
      final c = h.controller;
      h.stt = FakeStt(const [])
        ..failCalls = 1
        ..failWith = const AuthException(
            statusCode: 401, message: 'Ключ неверный или отозван');
      final video = h.copyVideo(probeClip);

      await c.openVideo(video);
      expect(c.stage, AppStage.failed);
      expect(c.error!.title, 'Ключ неверный или отозван');
      expect(c.error!.action, UserErrorAction.changeKey);
      expect(c.error!.details, isNot(contains(kTestApiKey)));

      c.changeKey();
      expect(c.stage, AppStage.needsKey);
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      const fresh = 'AQVN-vydumannyj-svezhij-klyuch-0004';
      expect(await c.submitKey(fresh), isTrue);
      await c.jobDone;
      expect(c.stage, AppStage.review);
      expect(c.videoPath, video);
      expect(h.keysUsed.last, fresh);
    });
  });

  group('Правка', () {
    test('«Речи нет» с вписанным текстом становится обычной репликой',
        () async {
      final h = await started();
      final c = h.controller;
      h.stt = FakeStt(const ['', '', '']); // модели ничего не услышали
      final video = h.copyVideo(speechClip);
      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      final cue = c.session!.cues.first;
      expect(cue.status, CueStatus.empty);

      c.updateTranslation(cue.index, 'вписал сам: здесь говорят о встрече');

      final edited = c.session!.cues.first;
      expect(edited.status, CueStatus.ok);
      // Предпросмотр и вшивание видят реплику одинаково.
      expect(isCueVisible(edited), isTrue);
      expect(buildSrt(c.session!.cues, field: SrtField.ru),
          contains('вписал сам'));

      // Обратное не делается: стёртый текст не превращает реплику в «речи нет».
      c.updateTranslation(cue.index, '');
      expect(c.session!.cues.first.status, CueStatus.ok);
    });

    test('Правка снимает пометку «перевод не получен»', () async {
      final h = await started();
      final c = h.controller;
      c.debugEmulate(stage: AppStage.review, session: sampleSession());
      expect(c.reviewCount, 3);
      c.updateTranslation(4, 'вечером приду домой поздно');
      expect(c.session!.cues[3].flags, isNot(contains(CueFlag.translateFailed)));
      expect(c.reviewCount, 2);
      c.updateTranslation(4, ' ');
      expect(c.session!.cues[3].flags, contains(CueFlag.translateFailed));
    });

    test('Правки уходят на диск с задержкой', () async {
      final h = makeTestController(
          editSaveDelay: const Duration(milliseconds: 50));
      addTearDown(h.dispose);
      final c = h.controller;
      await c.init();
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      final video = h.copyVideo(probeClip);
      await c.openVideo(video);

      c.updateTranslation(1, 'правка следователя');
      expect(sessionOnDisk(video).cues.first.ru, isNot('правка следователя'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.flush();
      expect(sessionOnDisk(video).cues.first.ru, 'правка следователя');
      expect(File(beside(video, '_ru.srt')).readAsStringSync(),
          contains('правка следователя'));
    });

    test('Видео перенесли вместе с сессией — правки пишутся к новому месту',
        () async {
      final (h, stt, videoA) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(videoA);
      expect(c.stage, AppStage.review);
      await c.goHome();

      // Папку дела скопировали: видео и его сессия лежат по новому пути,
      // прежняя копия осталась на месте.
      final videoB = h.copyVideo(videoA,
          folder: 'копия дела', name: p.basename(videoA));
      File('$videoA.subtitler.json').copySync('$videoB.subtitler.json');
      final sessionA = File('$videoA.subtitler.json').readAsStringSync();
      final srtA = File(beside(videoA, '_ru.srt')).readAsStringSync();

      stt.calls.clear();
      await c.openVideo(videoB);
      expect(c.stage, AppStage.review);
      expect(stt.calls, isEmpty, reason: 'сессия подошла по отпечатку');
      c.updateTranslation(1, 'правка следователя');
      await c.flush();

      expect(sessionOnDisk(videoB).cues.first.ru, 'правка следователя');
      expect(File(beside(videoB, '_ru.srt')).readAsStringSync(),
          contains('правка следователя'));
      expect(File('$videoA.subtitler.json').readAsStringSync(), sessionA,
          reason: 'правка не должна уходить к чужой копии вещдока');
      expect(File(beside(videoA, '_ru.srt')).readAsStringSync(), srtA);

      await c.goHome();
      await c.openVideo(videoB);
      expect(c.session!.cues.first.ru, 'правка следователя');
      expect(stt.calls, isEmpty);
    });

    test('Прежнего места видео больше нет — плашки «записать нельзя» нет',
        () async {
      final (h, _, videoA) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(videoA);
      await c.goHome();

      // Флешка стала другим диском: по старому пути ничего нет.
      final videoB = h.copyVideo(videoA,
          folder: 'флешка', name: p.basename(videoA));
      File('$videoA.subtitler.json').copySync('$videoB.subtitler.json');
      Directory(p.dirname(videoA)).deleteSync(recursive: true);

      await c.openVideo(videoB);
      expect(c.stage, AppStage.review);
      expect(c.outputInFallback, isFalse,
          reason: 'рядом с видео писать можно — ложная плашка путает');
      expect(File(beside(videoB, '_ru.srt')).existsSync(), isTrue);
    });

    // Дефект 3: «Вшить» сразу после правки брал с диска старый SRT —
    // правка попадала туда только через 700 мс.
    test('Сохранение сразу после правки берёт свежий текст', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      String? burned;
      h.runner.onBurn = (_) => burned = File(
              p.join(h.runtime.workDirFor(video), 'burn_ru.srt'))
          .readAsStringSync();

      c.updateTranslation(1, 'свежая правка следователя');
      await c.save();

      expect(burned, contains('свежая правка следователя'));
      expect(File(beside(video, '_ru.srt')).readAsStringSync(),
          contains('свежая правка следователя'));
      expect(sessionOnDisk(video).cues.first.ru, 'свежая правка следователя');
    });
  });

  group('Сохранение видео', () {
    test('Готовое видео рядом с исходником, «Открыть папку»', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      await c.save();

      expect(c.saveStatus, SaveStatus.saved, reason: '${c.saveError}');
      final result = c.saveResult!;
      expect(result.videoPath, beside(video, '_ru.mp4'));
      expect(result.inFallback, isFalse);
      expect(File(result.videoPath).existsSync(), isTrue);
      expect(File(beside(video, '_ru.partial.mp4')).existsSync(), isFalse);
      expect(File(p.join(h.runtime.workDirFor(video), 'burn_ru.srt')).existsSync(),
          isTrue,
          reason: 'SRT для вшивания — в рабочей папке');

      await c.revealOutput();
      expect(h.revealed, [result.videoPath]);
      expect(h.shared, isEmpty);

      // Правка после сохранения — готовый файл устарел.
      c.updateTranslation(1, 'ещё одна правка');
      expect(c.saveStatus, SaveStatus.idle);
      expect(c.saveResult, isNull);
    }, skip: burnSkip);

    // Дефект 4: во время вшивания интерфейс писал «Готово» — прогресс
    // приходил как этап done без счёта.
    test('Прогресс вшивания — доля длительности, а не «Готово»', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      h.runner.burnProgress = [7.5]; // половина пятнадцатисекундного ролика
      final seen = <(SaveStatus, double)>[];
      c.addListener(() => seen.add((c.saveStatus, c.saveProgress)));

      await c.save();

      expect(seen, contains((SaveStatus.burning, 0.5)));
      final whileBurning =
          seen.takeWhile((s) => s.$1 == SaveStatus.burning).length;
      expect(seen.take(whileBurning + 1).map((s) => s.$1),
          isNot(contains(SaveStatus.saved)),
          reason: 'пока кодируется — «Сохраняем… 50 %», а не «Готово»');
    });

    // Дефект 8: при провале проверки видимости файл оставался под
    // финальным именем и выглядел готовым.
    test('Субтитры не видны — финального файла нет, временный удалён',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      h.runner.rewriteBurn = withoutSubtitles;

      await c.save();

      expect(c.saveStatus, SaveStatus.failed);
      expect(c.saveError!.title,
          'Субтитры не отрисовались — сообщите разработчику');
      expect(c.saveError!.details, contains('пикселей'));
      expect(File(beside(video, '_ru.mp4')).existsSync(), isFalse);
      expect(File(beside(video, '_ru.partial.mp4')).existsSync(), isFalse);
      expect(c.stage, AppStage.review, reason: 'правки не теряются');
    });

    test('Готовый файл открыт в другой программе — понятное сообщение',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      final target = File(beside(video, '_ru.mp4'))..writeAsStringSync('старое');
      final lock = await holdFileLock(target.path);
      try {
        await c.save();
      } finally {
        await lock.release();
      }

      expect(c.saveStatus, SaveStatus.failed);
      expect(c.saveError!.title,
          'Файл ${p.basename(target.path)} открыт в другой программе, '
          'закройте его и повторите');
      expect(c.saveError!.action, UserErrorAction.retry);
      expect(h.runner.burnCalls, 0, reason: 'кодировать впустую не начинали');
      expect(target.readAsStringSync(), 'старое');

      if (burnSkip == null) {
        await c.save(); // программу закрыли — «Повторить»
        expect(c.saveStatus, SaveStatus.saved, reason: '${c.saveError}');
      }
    }, skip: Platform.isWindows ? null : lockSkipReason);

    test('Рядом с видео писать нельзя — всё в папке приложения', () async {
      final (h, _, _) = await turkishVideo();
      final c = h.controller;
      final folder = Directory(p.join(h.root.path, 'вещдок'))..createSync();
      final video = p.join(folder.path, 'clip.mp4');
      File(probeClip).copySync(video);
      addTearDown(makeUnwritable(folder.path, video));

      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      expect(c.outputInFallback, isTrue);
      await c.save();

      expect(c.saveStatus, SaveStatus.saved, reason: '${c.saveError}');
      final result = c.saveResult!;
      expect(result.inFallback, isTrue);
      expect(result.videoPath, startsWith(h.runtime.outputDir));
      expect(File(result.videoPath).existsSync(), isTrue);
      expect(File(result.ruSrtPath).readAsStringSync(), contains('RU:'));
      expect(c.outputDir, result.dir);
    }, skip: burnSkip);

    test('Android: вместо «Открыть папку» — «Поделиться» видео и обоими .srt',
        () async {
      final h = await started(isMobile: true);
      final c = h.controller;
      const result = SaveResult(
        videoPath: '/data/clip_ru.mp4',
        origSrtPath: '/data/clip_orig.srt',
        ruSrtPath: '/data/clip_ru.srt',
        inFallback: false,
      );
      c.debugEmulate(
          stage: AppStage.review,
          session: sampleSession(),
          saveStatus: SaveStatus.saved,
          saveResult: result);
      await c.revealOutput();
      expect(h.shared.single,
          ['/data/clip_ru.mp4', '/data/clip_orig.srt', '/data/clip_ru.srt']);
      expect(h.revealed, isEmpty);
    });
  });

  group('Язык', () {
    test('Переключение на язык из резервной копии бесплатно', () async {
      final (h, stt, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      c.updateTranslation(1, 'правка следователя');

      // Первый раз на узбекский — платно, но только непробованная реплика.
      stt.calls.clear();
      final stages = recordStages(c);
      final steps = <List<ProcessingStep>>[];
      c.addListener(() {
        if (c.stage == AppStage.processing) steps.add(c.processingSteps);
      });
      await c.switchLanguage('uz-UZ');
      expect(stages, [AppStage.review, AppStage.processing, AppStage.review]);
      expect(steps.last, isNot(contains(ProcessingStep.detectingLanguage)));
      expect(stt.calls, [('uz-UZ', 2)]);
      expect(c.language, 'uz-UZ');
      expect(c.languageConfidence, isNull, reason: 'язык выбрал человек');
      final back = c.languageChoices.first;
      expect(back.code, 'tr-TR');
      expect(back.ready, isTrue);

      // Обратно — из резервной копии, с правкой и без запросов.
      stt.calls.clear();
      final translate = FakeTranslate();
      h.translate = translate;
      await c.switchLanguage('tr-TR');
      expect(stt.calls, isEmpty);
      expect(translate.calls, 0);
      expect(c.stage, AppStage.review);
      expect(c.language, 'tr-TR');
      expect(c.session!.cues.first.ru, 'правка следователя');
      expect(c.languageChoices.first.code, 'uz-UZ');
      expect(c.languageChoices.first.ready, isTrue);
      expect(stages.last, AppStage.review);
    });

    test('Недоделанная резервная копия не «готова» и при выборе доделывается',
        () async {
      final h = await started();
      final c = h.controller;
      final texts = {
        ...turkishSpeech,
        'kk-KZ': {
          1: 'erteñ tañerteñ bazarğa baramız',
          2: 'jaqsı',
          3: 'keşke üyge keş kelemin',
        },
      };
      h.stt = ScriptedStt(h.runtime.workDir, texts);
      final video = h.copyVideo(probeClip);
      await c.openVideo(video);
      expect(c.language, 'tr-TR');

      // На казахский (платно) — и «Отмена» на первой же реплике.
      final gated =
          GatedStt(ScriptedStt(h.runtime.workDir, texts), gateAt: 1);
      h.stt = gated;
      final switching = c.switchLanguage('kk-KZ');
      await gated.reached;
      c.cancel();
      gated.release();
      await switching;
      expect(c.stage, AppStage.cancelled);
      await c.openPartial();
      expect(c.session!.cues.where((cue) => cue.status == CueStatus.pending),
          isNotEmpty);

      // Обратно на турецкий — бесплатно; недоделанный казахский ушёл в копию.
      await c.switchLanguage('tr-TR');
      expect(c.language, 'tr-TR');
      final kazakh = c.allLanguageChoices.firstWhere((l) => l.code == 'kk-KZ');
      expect(kazakh.ready, isFalse,
          reason: 'ролик на казахском распознан не целиком — «готово» '
              'было бы неправдой');

      // Снова казахский: остальные реплики распознаются, уже распознанная
      // повторно не оплачивается.
      final stt = ScriptedStt(h.runtime.workDir, texts);
      h.stt = stt;
      await c.switchLanguage('kk-KZ');
      expect(c.stage, AppStage.review);
      expect(c.language, 'kk-KZ');
      expect(c.session!.cues.map((cue) => cue.status),
          everyElement(CueStatus.ok));
      expect(c.session!.cues.every((cue) => cue.ru.startsWith('RU:')), isTrue);
      expect(stt.calls, [('kk-KZ', 2), ('kk-KZ', 3)]);
    });

    // Дефект 5: в вопросе о языке русский вариант был подписан
    // «Узбекская модель» — подпись не бралась из таблицы языков.
    test('Меню «Не тот язык?»: второй язык первым, названия по-русски',
        () async {
      final h = await started();
      final c = h.controller;
      c.debugEmulate(
        stage: AppStage.review,
        session: sampleSession(runnerUp: 'ru-RU'),
        backupLanguages: {'kk-KZ'},
      );

      final menu = c.languageChoices;
      expect(menu.map((m) => m.code), ['ru-RU', 'uz-UZ', 'kk-KZ']);
      expect(menu.map((m) => m.name), ['русский', 'узбекский', 'казахский']);
      expect(menu.first.isRunnerUp, isTrue);
      expect(menu[1].probedCues, 1, reason: 'узбекская проба оплачена');
      expect(menu.last.ready, isTrue);

      final all = c.allLanguageChoices;
      expect(all, hasLength(kLanguages.length - 1));
      expect(all.map((m) => m.code), isNot(contains('tr-TR')));
      for (final choice in all) {
        expect(choice.name, languageName(choice.code));
      }
    });

    test('Языки автоопределения сохраняются между запусками', () async {
      final root = Directory.systemTemp.createTempSync('app_settings_');
      addTearDown(() => root.deleteSync(recursive: true));
      final first = makeTestController(root: root, persistentSettings: true);
      await first.controller.init();
      await first.controller.toggleDetectionCandidate('kk-KZ');
      await first.controller.toggleDetectionCandidate('tr-TR');
      expect(first.controller.settings.detectionCandidates, ['uz-UZ', 'kk-KZ']);
      await first.dispose();

      final second = makeTestController(root: root, persistentSettings: true);
      addTearDown(second.dispose);
      await second.controller.init();
      expect(second.controller.settings.detectionCandidates, ['uz-UZ', 'kk-KZ']);

      // Последний язык не выключается: выбирать было бы не из чего.
      await second.controller.setDetectionCandidates(const []);
      expect(second.controller.settings.detectionCandidates, isNotEmpty);
    });
  });
}
