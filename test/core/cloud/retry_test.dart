import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/retry.dart';
import 'package:subtitler/core/pipeline/errors.dart';

void main() {
  test('Успех с первой попытки не порождает пауз', () async {
    final slept = <Duration>[];
    final value = await withRetry(() async => 'ok', sleep: (d) async => slept.add(d));
    expect(value, 'ok');
    expect(slept, isEmpty);
  });

  test('Временная ошибка повторяется с паузами 1, 4, 10 секунд', () async {
    final slept = <Duration>[];
    var attempts = 0;
    final value = await withRetry(
      () async {
        attempts++;
        if (attempts < 3) throw TransientException(statusCode: 429, message: 'busy');
        return 'ok';
      },
      sleep: (d) async => slept.add(d),
    );
    expect(value, 'ok');
    expect(attempts, 3);
    expect(slept, [const Duration(seconds: 1), const Duration(seconds: 4)]);
  });

  test('Когда паузы исчерпаны, исключение пробрасывается наружу', () async {
    var attempts = 0;
    final slept = <Duration>[];
    await expectLater(
      withRetry(
        () async {
          attempts++;
          throw TransientException(statusCode: 500, message: 'boom');
        },
        sleep: (d) async => slept.add(d),
      ),
      throwsA(isA<TransientException>()),
    );
    expect(attempts, 4, reason: 'первая попытка плюс три повтора');
    expect(slept, kRetryDelays,
        reason: 'использованы все объявленные паузы, включая последнюю');
  });

  group('«Отмена»', () {
    test('в паузе перед повтором — новых попыток нет, пауза обрывается',
        () async {
      var attempts = 0;
      var cancelled = false;
      final slept = <Duration>[];
      await expectLater(
        withRetry(
          () async {
            attempts++;
            throw const TransientException(statusCode: 429, message: 'busy');
          },
          sleep: (d) async {
            slept.add(d);
            cancelled = true; // нажали, пока ждём
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PipelineCancelledException>()),
      );
      expect(attempts, 1);
      expect(slept, [kCancelCheckInterval],
          reason: 'после нажатия паузу не досыпаем');
    });

    test('ответ на уже отправленный запрос дожидаемся', () async {
      var cancelled = false;
      final value = await withRetry(
        () async {
          cancelled = true; // нажали, пока запрос в пути
          return 'ответ';
        },
        sleep: (_) async {},
        isCancelled: () => cancelled,
      );
      expect(value, 'ответ');
    });

    test('без отмены пауза та же: 1, 4, 10 секунд', () async {
      final slept = <Duration>[];
      await expectLater(
        withRetry<String>(
          () async =>
              throw const TransientException(statusCode: 500, message: 'boom'),
          sleep: (d) async => slept.add(d),
          isCancelled: () => false,
        ),
        throwsA(isA<TransientException>()),
      );
      final total = slept.fold(Duration.zero, (sum, d) => sum + d);
      expect(total, const Duration(seconds: 15));
    });

    test('настоящая пауза в 30 с обрывается за доли секунды', () async {
      var cancelled = false;
      Timer(const Duration(milliseconds: 100), () => cancelled = true);
      final watch = Stopwatch()..start();
      await expectLater(
        withRetry<String>(
          () async =>
              throw const TransientException(message: 'нет связи'),
          delays: const [Duration(seconds: 30)],
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PipelineCancelledException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  test('Ошибка авторизации не повторяется — прогон надо останавливать', () async {
    var attempts = 0;
    await expectLater(
      withRetry(
        () async {
          attempts++;
          throw AuthException(statusCode: 403, message: 'нет роли');
        },
        sleep: (_) async {},
      ),
      throwsA(isA<AuthException>()),
    );
    expect(attempts, 1);
  });
}
