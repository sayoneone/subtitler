import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/diagnostics.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // installErrorLogging подменяет оба обработчика; после теста — вернуть
  // прежние, иначе следующий тест файла наслоит свои поверх этих.
  setUp(() {
    final flutter = FlutterError.onError;
    final platform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutter;
      PlatformDispatcher.instance.onError = platform;
    });
  });

  test('Ошибка интерфейса попадает в журнал, прежний обработчик тоже вызван',
      () {
    final log = DebugLog();
    final forwarded = <FlutterErrorDetails>[];
    FlutterError.onError = forwarded.add;

    installErrorLogging(log);
    FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('кнопка упала'), stack: StackTrace.empty));

    expect(log.asText(), contains('Ошибка интерфейса: Bad state: кнопка упала'));
    expect(forwarded, hasLength(1));
  });

  test('Необработанная ошибка фоновой задачи попадает в журнал, прежний '
      'обработчик вызван и решает, обработана ли она', () {
    final log = DebugLog();
    final forwarded = <Object>[];
    PlatformDispatcher.instance.onError = (error, stack) {
      forwarded.add(error);
      return true;
    };

    installErrorLogging(log);
    final handled = PlatformDispatcher.instance.onError!(
        StateError('фоновая задача упала'), StackTrace.empty);

    expect(log.asText(),
        contains('Необработанная ошибка: Bad state: фоновая задача упала'));
    expect(forwarded, hasLength(1));
    expect(handled, isTrue);
  });

  test('Без прежнего обработчика ошибка не глотается: обычный путь (печать '
      'в консоль) тоже срабатывает', () {
    final log = DebugLog();
    PlatformDispatcher.instance.onError = null;

    installErrorLogging(log);
    final handled = PlatformDispatcher.instance.onError!(
        StateError('таймер упал'), StackTrace.empty);

    expect(log.asText(), contains('Необработанная ошибка: Bad state: таймер упал'));
    expect(handled, isFalse);
  });
}
