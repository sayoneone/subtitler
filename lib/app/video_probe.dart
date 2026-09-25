import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ffmpeg/ffmpeg_runner.dart';

/// Файл не годится как видео: это папка, документ, звук без картинки
/// или повреждённый файл. Проверяется сразу при выборе файла, чтобы
/// человек получил короткое сообщение на главном экране, а не ошибку
/// посреди обработки.
class NotAVideoException implements Exception {
  final String path;

  /// Для журнала и «Технических деталей»: что именно не так.
  final String reason;

  /// Перетащили папку, а не файл.
  final bool isDirectory;

  const NotAVideoException(this.path, this.reason, {this.isDirectory = false});

  String get fileName => p.basename(path);

  @override
  String toString() => 'Не видео: $path ($reason)';
}

/// Что известно о файле после быстрой проверки.
class VideoProbe {
  final bool hasVideo;
  final bool hasAudio;

  const VideoProbe({required this.hasVideo, required this.hasAudio});
}

/// ffmpeg пишет это, когда не может разобрать файл: документ с расширением
/// .mp4, недокачанный ролик. Проверено на ffmpeg 9.0.1.
const String kInvalidDataMarker = 'Invalid data found when processing input';

/// Разбирает вывод `ffmpeg -i`: какие дорожки есть во ВХОДНОМ файле.
///
/// Обложка у аудиофайла (mp3 с картинкой) выглядит как видеодорожка с
/// пометкой `(attached pic)` — это не видео. Строки после «Stream mapping»
/// и «Output #0» описывают уже выход, их не смотрим.
VideoProbe parseStreams(String ffmpegLog) {
  var input = ffmpegLog;
  for (final marker in ['Stream mapping:', 'Output #0']) {
    final at = input.indexOf(marker);
    if (at >= 0) input = input.substring(0, at);
  }
  var hasVideo = false;
  var hasAudio = false;
  final stream = RegExp(r'Stream #\d+:\d+[^:]*: (Video|Audio): (.*)');
  for (final match in stream.allMatches(input)) {
    if (match.group(1) == 'Audio') {
      hasAudio = true;
    } else if (!match.group(2)!.contains('(attached pic)')) {
      hasVideo = true;
    }
  }
  return VideoProbe(hasVideo: hasVideo, hasAudio: hasAudio);
}

/// Быстро проверяет, что по [path] лежит видео, которое ffmpeg прочтёт.
///
/// `-t 0 -f null -` — прочитать заголовки и ничего не кодировать: ffmpeg
/// выходит с кодом 0 и печатает список дорожек. Голый `ffmpeg -i` для
/// этого не годится — он всегда завершается кодом 1 («не указан выходной
/// файл»), и в журнале каждое открытие видео выглядело бы как ошибка.
///
/// Нет видеодорожки или файл не читается — [NotAVideoException]. Нет
/// звука — не ошибка здесь: [VideoProbe.hasAudio] решает вызывающий.
Future<VideoProbe> probeVideo(FfmpegRunner runner, String path) async {
  if (FileSystemEntity.isDirectorySync(path)) {
    throw NotAVideoException(path, 'это папка', isDirectory: true);
  }
  if (!File(path).existsSync()) {
    throw NotAVideoException(path, 'файл не найден');
  }
  final result = await runner.run(
      ['-hide_banner', '-i', path, '-t', '0', '-f', 'null', '-']);
  if (!result.ok) {
    if (result.log.contains(kInvalidDataMarker)) {
      throw NotAVideoException(path, 'ffmpeg не распознал формат');
    }
    throw StateError('Не удалось прочитать видео: ${result.log}');
  }
  final probe = parseStreams(result.log);
  if (!probe.hasVideo) {
    throw NotAVideoException(path, 'в файле нет видеодорожки');
  }
  return probe;
}
