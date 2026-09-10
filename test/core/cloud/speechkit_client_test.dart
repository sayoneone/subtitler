import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  late List<HttpRequest> received;
  int Function() nextStatus = () => 200;
  String Function() nextBody = () => '{"result":"tam 12 saat var"}';

  setUp(() async {
    received = [];
    // Сбрасываем ответ сервера: иначе тест, выставивший 500, ломал бы
    // все следующие, и результат зависел бы от порядка запуска.
    nextStatus = () => 200;
    nextBody = () => '{"result":"tam 12 saat var"}';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      received.add(request);
      await request.drain<void>();
      request.response.statusCode = nextStatus();
      request.response.write(nextBody());
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  SpeechKitClient client() => SpeechKitClient(
        dio: Dio(),
        apiKey: 'TEST-KEY',
        baseUrl: baseUrl,
      );

  test('Запрос содержит нужные параметры и заголовок с ключом', () async {
    await client().recognize(oggBytes: utf8.encode('ogg'), lang: 'tr-TR');
    final request = received.single;
    expect(request.method, 'POST');
    expect(request.uri.queryParameters['lang'], 'tr-TR');
    expect(request.uri.queryParameters['format'], 'oggopus');
    expect(request.uri.queryParameters['topic'], 'general');
    expect(request.uri.queryParameters.containsKey('folderId'), isFalse,
        reason: 'с ключом сервисного аккаунта folderId запрещён');
    expect(request.uri.queryParameters.containsKey('sampleRateHertz'), isFalse);
    expect(request.headers.value('Authorization'), 'Api-Key TEST-KEY');
  });

  test('Успешный ответ отдаёт распознанный текст', () async {
    final text = await client().recognize(
        oggBytes: utf8.encode('ogg'), lang: 'tr-TR');
    expect(text, 'tam 12 saat var');
  });

  test('Отсутствие речи — пустая строка, а не ошибка', () async {
    nextBody = () => '{"result":""}';
    expect(await client().recognize(oggBytes: utf8.encode('o'), lang: 'uz-UZ'), '');
  });

  test('401 и 403 дают AuthException', () async {
    nextStatus = () => 401;
    nextBody = () => '{"error":"unauthorized"}';
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<AuthException>()),
    );
    nextStatus = () => 403;
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<AuthException>()),
    );
  });

  test('429 и 500 дают TransientException', () async {
    nextStatus = () => 429;
    nextBody = () => 'too many requests';
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<TransientException>()),
    );
    nextStatus = () => 500;
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR'),
      throwsA(isA<TransientException>()),
    );
  });

  test('Неизвестный язык отклоняется до похода в сеть', () async {
    await expectLater(
      client().recognize(oggBytes: utf8.encode('o'), lang: 'xx-XX'),
      throwsA(isA<ArgumentError>()),
    );
    expect(received, isEmpty);
  });

  test('Поддерживаются все языки таблицы, не только турецкий с узбекским',
      () async {
    expect(kSupportedSttLangs, containsAll(['ru-RU', 'kk-KZ', 'de-DE']));
    expect(kSupportedSttLangs.length, 16);
    await client().recognize(oggBytes: utf8.encode('ogg'), lang: 'ru-RU');
    expect(received.last.uri.queryParameters['lang'], 'ru-RU');
  });

  test('Сообщение об ошибке не содержит ключ', () async {
    nextStatus = () => 403;
    nextBody = () => 'forbidden';
    try {
      await client().recognize(oggBytes: utf8.encode('o'), lang: 'tr-TR');
      fail('должно было бросить');
    } on ApiException catch (e) {
      expect(e.toString(), isNot(contains('TEST-KEY')));
    }
  });
}
