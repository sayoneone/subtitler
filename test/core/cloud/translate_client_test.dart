import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/translate_client.dart';

void main() {
  test('Полный код локали превращается в короткий код переводчика', () {
    expect(toTranslateCode('tr-TR'), 'tr');
    expect(toTranslateCode('uz-UZ'), 'uz',
        reason: 'uz — латиница, именно её отдаёт распознавание; '
            'кириллический узбекский в переводчике зовётся uzbcyr');
    expect(() => toTranslateCode('xx-XX'), throwsA(isA<ArgumentError>()));
  });

  test('Батчи режутся по сумме длин, а не по числу строк', () {
    final texts = [
      'a' * 6000,
      'b' * 5000,
      'c' * 100,
    ];
    final batches = splitIntoBatches(texts);
    expect(batches.length, 2);
    expect(batches[0].length, 1, reason: '6000 + 5000 > 10000');
    expect(batches[1].length, 2);
    for (final batch in batches) {
      expect(batch.fold<int>(0, (sum, t) => sum + t.length),
          lessThanOrEqualTo(kTranslateBatchCharLimit));
    }
  });

  group('сетевые', () {
    late HttpServer server;
    late String baseUrl;
    late List<Map<String, dynamic>> bodies;
    late List<HttpRequest> received;
    int status = 200;

    setUp(() async {
      bodies = [];
      received = [];
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        received.add(request);
        final raw = await utf8.decoder.bind(request).join();
        if (raw.isNotEmpty) bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        request.response.statusCode = status;
        if (status == 200) {
          final texts = (bodies.last['texts'] as List).cast<String>();
          request.response.write(jsonEncode({
            'translations': [for (final t in texts) {'text': 'RU:$t'}],
          }));
        } else {
          request.response.write('error');
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    TranslateClient client() =>
        TranslateClient(dio: Dio(), apiKey: 'TEST-KEY', baseUrl: baseUrl);

    test('Тело запроса содержит короткие коды и не содержит folderId', () async {
      await client().translate(texts: ['merhaba'], sourceLang: 'tr-TR');
      expect(bodies.single['targetLanguageCode'], 'ru');
      expect(bodies.single['sourceLanguageCode'], 'tr');
      expect(bodies.single.containsKey('folderId'), isFalse);
      expect(received.single.headers.value('Authorization'), 'Api-Key TEST-KEY');
    });

    test('Переводы возвращаются в исходном порядке', () async {
      final result = await client()
          .translate(texts: ['bir', 'iki', 'üç'], sourceLang: 'tr-TR');
      expect(result, ['RU:bir', 'RU:iki', 'RU:üç']);
    });

    test('Длинный список уходит несколькими запросами и склеивается', () async {
      final texts = ['x' * 7000, 'y' * 7000];
      final result = await client().translate(texts: texts, sourceLang: 'uz-UZ');
      expect(received.length, 2);
      expect(result.length, 2);
      expect(result[0], startsWith('RU:x'));
      expect(result[1], startsWith('RU:y'));
    });

    test('Пустой список не ходит в сеть', () async {
      expect(await client().translate(texts: const [], sourceLang: 'tr-TR'),
          isEmpty);
      expect(received, isEmpty);
    });

    test('403 даёт AuthException с упоминанием роли перевода', () async {
      status = 403;
      try {
        await client().translate(texts: ['a'], sourceLang: 'tr-TR');
        fail('должно было бросить');
      } on AuthException catch (e) {
        expect(e.message, contains('ai.translate.user'));
        expect(e.toString(), isNot(contains('TEST-KEY')));
      }
    });

    test('503 даёт TransientException', () async {
      status = 503;
      await expectLater(
        client().translate(texts: ['a'], sourceLang: 'tr-TR'),
        throwsA(isA<TransientException>()),
      );
    });
  });
}
