import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/logging.dart';
import 'preview_player.dart';

/// Предпросмотр на Windows через media_kit (libmpv + ANGLE рядом с exe).
///
/// Выбран потому, что не опирается ни на Media Foundation, ни на кодеки ОС:
/// на N/LTSC-редакциях служебных ПК их нет, а libmpv везёт свой ffmpeg.
class MediaKitPreviewPlayer implements PreviewPlayer {
  MediaKitPreviewPlayer({DebugLog? log}) : _log = log ?? DebugLog.instance {
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'Subtitler',
        // Только локальные файлы. По умолчанию разрешены ещё http, tcp, udp и
        // прочие: контейнер вроде HLS-плейлиста мог бы заставить плеер выйти
        // в сеть. Служебному ПК это ни к чему.
        protocolWhitelist: ['file'],
      ),
    );
    _video = VideoController(
      _player,
      // Программное декодирование. Для роликов из мессенджеров (480p) это
      // дёшево, зато не зависит от видеодрайверов служебных ПК и от RDP.
      configuration: const VideoControllerConfiguration(hwdec: 'no'),
    );
    _subscriptions.addAll([
      _player.stream.position.listen((v) => _position.value = v),
      _player.stream.duration.listen((v) => _duration.value = v),
      _player.stream.playing.listen((v) => _playing.value = v),
      _player.stream.width.listen((v) {
        _width = v;
        _updateSize();
      }),
      _player.stream.height.listen((v) {
        _height = v;
        _updateSize();
      }),
      _player.stream.log.listen(_onLog),
    ]);
    _video.platform.future.then((_) {}, onError: (Object e) {
      // Без видеовыхода (не поднялся ANGLE) кадра не будет ни у этого
      // файла, ни у следующего.
      _outputFailure = 'Не создан видеовыход: $e';
      _fail(_outputFailure!);
    });
  }

  /// Столько ждём первого кадра, прежде чем признать, что показать файл
  /// не получится. С запасом: на старом ПК первый кадр 1080p без аппаратного
  /// декодирования — это доли секунды, а не десятки.
  static const Duration firstFrameTimeout = Duration(seconds: 20);

  /// Источники ошибок mpv, которые до первого кадра означают «файл не
  /// открылся»: нет файла, не распознан формат, не открылся декодер. Ошибки
  /// отдельных кадров или звука (`ffmpeg/video`, `ad`) показу не мешают.
  static const Set<String> _fatalPrefixes = {
    'file',
    'stream',
    'cplayer',
    'demux',
    'lavf',
    'vd',
  };

  final DebugLog _log;
  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);
  final _playing = ValueNotifier(false);
  final _videoSize = ValueNotifier<Size?>(null);
  final _error = ValueNotifier<String?>(null);

  int? _width;
  int? _height;
  Timer? _firstFrameTimer;
  String? _outputFailure;
  bool _mpvTuned = false;
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

  /// Завершается, когда первый кадр дошёл до текстуры Flutter. Нужен
  /// проверке на живом Windows (integration_test): одних размеров кадра
  /// мало — они приходят от декодера и не доказывают, что работает ANGLE.
  @visibleForTesting
  Future<void> get firstFrameRendered => _video.waitUntilFirstFrameRendered;

  @override
  Future<void> open(String path) async {
    if (_disposed) return;
    _firstFrameTimer?.cancel();
    _error.value = _outputFailure;
    if (_outputFailure != null) return;
    _videoSize.value = null;
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
    _width = null;
    _height = null;
    try {
      await _tuneMpv();
      await _player.open(Media(path), play: false);
      // Встроенные дорожки субтитров (в mkv они бывают) не показываем:
      // в кадре должны быть только наши реплики.
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } catch (e) {
      _fail('Не открылся файл $path: $e');
      return;
    }
    _log.info('Предпросмотр: открыт $path');
    _firstFrameTimer = Timer(firstFrameTimeout, () {
      if (_videoSize.value == null) {
        _fail('За ${firstFrameTimeout.inSeconds} с не декодирован ни один '
            'кадр: $path');
      }
    });
  }

  /// Настройки mpv, которых нет в конфигурации media_kit. Ставятся один раз:
  /// это опции, они действуют на все последующие файлы.
  Future<void> _tuneMpv() async {
    if (_mpvTuned) return;
    final native = _player.platform;
    if (native is! NativePlayer) return;
    // Не подхватывать субтитры-соседи. При просмотре готового `<имя>_ru.mp4`
    // рядом лежит `<имя>_ru.srt` — точное совпадение имени, и mpv загрузил бы
    // его отдельной дорожкой.
    await native.setProperty('sub-auto', 'no');
    await native.setProperty('sid', 'no');
    // media_kit включает дисковый кеш демуксера. Для локального файла он не
    // нужен, а кадры служебного видео во временных файлах — лишний след.
    await native.setProperty('cache-on-disk', 'no');
    _mpvTuned = true;
  }

  void _updateSize() {
    final w = _width;
    final h = _height;
    if (w == null || h == null || w <= 0 || h <= 0) {
      _videoSize.value = null;
      return;
    }
    final size = Size(w.toDouble(), h.toDouble());
    if (_videoSize.value != size) {
      _videoSize.value = size;
      _firstFrameTimer?.cancel();
      _log.debug('Предпросмотр: кадр ${w}x$h');
    }
  }

  void _onLog(PlayerLog entry) {
    if (entry.level != 'error' && entry.level != 'fatal') return;
    final message = '[${entry.prefix}] ${entry.text}';
    if (_videoSize.value == null && _fatalPrefixes.contains(entry.prefix)) {
      _fail(message);
    } else {
      // Сбой отдельного кадра не повод прятать видео — только в журнал.
      _log.warn('Предпросмотр: $message');
    }
  }

  void _fail(String reason) {
    if (_disposed || _error.value != null) return;
    _firstFrameTimer?.cancel();
    _error.value = reason;
    _log.error('Предпросмотр: $reason');
  }

  @override
  Future<void> play() async {
    if (_disposed || _error.value != null) return;
    // keep-open=yes: в конце ролик стоит на последнем кадре, и play() без
    // перемотки ничего не сделал бы.
    final d = _duration.value;
    if (d > Duration.zero && _position.value >= d - _endTolerance) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
  }

  /// Позиция на последнем кадре чуть меньше длительности — на длину кадра.
  static const Duration _endTolerance = Duration(milliseconds: 100);

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> toggle() => _playing.value ? pause() : play();

  @override
  Future<void> seek(Duration to) async {
    if (_disposed || _error.value != null) return;
    final d = _duration.value;
    final target = to < Duration.zero
        ? Duration.zero
        : (d > Duration.zero && to > d ? d : to);
    // Сразу, не дожидаясь mpv: оверлей субтитров должен показать реплику,
    // на которую человек щёлкнул, в тот же кадр.
    _position.value = target;
    await _player.seek(target);
  }

  @override
  Widget view() => Video(
        controller: _video,
        controls: NoVideoControls,
        fill: const Color(0xFF000000),
        subtitleViewConfiguration:
            const SubtitleViewConfiguration(visible: false),
      );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _firstFrameTimer?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _player.dispose();
    for (final n in [_position, _duration, _playing, _videoSize, _error]) {
      n.dispose();
    }
  }
}
