import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/retry.dart';

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
