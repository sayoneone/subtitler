import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';

void main() {
  test('TimeRange считает длительность', () {
    expect(const TimeRange(1.5, 4.25).duration, closeTo(2.75, 1e-9));
  });

  test('Cue переживает сериализацию без потерь', () {
    const cue = Cue(
      index: 3,
      range: TimeRange(7.52, 13.23),
      orig: 'sabah vardiyası başladı',
      ru: 'Утренняя смена началась',
      status: CueStatus.ok,
      flags: {CueFlag.repeatLoop},
    );
    final restored = Cue.fromJson(cue.toJson());
    expect(restored.index, 3);
    expect(restored.range.start, closeTo(7.52, 1e-9));
    expect(restored.range.end, closeTo(13.23, 1e-9));
    expect(restored.orig, cue.orig);
    expect(restored.ru, cue.ru);
    expect(restored.status, CueStatus.ok);
    expect(restored.flags, {CueFlag.repeatLoop});
  });

  test('Отпечаток совпадает при равных размере и длительности', () {
    const a = SourceFingerprint(sizeBytes: 6571302, durationSec: 34.80);
    const b = SourceFingerprint(sizeBytes: 6571302, durationSec: 34.801);
    const c = SourceFingerprint(sizeBytes: 6571303, durationSec: 34.80);
    expect(a.matches(b), isTrue, reason: 'разница длительности < 0.01 с');
    expect(a.matches(c), isFalse, reason: 'другой размер файла');
  });

  test('Session переживает сериализацию', () {
    const session = Session(
      videoPath: '/tmp/video.mp4',
      fingerprint: SourceFingerprint(sizeBytes: 10, durationSec: 1.0),
      lang: 'tr-TR',
      silenceThreshold: '-30dB',
      forcedSplit: true,
      cues: [
        Cue(index: 1, range: TimeRange(0, 1.7), orig: 'abi', ru: 'брат',
            status: CueStatus.ok, flags: {}),
      ],
    );
    final restored = Session.fromJson(session.toJson());
    expect(restored.schemaVersion, 1);
    expect(restored.lang, 'tr-TR');
    expect(restored.forcedSplit, isTrue);
    expect(restored.cues.single.orig, 'abi');
  });
}
