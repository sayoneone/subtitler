import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';
import 'segmenter.dart';
import 'silence_parser.dart';

class SilenceProfile {
  final String threshold;
  final double minDuration;
  const SilenceProfile(this.threshold, this.minDuration);
}

/// Пороги от щадящего к агрессивному: на записях со стройплощадки тихих
/// пауз не бывает, приходится спускаться до −15 dB.
const List<SilenceProfile> kSilenceProfiles = [
  SilenceProfile('-30dB', 0.3),
  SilenceProfile('-25dB', 0.3),
  SilenceProfile('-20dB', 0.25),
  SilenceProfile('-18dB', 0.25),
  SilenceProfile('-15dB', 0.25),
];

class SilenceScan {
  final List<TimeRange> segments;
  final String threshold;
  final bool forcedSplit;
  const SilenceScan({
    required this.segments,
    required this.threshold,
    required this.forcedSplit,
  });
}

class SilenceScanner {
  final FfmpegRunner runner;
  SilenceScanner(this.runner);

  /// Порог считается подошедшим, если найдена хотя бы одна пауза
  /// на каждые 15 секунд записи.
  static int _requiredPauses(double duration) =>
      (duration / 15).floor().clamp(1, 1 << 30);

  Future<List<SilenceEvent>> _detect(
      String audioPath, SilenceProfile profile) async {
    final result = await runner.run(FfmpegCommands.detectSilence(
      input: audioPath,
      noise: profile.threshold,
      minDuration: profile.minDuration,
    ));
    return parseSilenceLog(result.log);
  }

  Future<SilenceScan> scan({
    required String audioPath,
    required double duration,
  }) async {
    final needed = _requiredPauses(duration);

    for (final profile in kSilenceProfiles) {
      final events = await _detect(audioPath, profile);
      final pauses =
          events.where((e) => e.kind == SilenceEventKind.start).length;
      if (pauses < needed) continue;

      final speech = speechIntervals(events, duration);
      // Более чувствительный порог нужен только чтобы резать длинные куски.
      final needsFine = speech.any((r) => r.duration > kMaxSegment + 0.5);
      var fine = const <TimeRange>[];
      if (needsFine) {
        final bumped = int.parse(profile.threshold.replaceAll('dB', '')) + 3;
        fine = speechIntervals(
          await _detect(audioPath, SilenceProfile('${bumped}dB', 0.15)),
          duration,
        );
      }

      return SilenceScan(
        segments:
            buildSegments(speech: speech, duration: duration, fineSpeech: fine),
        threshold: profile.threshold,
        forcedSplit: false,
      );
    }

    return SilenceScan(
      segments: forcedSegments(duration),
      threshold: kSilenceProfiles.last.threshold,
      forcedSplit: true,
    );
  }
}
