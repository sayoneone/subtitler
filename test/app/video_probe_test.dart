import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/video_probe.dart';

import '../support/media.dart';

void main() {
  late Directory tmp;
  late String video;
  late String silent;
  late String audio;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('video_probe_');
    video = await makeSpeechClip('${tmp.path}/clip.mp4');
    silent = await makeSilentVideo('${tmp.path}/silent.mp4');
    audio = await makeAudioOnly('${tmp.path}/voice.m4a');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Обычное видео: картинка и звук', () async {
    final probe = await probeVideo(testRunner, video);
    expect(probe.hasVideo, isTrue);
    expect(probe.hasAudio, isTrue);
  });

  test('Видео без звука — не ошибка проверки, но звука нет', () async {
    final probe = await probeVideo(testRunner, silent);
    expect(probe.hasVideo, isTrue);
    expect(probe.hasAudio, isFalse);
  });

  test('Звук без картинки — не видео', () async {
    await expectLater(
        probeVideo(testRunner, audio), throwsA(isA<NotAVideoException>()));
  });

  test('Документ с расширением .mp4 — не видео', () async {
    final fake = File('${tmp.path}/протокол.mp4')
      ..writeAsStringSync('Выдуманный текст, а вовсе не видео.');
    await expectLater(
        probeVideo(testRunner, fake.path), throwsA(isA<NotAVideoException>()));
  });

  test('Папка — не видео', () async {
    await expectLater(
      probeVideo(testRunner, tmp.path),
      throwsA(isA<NotAVideoException>()
          .having((e) => e.isDirectory, 'isDirectory', isTrue)),
    );
  });

  test('Обложка аудиофайла не считается видеодорожкой', () {
    const log = '''
Input #0, mp3, from 'cover.mp3':
  Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, mono, fltp, 64 kb/s
  Stream #0:1: Video: mjpeg (Baseline), yuvj420p, 64x64, 90k tbr (attached pic)
Stream mapping:
  Stream #0:1 -> #0:0 (mjpeg (native) -> wrapped_avframe (native))
Output #0, null, to 'pipe:':
  Stream #0:0: Video: wrapped_avframe, 64x64 (attached pic)
''';
    final probe = parseStreams(log);
    expect(probe.hasVideo, isFalse);
    expect(probe.hasAudio, isTrue);
  });
}
