// Живая проверка плеера предпросмотра в собранном приложении.
//
// Виджет-тесты работают с FakePreviewPlayer: libmpv, ANGLE и ExoPlayer в
// `flutter test` не запускаются. Здесь — настоящий плеер платформы на
// настоящем ролике. Запуск (нужен ffmpeg, как и для остальных тестов):
//
//   $env:SUBTITLER_FFMPEG = '…\ffmpeg.exe'
//   flutter test integration_test -d windows
//
// CI этот тест не запускает, поэтому прогон вручную обязателен перед
// тегом релиза и после обновления Flutter или media_kit (README,
// спецификация §14): например, с переходом Windows на Impeller текстура
// media_kit давала чёрный кадр, и никакой другой тест этого не заметит.
// Без SUBTITLER_FFMPEG оба теста пропускаются молча.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/player/media_kit_preview_player.dart';
import 'package:subtitler/ui/player/preview_player.dart';
import 'package:subtitler/ui/player/subtitle_overlay.dart';
import 'package:subtitler/ui/player/video_preview.dart';

Future<void> waitFor(
  WidgetTester tester,
  String what,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Не дождались за ${timeout.inSeconds} с: $what');
    }
    // В живом режиме pump с длительностью действительно ждёт.
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String? shownText(WidgetTester tester) {
  final found = find.byType(OutlinedSubtitleText);
  if (found.evaluate().isEmpty) return null;
  return tester.widget<OutlinedSubtitleText>(found).text;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final ffmpeg = Platform.environment['SUBTITLER_FFMPEG'];
  late Directory dir;
  late String video;

  setUpAll(() async {
    if (ffmpeg == null) return;
    // Пробел и кириллица в пути — как у следователя на рабочем столе.
    dir = Directory.systemTemp.createTempSync('subtitler_smoke');
    final folder = Directory(p.join(dir.path, 'папка с пробелом'))
      ..createSync();
    video = p.join(folder.path, 'видео тест.mp4');
    final r = await Process.run(ffmpeg, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25:duration=4',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
      video,
    ]);
    if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
    initPreviewPlayers();
  });

  tearDownAll(() {
    if (ffmpeg != null) dir.deleteSync(recursive: true);
  });

  testWidgets('настоящий плеер открывает ролик, играет и перематывает',
      (tester) async {
    final player = createPreviewPlayer();
    if (Platform.isWindows) expect(player, isA<MediaKitPreviewPlayer>());
    addTearDown(player.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoPreview(player: player, cues: [
          Cue(
            index: 1,
            range: const TimeRange(0.5, 2.5),
            orig: 'Test',
            ru: 'Проверка оверлея',
            status: CueStatus.ok,
            flags: const {},
          ),
        ]),
      ),
    ));

    await player.open(video);
    await waitFor(tester, 'размер кадра',
        () => player.videoSize.value != null || player.error.value != null);
    expect(player.error.value, isNull);
    expect(player.videoSize.value, const Size(320, 240));
    await waitFor(tester, 'длительность',
        () => player.duration.value > Duration.zero);
    expect(player.duration.value.inMilliseconds, closeTo(4000, 200));
    // Открытие не запускает воспроизведение само.
    expect(player.playing.value, isFalse);

    if (player is MediaKitPreviewPlayer) {
      // Кадр дошёл до текстуры Flutter — значит, ANGLE поднялся.
      await player.firstFrameRendered.timeout(const Duration(seconds: 10));
    }

    await player.play();
    await waitFor(tester, 'позиция пошла',
        () => player.position.value > const Duration(milliseconds: 700));
    expect(player.playing.value, isTrue);
    expect(shownText(tester), 'Проверка оверлея');

    await player.pause();
    await waitFor(tester, 'пауза', () => !player.playing.value);

    await player.seek(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.position.value.inMilliseconds, closeTo(3000, 150));
    expect(shownText(tester), isNull);
    expect(find.text(kPreviewUnavailableText), findsNothing);
  }, skip: ffmpeg == null);

  testWidgets('не видео — надпись вместо кадра, приложение живо',
      (tester) async {
    final fake = p.join(dir.path, 'не видео.mp4');
    File(fake).writeAsStringSync('Это текстовый файл, а не видео.\n' * 50);
    final player = createPreviewPlayer();
    addTearDown(player.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VideoPreview(player: player, cues: const [])),
    ));
    await player.open(fake);
    await waitFor(tester, 'ошибка открытия', () => player.error.value != null,
        timeout: const Duration(seconds: 30));
    debugPrint('Ошибка плеера: ${player.error.value}');
    if (player is MediaKitPreviewPlayer) {
      // Ошибку сообщил сам mpv, а не сработал запасной таймаут: человек не
      // ждёт 20 секунд перед надписью.
      expect(player.error.value, isNot(startsWith('За ')));
    }
    await tester.pump();
    expect(find.text(kPreviewUnavailableText), findsOneWidget);
  }, skip: ffmpeg == null);
}
