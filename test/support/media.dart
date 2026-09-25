/// Синтетические ролики для тестов: делает их тот же ffmpeg, которым
/// пользуется приложение (переменная SUBTITLER_FFMPEG).
library;

import 'dart:io';

import 'package:subtitler/core/ffmpeg/process_runner.dart';

final ProcessFfmpegRunner testRunner = ProcessFfmpegRunner.fromEnvironment();

Future<void> _make(List<String> args) async {
  final made = await testRunner.run(
      ['-y', '-hide_banner', '-loglevel', 'error', ...args]);
  if (!made.ok) throw StateError('Не удалось сделать ролик: ${made.log}');
}

/// 15 с, звук идёт первые 3 с каждой пятисекундки: три «реплики»
/// с паузами между ними.
Future<String> makeSpeechClip(String path) async {
  await _make([
    '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=15',
    '-f', 'lavfi',
    '-i', 'aevalsrc=0.5*sin(440*2*PI*t)*between(mod(t\\,5)\\,0\\,3):d=15',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
    path,
  ]);
  return path;
}

/// 15 с, реплики разной длины — 4 с (1), 2 с (2), 3,5 с (3): выбор проб
/// для определения языка однозначен (реплики 1 и 3).
Future<String> makeProbeClip(String path) async {
  await _make([
    '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=15',
    '-f', 'lavfi',
    '-i', 'aevalsrc=0.5*sin(440*2*PI*t)*(between(t\\,0\\,4)'
        '+between(t\\,6\\,8)+between(t\\,10\\,13.5)):d=15',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
    path,
  ]);
  return path;
}

/// Видео без звуковой дорожки.
Future<String> makeSilentVideo(String path) async {
  await _make([
    '-f', 'lavfi', '-i', 'color=c=black:s=320x240:d=3',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
    path,
  ]);
  return path;
}

/// Звук без картинки.
Future<String> makeAudioOnly(String path) async {
  await _make(['-f', 'lavfi', '-i', 'sine=d=2', path]);
  return path;
}

/// Фильтр `subtitles` есть только в сборках ffmpeg с libass. Без него
/// вшивание на этой машине не проверить — такие тесты честно пропускаются.
String? burnSkipReason() {
  final result =
      Process.runSync(testRunner.ffmpegPath, ['-hide_banner', '-filters']);
  if (RegExp(r'\bsubtitles\b').hasMatch(result.stdout as String)) return null;
  return 'ffmpeg собран без libass — вшивание на этой машине непроверяемо '
      '(укажите сборку с libass через $kFfmpegPathEnv)';
}
