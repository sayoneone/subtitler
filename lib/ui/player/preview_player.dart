import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path/path.dart' as p;

import '../../core/logging.dart';
import 'media_kit_preview_player.dart';
import 'video_player_preview_player.dart';

/// Плеер для предпросмотра: показывает кадр и отдаёт позицию, чтобы Flutter
/// мог нарисовать поверх кадра субтитры (см. `SubtitleOverlay`).
///
/// Интерфейс нарочно маленький. На Windows под ним media_kit, на Android и
/// macOS — video_player, и всё различие между ними живёт в двух файлах
/// реализации. Если одну из библиотек придётся заменить, остальное
/// приложение этого не заметит.
abstract interface class PreviewPlayer {
  /// Текущая позиция воспроизведения.
  ValueListenable<Duration> get position;

  /// Длительность открытого файла; [Duration.zero], пока файл не разобран.
  ValueListenable<Duration> get duration;

  /// Идёт ли воспроизведение прямо сейчас.
  ValueListenable<bool> get playing;

  /// Размер кадра с учётом поворота. `null`, пока кадр не декодирован:
  /// до этого пропорции окна неизвестны.
  ValueListenable<Size?> get videoSize;

  /// Почему файл не удалось показать; `null`, если всё в порядке.
  ///
  /// Текст технический — для журнала и «Технических деталей». Человеку
  /// интерфейс показывает свою фразу: предпросмотр не мешает проверить и
  /// сохранить субтитры.
  ValueListenable<String?> get error;

  /// Открывает файл и встаёт на паузу в начале. Сам не запускает:
  /// человек пришёл читать субтитры, а не слушать ролик с порога.
  ///
  /// Не бросает исключений: всё, что пошло не так, оказывается в [error].
  Future<void> open(String path);

  Future<void> play();

  Future<void> pause();

  /// Пауза, если играет; иначе воспроизведение. С конца ролика — с начала.
  Future<void> toggle();

  Future<void> seek(Duration to);

  /// Только кадр: без кнопок и без собственных субтитров плеера. Встроенные
  /// дорожки субтитров из файла здесь только мешали бы нашим.
  Widget view();

  /// Освобождает декодер и текстуру. После вызова объект не используется.
  Future<void> dispose();
}

/// Что помешало подготовить плеер при запуске; `null` — всё готово.
String? _initFailure;

/// Готовит нативную часть плееров. Вызывается один раз из `main()` после
/// `WidgetsFlutterBinding.ensureInitialized()`.
///
/// libmpv нужен только на Windows: на Android и macOS работает video_player,
/// а инициализация media_kit там упала бы — его библиотек в сборке нет.
///
/// Никогда не бросает. Без предпросмотра приложение по-прежнему делает
/// главное — субтитры, поэтому сбой здесь только записывается в журнал, а
/// каждый созданный плеер сразу сообщит об ошибке через [PreviewPlayer.error].
/// (Отсутствие самой libmpv-2.dll сюда не доходит: её статически импортирует
/// плагин media_kit_video, и без неё exe не стартует. Проверяет CI.)
void initPreviewPlayers({DebugLog? log}) {
  if (!Platform.isWindows) return;
  final journal = log ?? DebugLog.instance;
  // Библиотеку берём по полному пути рядом с exe. Без пути media_kit сначала
  // смотрит переменную окружения LIBMPV_LIBRARY_PATH — то есть чужая
  // переменная могла бы подсунуть приложению постороннюю DLL.
  final bundled =
      p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll');
  try {
    MediaKit.ensureInitialized(
        libmpv: File(bundled).existsSync() ? bundled : null);
    _initFailure = null;
  } catch (e) {
    _initFailure = 'Не загрузилась библиотека плеера (libmpv-2.dll): $e';
    journal.error('Предпросмотр недоступен. $_initFailure');
  }
}

/// Плеер для текущей платформы: Windows — media_kit, остальные — video_player.
PreviewPlayer createPreviewPlayer({DebugLog? log}) {
  final journal = log ?? DebugLog.instance;
  if (!Platform.isWindows) return VideoPlayerPreviewPlayer(log: journal);
  final failure = _initFailure;
  if (failure != null) return UnavailablePreviewPlayer(failure);
  return MediaKitPreviewPlayer(log: journal);
}

/// Заглушка на случай, когда нативный плеер не поднялся: сразу сообщает
/// ошибку, и интерфейс показывает надпись вместо кадра.
class UnavailablePreviewPlayer implements PreviewPlayer {
  UnavailablePreviewPlayer(String reason) : _error = ValueNotifier(reason);

  final ValueNotifier<String?> _error;
  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);
  final _playing = ValueNotifier(false);
  final _videoSize = ValueNotifier<Size?>(null);

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
  Future<void> open(String path) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> toggle() async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Widget view() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    for (final n in [_error, _position, _duration, _playing, _videoSize]) {
      n.dispose();
    }
  }
}
