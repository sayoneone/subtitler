import 'package:flutter/foundation.dart';

import '../core/logging.dart';

/// Ошибки, которые иначе ушли бы только в консоль, пишутся в журнал: у
/// следователя консоли нет, а журнал он может прислать разработчику.
///
/// Прежние обработчики не заменяются, а вызываются после записи: в
/// отладке Flutter по-прежнему печатает ошибку и показывает красный экран.
void installErrorLogging(DebugLog log) {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    log.error('Ошибка интерфейса: ${details.exceptionAsString()}'
        '${details.stack == null ? '' : '\n${details.stack}'}');
    previousFlutter?.call(details);
  };

  final platform = PlatformDispatcher.instance;
  final previousPlatform = platform.onError;
  platform.onError = (error, stack) {
    log.error('Необработанная ошибка: $error\n$stack');
    // false — пусть сработает и обычный путь (печать в stderr).
    return previousPlatform?.call(error, stack) ?? false;
  };
}
