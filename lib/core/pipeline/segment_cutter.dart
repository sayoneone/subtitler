import 'dart:io';

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';

/// Жёсткий лимит SpeechKit v1 на один синхронный запрос.
const int kMaxSegmentBytes = 1000000;

class SegmentFile {
  final int index;
  final TimeRange range;
  final String path;
  const SegmentFile({
    required this.index,
    required this.range,
    required this.path,
  });
}

class SegmentCutter {
  final FfmpegRunner runner;
  SegmentCutter(this.runner);

  Future<List<SegmentFile>> cut({
    required String audioPath,
    required List<TimeRange> segments,
    required String outputDir,
  }) async {
    Directory(outputDir).createSync(recursive: true);
    final files = <SegmentFile>[];

    for (var i = 0; i < segments.length; i++) {
      final index = i + 1;
      final name = 'seg_${index.toString().padLeft(3, '0')}.ogg';
      final path = '$outputDir${Platform.pathSeparator}$name';

      final result = await runner.run(FfmpegCommands.cutSegment(
        input: audioPath,
        output: path,
        start: segments[i].start,
        end: segments[i].end,
      ));
      if (!result.ok) {
        throw StateError('Не удалось вырезать сегмент $index: ${result.log}');
      }
      files.add(SegmentFile(index: index, range: segments[i], path: path));
    }
    return files;
  }
}
