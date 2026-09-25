import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../core/logging.dart';
import 'preview_player.dart';

/// Предпросмотр на Android и macOS через официальный video_player
/// (ExoPlayer / AVFoundation). Нативных библиотек в сборку не добавляет.
class VideoPlayerPreviewPlayer implements PreviewPlayer {
  VideoPlayerPreviewPlayer({DebugLog? log}) : _log = log ?? DebugLog.instance;

  final DebugLog _log;

  /// Контроллер меняется при каждом [open]: у video_player один контроллер —
  /// один файл. [view] слушает этот нотификатор, чтобы сразу показать новый.
  final _controller = ValueNotifier<VideoPlayerController?>(null);

  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);
  final _playing = ValueNotifier(false);
  final _videoSize = ValueNotifier<Size?>(null);
  final _error = ValueNotifier<String?>(null);
  bool _disposed = false;

  @override
  ValueListenable<Duration> get position => _position;
  @override
  ValueListenable<Duration> get duration => _duration;
  @override
  ValueListenable<bool> get playing => _playing;
  @override
  ValueListenable<Size?> get videoSize => _videoSize;
  @override
  ValueListenable<String?> get error => _error;

  @override
  Future<void> open(String path) async {
    if (_disposed) return;
    await _release();
    _error.value = null;
    _videoSize.value = null;
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
    _playing.value = false;

    final c = VideoPlayerController.file(File(path));
    _controller.value = c;
    c.addListener(_sync);
    try {
      await c.initialize();
    } catch (e) {
      // Контроллер мог смениться, пока шла инициализация: ошибка старого
      // файла к новому отношения не имеет.
      if (_controller.value == c) _fail('Не открылся файл $path: $e');
      return;
    }
    if (_disposed || _controller.value != c) return;
    _log.info('Предпросмотр: открыт $path');
    _sync();
  }

  void _sync() {
    final c = _controller.value;
    if (c == null || _disposed) return;
    final v = c.value;
    if (v.hasError) {
      // До готовности ошибка значит «файл не показать»; после — это сбой
      // посреди ролика, прятать уже показанное видео незачем.
      if (!v.isInitialized) {
        _fail(v.errorDescription ?? 'неизвестная ошибка');
      } else {
        _log.warn('Предпросмотр: ${v.errorDescription}');
      }
      return;
    }
    if (!v.isInitialized) return;
    _position.value = v.position;
    _duration.value = v.duration;
    _playing.value = v.isPlaying;
    // size уже с учётом поворота из метаданных.
    final s = v.size;
    _videoSize.value = s.width > 0 && s.height > 0 ? s : null;
  }

  void _fail(String reason) {
    if (_disposed || _error.value != null) return;
    _error.value = reason;
    _log.error('Предпросмотр: $reason');
  }

  bool get _ready {
    final c = _controller.value;
    return c != null && c.value.isInitialized && _error.value == null;
  }

  @override
  Future<void> play() async {
    // С конца ролика video_player сам перематывает на начало.
    if (_ready) await _controller.value!.play();
  }

  @override
  Future<void> pause() async {
    if (_ready) await _controller.value!.pause();
  }

  @override
  Future<void> toggle() => _playing.value ? pause() : play();

  @override
  Future<void> seek(Duration to) async {
    if (!_ready) return;
    final d = _duration.value;
    final target = to < Duration.zero
        ? Duration.zero
        : (d > Duration.zero && to > d ? d : to);
    // Сразу, не дожидаясь плеера: оверлей должен показать выбранную реплику
    // в тот же кадр.
    _position.value = target;
    await _controller.value!.seekTo(target);
  }

  @override
  Widget view() => ValueListenableBuilder<VideoPlayerController?>(
        valueListenable: _controller,
        builder: (context, c, _) => ColoredBox(
          color: const Color(0xFF000000),
          child: c == null ? const SizedBox.expand() : VideoPlayer(c),
        ),
      );

  Future<void> _release() async {
    final old = _controller.value;
    if (old == null) return;
    old.removeListener(_sync);
    _controller.value = null;
    await old.dispose();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _release();
    for (final n in [
      _controller,
      _position,
      _duration,
      _playing,
      _videoSize,
      _error,
    ]) {
      n.dispose();
    }
  }
}
