/// Журнал, который считает живые подписки на свой поток: панель журнала
/// обязана отписываться, когда её закрывают.
library;

import 'dart:async';

import 'package:subtitler/core/logging.dart';

class CountingLog extends DebugLog {
  int listeners = 0;

  @override
  Stream<LogEntry> get stream {
    StreamSubscription<LogEntry>? inner;
    late final StreamController<LogEntry> relay;
    relay = StreamController<LogEntry>(
      onListen: () {
        listeners++;
        inner = super.stream.listen(relay.add);
      },
      onCancel: () {
        listeners--;
        return inner?.cancel();
      },
    );
    return relay.stream;
  }
}
