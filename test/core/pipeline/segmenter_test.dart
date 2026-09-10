import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/segmenter.dart';

void main() {
  test('Близкие короткие интервалы склеиваются', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 2.0), TimeRange(2.5, 4.0)],
      duration: 5.0,
    );
    expect(segments.length, 1, reason: 'зазор 0.5 с ≤ 1.0 с, сумма ≤ 8 с');
    expect(segments.single.start, closeTo(0.0, 1e-9));
    expect(segments.single.end, closeTo(4.12, 1e-9), reason: 'паддинг 0.12 в конце');
  });

  test('Далёкие интервалы остаются раздельными', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 2.0), TimeRange(5.0, 7.0)],
      duration: 8.0,
    );
    expect(segments.length, 2);
  });

  test('Паддинг никогда не даёт перекрытия соседей', () {
    // зазор 0.1 с: половина зазора = 0.05, значит паддинг обрежется до 0.05.
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 5.0), TimeRange(5.1, 10.0)],
      duration: 10.0,
    );
    expect(segments.length, 2, reason: 'сумма 10 с > 8 с, склейки нет');
    expect(segments[0].end, lessThanOrEqualTo(segments[1].start),
        reason: 'перекрытие отправило бы один звук в платный API дважды');
    expect(segments[0].end, closeTo(5.05, 1e-9));
    expect(segments[1].start, closeTo(5.05, 1e-9));
  });

  test('Длинный интервал режется по микропаузам', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 20.0)],
      duration: 20.0,
      fineSpeech: const [
        TimeRange(0.0, 6.0),
        TimeRange(6.3, 13.0),
        TimeRange(13.4, 20.0),
      ],
    );
    expect(segments.length, greaterThan(1));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kMaxSegment + 0.5));
    }
  });

  test('Без микропауз длинный интервал режется принудительно', () {
    final segments = buildSegments(
      speech: const [TimeRange(0.0, 20.0)],
      duration: 20.0,
    );
    expect(segments.length, greaterThanOrEqualTo(3));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kMaxSegment + 0.5));
    }
  });

  test('Границы округляются до сотых', () {
    final segments = buildSegments(
      speech: const [TimeRange(1.234567, 3.987654)],
      duration: 5.0,
    );
    expect(segments.single.start, closeTo(1.11, 1e-9));
    expect(segments.single.end, closeTo(4.11, 1e-9));
  });

  test('Принудительная нарезка покрывает весь ролик кусками по 7.2 с', () {
    final segments = forcedSegments(20.0);
    expect(segments.first.start, 0.0);
    expect(segments.last.end, closeTo(20.0, 1e-9));
    for (final s in segments) {
      expect(s.duration, lessThanOrEqualTo(kForcedSplit + 1e-9));
    }
    for (var i = 0; i + 1 < segments.length; i++) {
      expect(segments[i].end, closeTo(segments[i + 1].start, 1e-9));
    }
  });

  test('Пустой вход даёт пустой результат', () {
    expect(buildSegments(speech: const [], duration: 10.0), isEmpty);
  });
}
