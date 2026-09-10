import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitler/core/pipeline/silence_scanner.dart';

/// Отдаёт заранее заготовленный лог для каждого порога и запоминает,
/// какие пороги пробовали.
class FakeRunner implements FfmpegRunner {
  final Map<String, String> logsByThreshold;
  final List<String> triedThresholds = [];

  FakeRunner(this.logsByThreshold);

  @override
  Future<FfmpegResult> run(List<String> args,
      {void Function(double seconds)? onProgress}) async {
    final filter = args[args.indexOf('-af') + 1];
    final threshold = RegExp(r'noise=(-?\d+dB)').firstMatch(filter)!.group(1)!;
    triedThresholds.add(threshold);
    return FfmpegResult(exitCode: 0, log: logsByThreshold[threshold] ?? '');
  }

  @override
  Future<double> probeDuration(String path) async => 30.0;
}

const _twoPauses = '''
silence_start: 5.0
silence_end: 6.0 | silence_duration: 1.0
silence_start: 12.0
silence_end: 13.0 | silence_duration: 1.0
''';

/// Пороги из основной цепочки подбора — без дополнительного
/// чувствительного прохода, которым дорезаются длинные куски речи.
List<String> _mainChain(FakeRunner runner) {
  final profiles = kSilenceProfiles.map((p) => p.threshold).toSet();
  return runner.triedThresholds.where(profiles.contains).toList();
}

void main() {
  test('Останавливается на первом пороге, где нашлись паузы', () async {
    final runner = FakeRunner({'-30dB': _twoPauses});
    final scan =
        await SilenceScanner(runner).scan(audioPath: 'a.wav', duration: 30.0);

    expect(scan.threshold, '-30dB');
    expect(_mainChain(runner), ['-30dB'],
        reason: 'дальше по цепочке идти не нужно');
    expect(scan.forcedSplit, isFalse);
    expect(scan.segments, isNotEmpty);
  });

  test('Перебирает пороги, пока пауз недостаточно', () async {
    final runner = FakeRunner({'-15dB': _twoPauses});
    final scan =
        await SilenceScanner(runner).scan(audioPath: 'a.wav', duration: 30.0);

    expect(scan.threshold, '-15dB');
    expect(_mainChain(runner), ['-30dB', '-25dB', '-20dB', '-18dB', '-15dB']);
    expect(scan.forcedSplit, isFalse);
  });

  test('Если пауз нет нигде — принудительная нарезка и флаг', () async {
    final runner = FakeRunner(const {});
    final scan =
        await SilenceScanner(runner).scan(audioPath: 'a.wav', duration: 30.0);

    expect(scan.forcedSplit, isTrue);
    expect(scan.segments.length, greaterThan(3));
    expect(scan.segments.last.end, closeTo(30.0, 1e-9));
    expect(runner.triedThresholds.length, kSilenceProfiles.length,
        reason: 'перед сдачей перебраны все пороги');
  });

  test('Длинный сплошной кусок речи дорезается по микропаузам', () async {
    // Две паузы на -30 dB порог принимают, но речь между ними идёт
    // кусками по 12 и 15 секунд — это больше предельных 8, поэтому
    // нужен более чувствительный проход (+3 dB) за микропаузами.
    final runner = FakeRunner({
      '-30dB': '''
silence_start: 12.0
silence_end: 13.0 | silence_duration: 1.0
silence_start: 28.0
silence_end: 29.0 | silence_duration: 1.0
''',
      '-27dB': '''
silence_start: 5.9
silence_end: 6.1 | silence_duration: 0.2
silence_start: 12.0
silence_end: 13.0 | silence_duration: 1.0
silence_start: 18.0
silence_end: 18.2 | silence_duration: 0.2
silence_start: 22.0
silence_end: 22.2 | silence_duration: 0.2
silence_start: 28.0
silence_end: 29.0 | silence_duration: 1.0
''',
    });
    final scan =
        await SilenceScanner(runner).scan(audioPath: 'a.wav', duration: 30.0);

    expect(scan.threshold, '-30dB', reason: 'основной порог подошёл');
    expect(runner.triedThresholds, contains('-27dB'),
        reason: 'для деления длинного куска нужен более чувствительный порог');
    expect(scan.forcedSplit, isFalse);
    for (final segment in scan.segments) {
      expect(segment.duration, lessThanOrEqualTo(8.5),
          reason: 'сегмент ${segment.start}-${segment.end} длиннее предела');
    }
  });
}
