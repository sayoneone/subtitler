import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:subtitler/ui/player/preview_player.dart';

/// Плеер без декодера для виджет-тестов: состояние выставляет сам тест,
/// а вызовы записываются, чтобы их можно было проверить.
///
/// Настоящие плееры в `flutter test` не работают: libmpv и ExoPlayer — это
/// нативный код, которого в тестовой среде нет.
class FakePreviewPlayer implements PreviewPlayer {
  final positionValue = ValueNotifier(Duration.zero);
  final durationValue = ValueNotifier(Duration.zero);
  final playingValue = ValueNotifier(false);
  final videoSizeValue = ValueNotifier<Size?>(null);
  final errorValue = ValueNotifier<String?>(null);

  final List<String> opened = [];
  final List<Duration> seeks = [];
  int toggleCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  bool disposed = false;

  /// Ключ кадра, который отдаёт [view]: по нему тест находит «видео».
  static const frameKey = ValueKey('fake-frame');

  /// Как будто файл открылся: известны длительность и размер кадра.
  void loaded({
    Duration duration = const Duration(minutes: 1),
    Size size = const Size(848, 480),
  }) {
    durationValue.value = duration;
    videoSizeValue.value = size;
  }

  @override
  ValueListenable<Duration> get position => positionValue;
  @override
  ValueListenable<Duration> get duration => durationValue;
  @override
  ValueListenable<bool> get playing => playingValue;
  @override
  ValueListenable<Size?> get videoSize => videoSizeValue;
  @override
  ValueListenable<String?> get error => errorValue;

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  Future<void> play() async {
    playCalls++;
    playingValue.value = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playingValue.value = false;
  }

  @override
  Future<void> toggle() async {
    toggleCalls++;
    playingValue.value = !playingValue.value;
  }

  @override
  Future<void> seek(Duration to) async {
    seeks.add(to);
    positionValue.value = to;
  }

  @override
  Widget view() => const ColoredBox(key: frameKey, color: Color(0xFF000000));

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
