import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/logging.dart';

import '../support/fakes.dart';
import '../support/media.dart';

void main() {
  const key = 'AQVN-vydumannyj-klyuch-proverki-0002';

  KeyChecker checker(FakeStt stt, FakeTranslate translate, DebugLog log) =>
      KeyChecker(
          translate: (_) => translate, speechKit: (_) => stt, log: log);

  test('Обе роли есть — обе галочки зелёные', () async {
    final states = <KeyCheckResult>[];
    final result = await checker(FakeStt(const ['']), FakeTranslate(), DebugLog())
        .check(key, onProgress: states.add);
    expect(result.ok, isTrue);
    expect(result.error, isNull);
    expect(states.first.checking, isTrue,
        reason: 'индикаторы переходят в «проверяется» сразу');
  });

  test('401 — «ключ неверный», обе проверки красные', () async {
    const unauthorized =
        AuthException(statusCode: 401, message: 'Ключ неверный или отозван');
    final stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = unauthorized;
    final result = await checker(
            stt, FakeTranslate()..failWith = unauthorized, DebugLog())
        .check(key);
    expect(result.ok, isFalse);
    expect(result.translate, CheckState.failed);
    expect(result.stt, CheckState.failed);
    expect(result.error!.title, 'Ключ неверный или отозван');
    expect(result.error!.action, UserErrorAction.changeKey);
  });

  test('403 только на распознавании — нужна роль ai.speechkit-stt.user',
      () async {
    final stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = const AuthException(
          statusCode: 403, message: 'У ключа нет роли ai.speechkit-stt.user');
    final result = await checker(stt, FakeTranslate(), DebugLog()).check(key);
    expect(result.translate, CheckState.ok);
    expect(result.stt, CheckState.failed);
    expect(result.translateError, isNull);
    expect(result.sttError!.title, 'У ключа нет роли ai.speechkit-stt.user');
  });

  test('Нет сети — так и сказано', () async {
    const offline = TransientException(message: 'Нет связи с сервисом перевода');
    final stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = offline;
    final result =
        await checker(stt, FakeTranslate()..failWith = offline, DebugLog())
            .check(key);
    expect(result.error!.title, 'Нет доступа к интернету');
  });

  test('Пустой ключ в сеть не уходит', () async {
    final stt = FakeStt(const []);
    final translate = FakeTranslate();
    final result = await checker(stt, translate, DebugLog()).check('   ');
    expect(result.ok, isFalse);
    expect(result.error!.title, 'Ключ пустой');
    expect(stt.calls + translate.calls, 0);
  });

  test('Ключ не попадает в журнал, даже в тексте ошибки', () async {
    final log = DebugLog();
    final stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = const ApiException(statusCode: 400, message: 'bad $key');
    final result = await checker(stt, FakeTranslate(), log).check(' $key ');
    expect(log.asText(), isNot(contains(key)));
    expect(result.sttError!.details, isNot(contains(key)));
  });

  test('Пробный звук — полсекунды OggOpus, который ffmpeg читает', () async {
    final bytes = probeOgg;
    expect(String.fromCharCodes(bytes.take(4)), 'OggS');
    final dir = Directory.systemTemp.createTempSync('probe_ogg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/probe.ogg';
    File(path).writeAsBytesSync(bytes);
    final seconds = await testRunner.probeDuration(path);
    expect(seconds, closeTo(0.5, 0.05));
  });
}
