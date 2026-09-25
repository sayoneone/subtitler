import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';

void main() {
  test('TimeRange считает длительность', () {
    expect(const TimeRange(1.5, 4.25).duration, closeTo(2.75, 1e-9));
  });

  test('Cue переживает сериализацию без потерь', () {
    const cue = Cue(
      index: 3,
      range: TimeRange(9.03, 14.6),
      orig: 'sabah vardiyası başladı',
      ru: 'Утренняя смена началась',
      status: CueStatus.ok,
      flags: {CueFlag.repeatLoop},
    );
    final restored = Cue.fromJson(cue.toJson());
    expect(restored.index, 3);
    expect(restored.range.start, closeTo(9.03, 1e-9));
    expect(restored.range.end, closeTo(14.6, 1e-9));
    expect(restored.orig, cue.orig);
    expect(restored.ru, cue.ru);
    expect(restored.status, CueStatus.ok);
    expect(restored.flags, {CueFlag.repeatLoop});
  });

  test('Отпечаток совпадает при равных размере и длительности', () {
    const a = SourceFingerprint(sizeBytes: 4812907, durationSec: 41.20);
    const b = SourceFingerprint(sizeBytes: 4812907, durationSec: 41.201);
    const c = SourceFingerprint(sizeBytes: 4812908, durationSec: 41.20);
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
    expect(restored.schemaVersion, Session.currentSchemaVersion);
    expect(restored.lang, 'tr-TR');
    expect(restored.forcedSplit, isTrue);
    expect(restored.cues.single.orig, 'abi');
  });

  test('Уверенность, второй язык и пробы всех языков переживают сериализацию',
      () {
    const session = Session(
      videoPath: '/tmp/video.mp4',
      fingerprint: SourceFingerprint(sizeBytes: 10, durationSec: 1.0),
      lang: 'tr-TR',
      langConfidence: LanguageConfidence.low,
      langRunnerUp: 'uz-UZ',
      probeTexts: {
        'tr-TR': {3: 'yarın sabah erkenden çarşıya gideceğiz', 7: ''},
        'uz-UZ': {3: 'ertaga ertalab bozorga boramiz'},
      },
      silenceThreshold: '-30dB',
      forcedSplit: false,
      cues: [],
    );
    // Через настоящий JSON: ключи-номера реплик там становятся строками.
    final restored = Session.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>);
    expect(restored.langConfidence, LanguageConfidence.low);
    expect(restored.langRunnerUp, 'uz-UZ');
    expect(restored.probeTexts['tr-TR'],
        {3: 'yarın sabah erkenden çarşıya gideceğiz', 7: ''});
    expect(restored.probeTexts['uz-UZ'], {3: 'ertaga ertalab bozorga boramiz'});
  });

  test('copyWith сбрасывает уверенность только по явному null', () {
    const session = Session(
      videoPath: '/tmp/video.mp4',
      fingerprint: SourceFingerprint(sizeBytes: 10, durationSec: 1.0),
      lang: 'tr-TR',
      langConfidence: LanguageConfidence.low,
      langRunnerUp: 'uz-UZ',
      silenceThreshold: '-30dB',
      forcedSplit: false,
      cues: [],
    );
    expect(session.copyWith(lang: 'uz-UZ').langConfidence,
        LanguageConfidence.low);
    final manual = session.copyWith(langConfidence: null, langRunnerUp: null);
    expect(manual.langConfidence, isNull);
    expect(manual.langRunnerUp, isNull);
  });
}
