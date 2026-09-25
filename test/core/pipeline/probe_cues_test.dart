import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/probe_cues.dart';

/// Реплики подряд с паузой 1 с; [lengths] — их длительности.
List<Cue> cuesOf(List<double> lengths) {
  final cues = <Cue>[];
  var t = 0.0;
  for (var i = 0; i < lengths.length; i++) {
    cues.add(Cue(
      index: i + 1,
      range: TimeRange(t, t + lengths[i]),
      orig: '',
      ru: '',
      status: CueStatus.pending,
      flags: const {},
    ));
    t += lengths[i] + 1;
  }
  return cues;
}

List<int> indices(List<Cue> cues) => cues.map((c) => c.index).toList();

void main() {
  test('Две самые длинные реплики, если они в разных частях ролика', () {
    final cues = cuesOf([7.5, 3, 3, 3, 3, 3, 3, 7.8]);
    expect(indices(pickProbeCues(cues)), [1, 8]);
  });

  test('Соседняя длинная реплика уступает чуть более короткой издалека', () {
    // Две самые длинные стоят рядом (скорее всего, один говорящий).
    final cues = cuesOf([7.9, 7.8, 3, 3, 3, 3, 3, 7.2]);
    expect(indices(pickProbeCues(cues)), [1, 8]);
  });

  test('Далёкая, но слишком короткая реплика не годится', () {
    // Вдалеке только короткие реплики — берём длинную, пусть и ближе
    // четверти ролика (но не соседнюю).
    final cues = cuesOf([7.9, 1, 7.8, 2, 2, 2, 2, 2, 2, 2, 2, 2]);
    expect(indices(pickProbeCues(cues)), [1, 3]);
  });

  test('Уже пробованные реплики не повторяются, новые — подальше от них', () {
    final cues = cuesOf([7.9, 7, 3, 3, 6, 3, 3, 7.5]);
    final first = pickProbeCues(cues);
    expect(indices(first), [1, 8]);
    final second = pickProbeCues(cues, taken: first);
    expect(indices(second), isNot(contains(1)));
    expect(indices(second), isNot(contains(8)));
    expect(indices(second), contains(5),
        reason: 'середина ролика — единственная далёкая от первых проб');
  });

  test('Реплик меньше, чем просили, — берутся все', () {
    final cues = cuesOf([4, 2]);
    expect(indices(pickProbeCues(cues, count: 5)), [1, 2]);
    expect(pickProbeCues(cues, count: 2, taken: cues), isEmpty);
  });

  test('Пустой список — пустой выбор', () {
    expect(pickProbeCues(const []), isEmpty);
  });
}
