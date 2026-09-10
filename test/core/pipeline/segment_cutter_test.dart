import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/segment_cutter.dart';

void main() {
  late Directory tmp;
  late String tone;
  final runner = ProcessFfmpegRunner();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('cutter_test_');
    tone = '${tmp.path}/tone.wav';
    await runner.run([
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
      '-ac', '1', '-ar', '48000', tone,
    ]);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('Каждый сегмент превращается в непустой ogg-файл', () async {
    final files = await SegmentCutter(runner).cut(
      audioPath: tone,
      segments: const [TimeRange(0.0, 5.0), TimeRange(6.0, 12.0)],
      outputDir: tmp.path,
    );
    expect(files.length, 2);
    expect(files[0].index, 1);
    expect(files[1].index, 2);
    for (final f in files) {
      final file = File(f.path);
      expect(file.existsSync(), isTrue, reason: f.path);
      expect(file.lengthSync(), greaterThan(0));
      expect(file.lengthSync(), lessThan(kMaxSegmentBytes),
          reason: 'лимит SpeechKit v1 — 1 МБ на запрос');
    }
  });

  test('Имена файлов упорядочены и не конфликтуют', () async {
    final files = await SegmentCutter(runner).cut(
      audioPath: tone,
      segments: const [TimeRange(0.0, 2.0), TimeRange(3.0, 5.0)],
      outputDir: tmp.path,
    );
    expect(files.map((f) => f.path.split('/').last).toList(),
        ['seg_001.ogg', 'seg_002.ogg']);
  });

  test('Ошибка ffmpeg превращается в исключение с текстом лога', () async {
    expect(
      () => SegmentCutter(runner).cut(
        audioPath: '${tmp.path}/нет-файла.wav',
        segments: const [TimeRange(0.0, 1.0)],
        outputDir: tmp.path,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
