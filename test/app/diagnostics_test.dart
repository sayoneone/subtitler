import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/diagnostics.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  test('Ошибка интерфейса попадает в журнал, прежний обработчик тоже вызван',
      () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final log = DebugLog();
    final previous = FlutterError.onError;
    final forwarded = <FlutterErrorDetails>[];
    FlutterError.onError = forwarded.add;
    addTearDown(() => FlutterError.onError = previous);

    installErrorLogging(log);
    FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('кнопка упала'), stack: StackTrace.empty));

    expect(log.asText(), contains('Ошибка интерфейса: Bad state: кнопка упала'));
    expect(forwarded, hasLength(1));
  });
}
