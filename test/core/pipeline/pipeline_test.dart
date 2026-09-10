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
  final runner = ProcessFfmpegRunner();
  var workCounter = 0;

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
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// Каждому прогону — своя рабочая папка, кроме случаев, когда тест
  /// намеренно продолжает предыдущий (тогда путь передаётся явно).
  Pipeline build(FakeStt stt, FakeTranslate tr, {String? workDir}) => Pipeline(
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
    var checks = 0;
    final stt = FakeStt(['bir', 'iki', 'üç']);
    final session = await build(stt, FakeTranslate()).process(
      videoPath: video,
      lang: 'tr-TR',
      sleep: (_) async {},
      // Первая проверка пропускает один сегмент, дальше — отмена.
      isCancelled: () => checks++ > 0,
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
}
