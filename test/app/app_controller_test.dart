import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cue_timeline.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_locator.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitler/core/languages.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/session_store.dart';
import 'package:subtitler/core/srt.dart';
import 'package:subtitler/main.dart';

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

/// Распознавание, у которого после [answered] ответов пропала сеть: дальше
/// каждый запрос — TransientException без кода, как у настоящего клиента.
class _NetworkLostAfter implements SpeechKitClient {
  final SpeechKitClient inner;
  final int answered;
  int calls = 0;

  _NetworkLostAfter(this.inner, {required this.answered});

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) {
    calls++;
    if (calls > answered) {
      throw const TransientException(
          message: 'Нет связи с сервисом распознавания');
    }
    return inner.recognize(oggBytes: oggBytes, lang: lang);
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

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

  /// Ждёт, пока [done] не станет истинным, но не дольше [timeout]: для
  /// записи, которую контроллер делает сам, по таймеру. Файл в это время
  /// может дописываться — ошибка чтения значит «ещё нет».
  Future<void> eventually(
    bool Function() done, {
    required String reason,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        if (done()) return;
      } on Exception {
        // ещё пишется
      }
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

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

    // main() собирает контроллер через launchController: связка «аргумент
    // запуска → видео» проверяется на той же функции, что работает в
    // программе.
    AppHarness launchedByMain(List<String> args) {
      final h = makeTestController(
          build: (services, log) =>
              launchController(args, services: services, log: log));
      addTearDown(h.dispose);
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      return h;
    }

    test('main: видео из аргументов запуска открывается само', () async {
      final dir = Directory.systemTemp.createTempSync('main_args_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = p.join(dir.path, 'запись 2.mp4');
      File(probeClip).copySync(video);
      final h = launchedByMain(['--enable-software-rendering', video]);

      await h.controller.init();
      await waitForStage(h.controller, AppStage.review);
      expect(h.controller.videoPath, video);
    });

    test('main: мусорный аргумент — «Это не видео», главный экран', () async {
      final dir = Directory.systemTemp.createTempSync('main_args_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final notVideo = p.join(dir.path, 'заметка.txt');
      File(notVideo).writeAsStringSync('это не видео');
      final h = launchedByMain([notVideo]);
      final c = h.controller;

      await c.init();
      for (var i = 0; i < 200 && c.notice == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.notice?.title, 'Это не видео или файл повреждён');
      expect(c.stage, AppStage.home);
      expect(c.videoPath, isNull);
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

  // Программа уже открыта, а видео бросили на значок: вторая копия не
  // запускается, запускалка отдаёт путь этой (receiveFromAnotherLaunch).
  group('Видео от повторного запуска', () {
    const busyTitle = 'Сначала закончите с текущим видео';

    test('на главном экране — открывается и обрабатывается', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      c.receiveFromAnotherLaunch(video);
      // Сначала проверка файла, потом обработка — ждём итога.
      for (var i = 0; i < 600 && c.stage != AppStage.review; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.videoPath, video);
      expect(c.stage, AppStage.review);
      expect(c.notice, isNull);
    });

    test('без ключа — ждёт ключа и открывается сразу после него', () async {
      final h = await started(storedKey: null);
      final c = h.controller;
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      final video = h.copyVideo(probeClip);
      c.receiveFromAnotherLaunch(video);
      expect(c.stage, AppStage.needsKey);
      expect(c.videoPath, isNull);

      expect(await c.submitKey('AQVN-vydumannyj-novyj-klyuch-0005'), isTrue);
      for (var i = 0; i < 600 && c.stage != AppStage.review; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(c.stage, AppStage.review);
      expect(c.videoPath, video);
    });

    test('во время обработки — понятное сообщение, текущая обработка идёт',
        () async {
      final h = await started();
      final c = h.controller;
      final stt = GatedStt(ScriptedStt(h.runtime.workDir, turkishSpeech));
      h.stt = stt;
      final first = h.copyVideo(probeClip, name: 'первое.mp4');
      final second = h.copyVideo(speechClip, name: 'второе.mp4');

      final done = c.openVideo(first);
      await stt.reached;
      c.receiveFromAnotherLaunch(second);
      expect(c.notice?.title, busyTitle);
      expect(c.notice?.hint, contains('второе.mp4'));
      expect(c.videoPath, first);
      stt.release();
      await done;
      expect(c.stage, AppStage.review);
      expect(c.videoPath, first);
      expect(File('$second.subtitler.json').existsSync(), isFalse);
    });

    test('на экране предпросмотра — сообщение, правки не бросаются', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      final other = h.copyVideo(speechClip, name: 'другое.mp4');

      c.receiveFromAnotherLaunch(other);

      expect(c.stage, AppStage.review);
      expect(c.videoPath, video);
      expect(c.notice?.title, busyTitle);
    });

    test('во время сохранения — сообщение', () async {
      final h = await started();
      final c = h.controller;
      c.debugEmulate(
          stage: AppStage.review,
          session: sampleSession(),
          saveStatus: SaveStatus.burning);
      c.receiveFromAnotherLaunch(r'C:\Дела\ещё.mp4');
      expect(c.notice?.title, busyTitle);
      expect(c.videoPath, sampleSession().videoPath);
    });

    test('то же видео ещё раз — без сообщения: оно уже открыто', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      c.receiveFromAnotherLaunch(video);
      expect(c.notice, isNull);
      expect(c.videoPath, video);
    });

    test('запуск без видео только выводит окно вперёд', () async {
      final h = await started();
      h.controller.receiveFromAnotherLaunch(null);
      expect(h.controller.stage, AppStage.home);
      expect(h.controller.notice, isNull);
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

    test('После обработки нарезанного звука в рабочей папке не остаётся',
        () async {
      final (h, _, video) = await turkishVideo();
      await h.controller.openVideo(video);
      expect(h.controller.stage, AppStage.review);
      expect(Directory(h.runtime.workDirFor(video)).existsSync(), isFalse);
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

    test('Закрытие окна при подготовке звука: ffmpeg остановлен, audio.wav '
        'удалён, платных запросов нет', () async {
      final (h, stt, video) = await turkishVideo();
      final c = h.controller;
      // Извлечение звука идёт со скоростью воспроизведения: 15 секунд.
      h.runner.rewrite =
          (args) => args.contains('pcm_s16le') ? inRealTime(args) : args;
      final audio = File(p.join(h.runtime.workDirFor(video), 'audio.wav'));
      final processing = c.openVideo(video);
      for (var i = 0; i < 400 && !audio.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(audio.existsSync(), isTrue, reason: 'ffmpeg начал писать звук');
      expect(c.progress?.step, ProcessingStep.preparingAudio);

      final stopwatch = Stopwatch()..start();
      await c.prepareToExit();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(c.stage, isNot(AppStage.processing),
          reason: 'обработка закончилась до закрытия, а не после');
      expect(audio.existsSync(), isFalse);
      await processing;
      expect(stt.calls, isEmpty);
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

    test('Отмена повторной нарезки начатой сессии — «Открыть, что успели»',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      await c.goHome();
      // Сессию начали на другом ПК: реплика 2 не распознана, а нарезки
      // на этом ПК нет.
      final saved = sessionOnDisk(video);
      File('$video.subtitler.json').writeAsStringSync(jsonEncode(saved
          .copyWith(cues: [
            for (final cue in saved.cues)
              cue.index == 2
                  ? cue.copyWith(
                      orig: '', ru: '', status: CueStatus.pending, flags: {})
                  : cue,
          ])
          .toJson()));
      final work = Directory(h.runtime.workDirFor(video));
      if (work.existsSync()) work.deleteSync(recursive: true);

      // «Отмена», пока ролик режется заново.
      c.addListener(() {
        if (c.stage == AppStage.processing && !c.cancelRequested) c.cancel();
      });
      await c.openVideo(video);

      expect(c.stage, AppStage.cancelled);
      expect(c.canOpenPartial, isTrue,
          reason: 'реплики 1 и 3 распознаны — показать есть что');
      await c.openPartial();
      expect(c.stage, AppStage.review);
      expect(c.session!.cues.where((cue) => cue.orig.isNotEmpty), hasLength(2));
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

    test('Нет сети — «Нет доступа к интернету» и «Повторить», язык наугад '
        'не выбран', () async {
      final h = await started();
      final c = h.controller;
      h.stt = FakeStt(const [])
        ..failCalls = 1000
        ..failWith = const TransientException(
            message: 'Нет связи с сервисом распознавания');
      final video = h.copyVideo(probeClip);

      await c.openVideo(video);
      expect(c.stage, AppStage.failed);
      expect(c.error!.title, 'Нет доступа к интернету');
      expect(c.error!.action, UserErrorAction.retry);
      expect(File('$video.subtitler.json').existsSync(), isFalse,
          reason: 'сессия с языком наугад закрепила бы неверный язык');
      expect(c.settings.lastLanguage, isNull);

      // Сеть вернулась.
      h.stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      await c.retry();
      expect(c.stage, AppStage.review);
      expect(c.language, 'tr-TR');
    });

    test('Сеть пропала во время распознавания — «Повторить» не платит за '
        'распознанное', () async {
      final h = await started();
      final c = h.controller;
      final scripted = ScriptedStt(h.runtime.workDir, turkishSpeech);
      // Четыре пробы прошли, дальше сети нет.
      h.stt = _NetworkLostAfter(scripted, answered: 4);
      final video = h.copyVideo(probeClip);

      await c.openVideo(video);
      expect(c.stage, AppStage.failed);
      expect(c.error!.title, 'Нет доступа к интернету');
      expect(sessionOnDisk(video).lang, 'tr-TR',
          reason: 'язык определён до обрыва — пробы сохранены');

      scripted.calls.clear();
      h.stt = scripted;
      await c.retry();
      expect(c.stage, AppStage.review);
      expect(scripted.calls, [('tr-TR', 2)],
          reason: 'реплики 1 и 3 уже распознаны пробами');
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

      // Стёрли — снова «речи нет»: распознанного оригинала у реплики нет,
      // сказать в кадре нечего.
      c.updateTranslation(cue.index, '');
      expect(c.session!.cues.first.status, CueStatus.empty);
    });

    // Стереть перевод — единственный способ убрать строку-бред из видео.
    // Раньше стёртое не отличалось от «перевод ещё не получен»: при
    // следующем открытии видео реплика переводилась заново, и строка
    // возвращалась в .srt, а потом и в видео.
    test('Стёртый человеком перевод не возвращается при повторном открытии',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      c.updateTranslation(1, ''); // убрал строку из видео
      await c.goHome();

      final translate = FakeTranslate();
      final stt = ScriptedStt(h.runtime.workDir, turkishSpeech);
      h
        ..translate = translate
        ..stt = stt;
      await c.openVideo(video);

      expect(c.stage, AppStage.review);
      expect(translate.calls, 0, reason: 'стёртое человеком не переводится');
      expect(stt.calls, isEmpty);
      expect(c.session!.cues.first.ru, '');
      expect(File(beside(video, '_ru.srt')).readAsStringSync(),
          isNot(contains('RU:yarın')));
    });

    test('Стёртый текст в «речи нет» — снова «речи нет», сессия готова',
        () async {
      final h = await started(longVideoThreshold: const Duration(seconds: 1));
      final c = h.controller;
      h.stt = FakeStt(const ['', '', '']); // модели ничего не услышали
      final video = h.copyVideo(speechClip);
      await c.openVideo(video);
      await c.confirmLongVideo();
      expect(c.stage, AppStage.review);
      final index = c.session!.cues.first.index;

      c.updateTranslation(index, 'вписал по ошибке');
      c.updateTranslation(index, '');
      expect(c.session!.cues.first.status, CueStatus.empty);
      await c.goHome();

      // Ролик «длинный» (порог 1 с), но делать с ним уже нечего: ни
      // вопроса о долгой платной обработке, ни запроса перевода.
      final translate = FakeTranslate();
      h.translate = translate;
      await c.openVideo(video);
      expect(c.longVideoQuestion, isNull);
      expect(c.stage, AppStage.review);
      expect(translate.calls, 0);
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
      // flush() здесь не зовём: он записал бы отложенную правку сам, и
      // тест не заметил бы, что таймер не заведён или не сработал. Правка
      // должна дойти до диска без явных действий — на случай, если
      // программа упадёт или компьютер выключат.
      await eventually(
        () =>
            sessionOnDisk(video).cues.first.ru == 'правка следователя' &&
            File(beside(video, '_ru.srt'))
                .readAsStringSync()
                .contains('правка следователя'),
        reason: 'правка не записалась сама через editSaveDelay',
      );
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
      // SRT для вшивания писался в рабочую папку — и после вшивания
      // удалён вместе с ней: перевод целиком уже лежит рядом с видео.
      expect(File(p.join(h.runtime.workDirFor(video), 'burn_ru.srt')).existsSync(),
          isFalse);
      expect(Directory(h.runtime.workDirFor(video)).existsSync(), isFalse);
      expect(File(beside(video, '_ru.srt')).existsSync(), isTrue);
      expect(File('$video.subtitler.json').existsSync(), isTrue);

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
      expect(c.saveError!.hint, contains('уже лежат рядом с видео'));
      expect(c.saveError!.details, contains('пикселей'));
      expect(File(beside(video, '_ru.mp4')).existsSync(), isFalse);
      expect(File(beside(video, '_ru.partial.mp4')).existsSync(), isFalse);
      expect(File(p.join(h.runtime.workDirFor(video), 'burn_ru.srt')).existsSync(),
          isFalse, reason: 'и при ошибке перевод в рабочей папке не остаётся');
      expect(c.stage, AppStage.review, reason: 'правки не теряются');
    });

    // Замечание ревью d2: вписанный человеком текст уходил в ffmpeg и
    // libass как разметка. «{…}» — блок тегов ASS: такая реплика в кадре
    // пропадала целиком, а проверка видимости (она смотрит самую длинную
    // реплику) ложно сообщала «Субтитры не отрисовались».
    test('Фигурные скобки в переводе вшиваются как есть', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      const marked = '{неразборчиво: говорят двое сразу, шумит улица}';
      c.updateTranslation(1, marked);
      c.updateTranslation(3, 'вечером');

      await c.save();

      expect(c.saveStatus, SaveStatus.saved, reason: '${c.saveError}');
      expect(File(beside(video, '_ru.srt')).readAsStringSync(),
          contains(marked),
          reason: 'файл для человека — без экранирования');
    }, skip: burnSkip);

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

    group('Готовый файл заняли уже после кодирования', () {
      // Плеер держит прежний <имя>_ru.mp4 так, что дописать можно, а
      // удалить нельзя: предварительная проба canReplace проходит, ролик
      // кодируется и проверяется, и только замена упирается в «занят».
      Future<(AppHarness, String, File, FileLockHolder)> failedReplace() async {
        final (h, _, video) = await turkishVideo();
        await h.controller.openVideo(video);
        final target = File(beside(video, '_ru.mp4'))..writeAsStringSync('старое');
        final lock = await holdFileLock(target.path, share: 'ReadWrite');
        var released = false;
        addTearDown(() async {
          if (!released) await lock.release();
        });
        await h.controller.save();
        expect(h.controller.saveStatus, SaveStatus.failed);
        expect(h.controller.saveError!.title,
            'Файл ${p.basename(target.path)} открыт в другой программе, '
            'закройте его и повторите');
        expect(h.runner.burnCalls, 1);
        await lock.release();
        released = true;
        return (h, video, target, lock);
      }

      test('проверенное видео не удаляется, «Повторить» только ставит его '
          'на место', () async {
        final (h, video, target, _) = await failedReplace();
        final partial = File(beside(video, '_ru.partial.mp4'));
        expect(partial.existsSync(), isTrue,
            reason: 'проверенное видео — годное, его не выбрасываем');
        final verifiedLength = partial.lengthSync();

        await h.controller.save(); // плеер закрыли — «Повторить»

        expect(h.controller.saveStatus, SaveStatus.saved,
            reason: '${h.controller.saveError}');
        expect(h.runner.burnCalls, 1, reason: 'заново не кодируем');
        expect(target.lengthSync(), verifiedLength);
        expect(partial.existsSync(), isFalse);
        expect(h.controller.saveResult!.videoPath, target.path);
      });

      test('после правки временное видео устарело — удаляется, повтор '
          'кодирует заново', () async {
        final (h, video, target, _) = await failedReplace();
        final partial = File(beside(video, '_ru.partial.mp4'));

        h.controller.updateTranslation(1, 'правка после ошибки');
        expect(partial.existsSync(), isFalse,
            reason: 'видео без этой правки ставить на место нельзя');
        await h.controller.save();

        expect(h.controller.saveStatus, SaveStatus.saved,
            reason: '${h.controller.saveError}');
        expect(h.runner.burnCalls, 2);
        expect(target.readAsStringSync(encoding: latin1), isNot('старое'));
      });

      test('программу закрыли, не нажав «Повторить», — проверенное видео не '
          'остаётся рядом с исходником', () async {
        final (h, video, _, _) = await failedReplace();
        final partial = File(beside(video, '_ru.partial.mp4'));
        expect(partial.existsSync(), isTrue);

        await h.controller.prepareToExit();

        expect(partial.existsSync(), isFalse);
      });

      test('временное видео пропало — повтор кодирует заново', () async {
        final (h, video, _, _) = await failedReplace();
        File(beside(video, '_ru.partial.mp4')).deleteSync();

        await h.controller.save();

        expect(h.controller.saveStatus, SaveStatus.saved,
            reason: '${h.controller.saveError}');
        expect(h.runner.burnCalls, 2);
      });
    }, skip: Platform.isWindows ? burnSkip : lockSkipReason);

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

    // Замечание ревью c20: при запасной папке сообщение уверяло, что .srt
    // «уже лежат рядом с видео», а плашка на том же экране — что они в
    // папке программы. Следователь искал бы их не там.
    test('Субтитры не видны, а .srt в папке приложения — сообщение называет '
        'эту папку', () async {
      final (h, _, _) = await turkishVideo();
      final c = h.controller;
      final folder = Directory(p.join(h.root.path, 'вещдок'))..createSync();
      final video = p.join(folder.path, 'clip.mp4');
      File(probeClip).copySync(video);
      addTearDown(makeUnwritable(folder.path, video));
      await c.openVideo(video);
      h.runner.rewriteBurn = withoutSubtitles;

      await c.save();

      expect(c.saveError!.title,
          'Субтитры не отрисовались — сообщите разработчику');
      expect(c.outputInFallback, isTrue);
      expect(c.saveError!.hint, isNot(contains('рядом с видео')));
      expect(c.saveError!.hint, contains(c.outputDir!));
      expect(c.outputDir, startsWith(h.runtime.outputDir));
    });

    // Замечание ревью c30: во время сохранения этап остаётся review, и
    // открыть другое видео не даёт только isBusy в canOpenVideo. Без него
    // перетащенный ролик сбросил бы видео и сохранение, а незаконченное
    // вшивание потом записало бы «Готово» старого ролика поверх нового.
    test('Во время сохранения другое видео не открывается', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      final other = h.copyVideo(probeClip);
      // Без libass: исход сохранения здесь не важен, важно, что оно идёт.
      h.runner.rewriteBurn = withoutSubtitles;

      final saving = c.save();
      expect(c.stage, AppStage.review);
      expect(c.isSaving, isTrue);
      await c.openVideo(other);
      await saving;

      expect(c.videoPath, video);
      expect(c.stage, AppStage.review);
      expect(c.saveStatus, isNot(SaveStatus.idle),
          reason: 'итог сохранения первого ролика не сброшен');
      expect(h.runner.calls.where((args) => args.contains(other)), isEmpty,
          reason: 'другое видео даже не проверялось');
    });

    // Контролируемый доступ к папкам разрешён только subtitler.exe: сама
    // программа пишет рядом с видео (.srt и проба canReplace проходят), а
    // ffmpeg.exe — нет. Вшивание должно уйти в запасную папку, а не
    // упираться в «Не удалось обработать видео» при каждом повторе.
    test('ffmpeg не пускают писать рядом с видео — видео в папке приложения',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      final besidePartial = beside(video, '_ru.partial.mp4');
      h.runner.answerBurn = (args) => args.last == besidePartial
          ? FfmpegResult(
              exitCode: -13,
              log: '[out#0/mp4 @ 000001] Error opening output $besidePartial: '
                  'Permission denied\n'
                  'Error opening output file $besidePartial.\n'
                  'Error opening output files: Permission denied\n')
          : null;

      await c.save();

      expect(c.saveStatus, SaveStatus.saved, reason: '${c.saveError}');
      final result = c.saveResult!;
      expect(result.inFallback, isTrue);
      expect(result.videoPath, startsWith(h.runtime.outputDir));
      expect(File(result.videoPath).existsSync(), isTrue);
      expect(result.ruSrtPath, beside(video, '_ru.srt'),
          reason: '.srt рядом с видео записать удалось — они там и остались');
      expect(c.outputInFallback, isTrue, reason: 'плашка с путём к видео');
      expect(h.runner.burnCalls, 2);
      expect(File(beside(video, '_ru.mp4')).existsSync(), isFalse);
      expect(h.log.asText(), contains('папку приложения'));
    }, skip: burnSkip);

    test('Другой сбой ffmpeg в запасную папку не уводит', () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      h.runner.answerBurn = (_) => const FfmpegResult(
          exitCode: 1, log: '[AVFilterGraph @ 000001] что-то сломалось');

      await c.save();

      expect(c.saveStatus, SaveStatus.failed);
      expect(c.saveError!.title, 'Не удалось обработать видео');
      expect(h.runner.burnCalls, 1);
    });

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

  // Журнал просят «сохранить и отправить разработчику». Раньше в нём были
  // распознанная речь (пробы всех языков и каждая реплика) и полные пути
  // к видео с названиями дел.
  test('В журнале нет ни текста записей, ни папки видео; ключ замаскирован',
      () async {
    final (h, stt, _) = await turkishVideo();
    final c = h.controller;
    final logFile = p.join(h.root.path, 'журнал', 'subtitler.log');
    h.log.attachFile(logFile);
    final video = h.copyVideo(probeClip,
        folder: p.join('Дела', 'Дело №7 (тест)'), name: 'clip.mp4');
    final folder = p.dirname(video);

    await c.openVideo(video);
    expect(c.stage, AppStage.review);
    expect(stt.calls, isNotEmpty);
    await c.save();
    h.log.warn('проверка маски ключа: $kTestApiKey');
    final exported = await c.exportLog();
    await h.log.close();

    final texts = {
      for (final byCue in turkishSpeech.values) ...byCue.values,
    };
    final journals = {
      'в памяти': h.log.asText(),
      'в файле': File(logFile).readAsStringSync(),
      '«Сохранить журнал»': File(exported).readAsStringSync(),
      '«Технические детали»': c.recentLog(lines: 1000),
      'ошибка с путём': describeError(
              FileSystemException('Не удалось открыть', video),
              mask: h.log.mask)
          .details,
    };
    for (final MapEntry(key: where, value: journal) in journals.entries) {
      for (final text in texts) {
        expect(journal, isNot(contains(text)),
            reason: 'распознанный текст $where');
      }
      expect(journal, isNot(contains('RU:')), reason: 'перевод $where');
      expect(journal, isNot(contains(folder)), reason: 'папка видео $where');
      expect(journal, isNot(contains('Дело №7')), reason: where);
      expect(journal, isNot(contains(kTestApiKey)), reason: where);
    }
    expect(h.log.asText(), contains('clip.mp4'),
        reason: 'имя файла остаётся — по нему видно, о каком видео речь');
    expect(h.log.asText(), contains('***КЛЮЧ***'));
  }, skip: burnSkip);

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
      // «Отмена» вернула турецкий, недоделанный казахский ушёл в копию.
      expect(c.stage, AppStage.review);
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

    // Раньше основной сессией после «Отмены» оставалась заготовка нового
    // языка: повторное открытие видео молча распознавало на нём весь
    // ролик — ровно то платное, от чего отказались, — а выправленный
    // вариант лежал только в резервной копии.
    test('Отмена платной смены языка — прежний язык остаётся основным, '
        'оплаченное на новом — в копии', () async {
      final (h, stt, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      c.updateTranslation(1, 'правка следователя');

      // «Не тот язык? → узбекский»: реплика 2 ушла в распознавание, и
      // человек передумал, пока запрос в пути.
      final gated = GatedStt(stt);
      h.stt = gated;
      final switching = c.switchLanguage('uz-UZ');
      await gated.reached;
      c.cancel();
      gated.release();
      await switching;

      final main = sessionOnDisk(video);
      expect(main.lang, 'tr-TR', reason: 'основной осталась прежняя сессия');
      expect(main.cues.first.ru, 'правка следователя');
      expect(main.langConfidence, LanguageConfidence.high);
      final store = SessionStore(fallbackDir: h.runtime.supportDir);
      final uzbek = await store.loadBackup(video, 'uz-UZ', main.fingerprint);
      expect(uzbek!.cues.firstWhere((cue) => cue.index == 2).status,
          CueStatus.ok, reason: 'ответ на ушедший запрос оплачен — не теряем');

      expect(c.stage, AppStage.review);
      expect(c.language, 'tr-TR');
      expect(c.session!.cues.first.ru, 'правка следователя');
      expect(c.notice!.title, 'Смена языка отменена');

      // Снова открыли то же видео — турецкий вариант, без запросов.
      await c.goHome();
      final again = ScriptedStt(h.runtime.workDir, turkishSpeech);
      h.stt = again;
      await c.openVideo(video);
      expect(c.stage, AppStage.review);
      expect(c.language, 'tr-TR');
      expect(again.calls, isEmpty);
    });

    test('Отмена смены языка, пока ролик режется заново, — тоже назад',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      final work = Directory(h.runtime.workDirFor(video));
      if (work.existsSync()) work.deleteSync(recursive: true);

      c.addListener(() {
        if (c.stage == AppStage.processing && !c.cancelRequested) c.cancel();
      });
      // На казахском проб нет: распознанного в заготовке нет вовсе.
      await c.switchLanguage('kk-KZ');

      expect(c.stage, AppStage.review);
      expect(c.language, 'tr-TR');
      expect(sessionOnDisk(video).lang, 'tr-TR');
      expect(c.notice!.title, 'Смена языка отменена');
    });

    // Замечание ревью c30: запрет открывать видео во время работы
    // проверялся только на этапе processing, где его и так даёт этап.
    // Бесплатная смена языка идёт на этапе review — там держит только
    // isBusy в canOpenVideo.
    test('Во время бесплатной смены языка другое видео не открывается',
        () async {
      final (h, _, video) = await turkishVideo();
      final c = h.controller;
      await c.openVideo(video);
      await c.switchLanguage('uz-UZ'); // турецкий уходит в резервную копию
      final other = h.copyVideo(probeClip);

      final switching = c.switchLanguage('tr-TR'); // из копии, бесплатно
      expect(c.stage, AppStage.review);
      expect(c.isBusy, isTrue);
      await c.openVideo(other);
      await switching;

      expect(c.videoPath, video);
      expect(c.language, 'tr-TR');
      expect(c.stage, AppStage.review);
      expect(h.runner.calls.where((args) => args.contains(other)), isEmpty,
          reason: 'другое видео даже не проверялось');
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
