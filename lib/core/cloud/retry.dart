import '../pipeline/errors.dart';
import 'api_errors.dart';

/// Паузы перед каждым повтором. Первая попытка пауз не требует, поэтому
/// всего попыток на одну больше, чем задержек: try → 1 с → try → 4 с → try
/// → 10 с → try.
const List<Duration> kRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 4),
  Duration(seconds: 10),
];

/// Как часто пауза перед повтором смотрит, не нажата ли «Отмена»: дольше
/// этого человек после нажатия паузу не ждёт.
const Duration kCancelCheckInterval = Duration(milliseconds: 250);

/// Повторяет [body] при временных ошибках. [sleep] подменяется в тестах,
/// чтобы не ждать по-настоящему.
///
/// [isCancelled] — «Отмена». После неё новых попыток нет, а пауза перед
/// повтором обрывается: [PipelineCancelledException]. Запрос, который уже
/// ушёл, не прерывается — его ответ дожидаемся: сервис мог его уже
/// выполнить, и тогда за него заплачено.
Future<T> withRetry<T>(
  Future<T> Function() body, {
  List<Duration> delays = kRetryDelays,
  Future<void> Function(Duration)? sleep,
  bool Function()? isCancelled,
}) async {
  final wait = sleep ?? Future<void>.delayed;

  for (var attempt = 1; ; attempt++) {
    throwIfCancelled(isCancelled);
    try {
      return await body();
    } on TransientException {
      // Паузы кончились — значит израсходованы все попытки.
      if (attempt > delays.length) rethrow;
      await _pause(delays[attempt - 1], wait, isCancelled);
    }
  }
}

/// Пауза [delay], которую «Отмена» обрывает. Отменить уже начатое
/// ожидание нельзя, поэтому оно идёт короткими отрезками, и между ними
/// проверяется флаг.
Future<void> _pause(
  Duration delay,
  Future<void> Function(Duration) wait,
  bool Function()? cancelled,
) async {
  if (cancelled == null) return wait(delay);
  var left = delay;
  while (left > Duration.zero && !cancelled()) {
    final step = left < kCancelCheckInterval ? left : kCancelCheckInterval;
    await wait(step);
    left -= step;
  }
}
