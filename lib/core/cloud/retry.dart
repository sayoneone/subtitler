import 'api_errors.dart';

/// Паузы перед каждым повтором. Первая попытка пауз не требует, поэтому
/// всего попыток на одну больше, чем задержек: try → 1 с → try → 4 с → try
/// → 10 с → try.
const List<Duration> kRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 4),
  Duration(seconds: 10),
];

/// Повторяет [body] при временных ошибках. [sleep] подменяется в тестах,
/// чтобы не ждать по-настоящему.
Future<T> withRetry<T>(
  Future<T> Function() body, {
  List<Duration> delays = kRetryDelays,
  Future<void> Function(Duration)? sleep,
}) async {
  final wait = sleep ?? Future<void>.delayed;

  for (var attempt = 1; ; attempt++) {
    try {
      return await body();
    } on TransientException {
      // Паузы кончились — значит израсходованы все попытки.
      if (attempt > delays.length) rethrow;
      await wait(delays[attempt - 1]);
    }
  }
}
