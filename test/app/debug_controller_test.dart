import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/debug_controller.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/models.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';
import '../support/media.dart';

/// Выдуманная турецкая речь на репликах 1 и 3 пробного ролика; узбекская
/// модель пишет кальку. С ней язык выбирается уверенно после первых проб.
const _speech = {
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

/// Исправления отладочного стенда из f745a71 и 2f0eb16: ключ берётся только
/// после обеих проверок, «Вшить» без папок программы недоступно, отмена
/// доходит до определения языка, при смене языка ядро получает прежнюю
/// сессию.
void main() {
  late Directory sources;
  late String probeClip;

  setUpAll(() async {
    sources = Directory.systemTemp.createTempSync('debug_stand_src_');
    probeClip = await makeProbeClip(p.join(sources.path, 'probe.mp4'));
  });
  tearDownAll(() => sources.deleteSync(recursive: true));

  /// Стенд, как его открывает приложение: готовые папки, ffmpeg и
  /// хранилище ключа; клиенты Яндекса — подделки.
  DebugController openStand(
    AppHarness h, {
    SpeechKitClient? stt,
    TranslateClient? translate,
  }) {
    final stand = DebugController(
      runtime: h.runtime,
      ffmpeg: kTestFfmpeg,
      keyStore: h.keyStore,
      log: h.log,
      speechKit: (_) => stt ?? h.stt,
      translate: (_) => translate ?? h.translate,
    );
    addTearDown(stand.dispose);
    return stand;
  }

  AppHarness harness({String? storedKey = kTestApiKey}) {
    final h = makeTestController(storedKey: storedKey);
    addTearDown(h.dispose);
    return h;
  }

  test('неверный ключ не остаётся в памяти и не открывает «Обработать»',
      () async {
    final h = harness(storedKey: null);
    final translate = FakeTranslate()
      ..failWith = const AuthException(
          statusCode: 401, message: 'Ключ неверный или отозван');
    final stand = openStand(h, translate: translate);
    await stand.init();
    await stand.setVideo(h.copyVideo(probeClip));

    await stand.saveKey('AQVN-vydumannyj-nevernyj-klyuch-0006');

    expect(stand.apiKey, isEmpty);
    expect(stand.canRun, isFalse);
    expect(h.keyStore.value, isNull);
    expect(stand.keyError, isNotNull);

    // Перевод принял ключ, распознавание — нет: тоже не берём.
    translate.failWith = null;
    stand.sttCheck = CheckState.unknown;
    final stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = const AuthException(
          statusCode: 403, message: 'У ключа нет роли ai.speechkit-stt.user');
    final strict = openStand(h, stt: stt, translate: translate);
    await strict.init();
    await strict.setVideo(h.copyVideo(probeClip));
    await strict.saveKey('AQVN-vydumannyj-klyuch-bez-roli-0007');
    expect(strict.apiKey, isEmpty);
    expect(h.keyStore.value, isNull);

    // Обе проверки прошли — ключ взят и сохранён.
    await strict.saveKey(kTestApiKey);
    expect(strict.apiKey, kTestApiKey);
    expect(strict.canRun, isTrue);
    expect(h.keyStore.value, kTestApiKey);
  });

  test('«Вшить» без папок программы недоступно и не падает', () async {
    final h = harness();
    // Стенд, у которого папки программы не подготовились.
    final stand = DebugController(
      ffmpeg: kTestFfmpeg,
      keyStore: h.keyStore,
      log: h.log,
      speechKit: (_) => h.stt,
      translate: (_) => h.translate,
    );
    addTearDown(stand.dispose);
    stand.videoPath = h.copyVideo(probeClip);
    stand.session = sampleSession(videoPath: stand.videoPath!);

    expect(stand.canBurn, isFalse);
    await stand.burn();
    expect(stand.lastError, isNull, reason: 'шрифта для libass нет — не вшиваем');
    expect(stand.burnedPath, isNull);
  });

  test('отмена во время определения языка останавливает платные пробы',
      () async {
    final h = harness();
    final stt = GatedStt(ScriptedStt(h.runtime.workDir, _speech));
    final stand = openStand(h, stt: stt);
    await stand.init();
    await stand.setVideo(h.copyVideo(probeClip));

    final detecting = stand.detectLanguage();
    await stt.reached; // первая проба ушла
    stand.cancel();
    stt.release();
    await detecting;

    expect(stand.lastError, 'Отменено');
    expect(stt.calls, 1, reason: 'после отмены новых запросов нет');
    expect(stand.busy, isFalse);
  });

  test('смена языка отдаёт ядру прежнюю сессию: она уходит в резервную '
      'копию, оплаченные пробы не распознаются заново', () async {
    final h = harness();
    final stt = ScriptedStt(h.runtime.workDir, _speech);
    final stand = openStand(h, stt: stt);
    await stand.init();
    final video = h.copyVideo(probeClip);
    await stand.setVideo(video);

    await stand.detectLanguage();
    expect(stand.lang, 'tr-TR');
    await stand.run();
    expect(stand.session?.lang, 'tr-TR');
    final uzBefore = stt.callsFor('uz-UZ').length;

    stand.setLang('uz-UZ');
    await stand.run();

    expect(stand.lastError, isNull);
    expect(stand.session?.lang, 'uz-UZ');
    expect(File('$video.subtitler.tr-TR.json').existsSync(), isTrue,
        reason: 'турецкий вариант с правками можно вернуть бесплатно');
    // Реплики 1 и 3 на узбекском уже распознаны пробами — платим за 2-ю.
    expect(stt.callsFor('uz-UZ').length - uzBefore, 1);
    expect(stand.session!.cues.map((c) => c.status),
        everyElement(isNot(CueStatus.pending)));
  });
}
