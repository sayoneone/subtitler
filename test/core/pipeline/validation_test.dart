import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/pipeline/validation.dart';

Cue _cue(int i, double start, double end, {String orig = 'текст', String ru = 'текст',
    CueStatus status = CueStatus.ok}) {
  return Cue(index: i, range: TimeRange(start, end), orig: orig, ru: ru,
      status: status, flags: const {});
}

void main() {
  test('Корректные тайминги не дают замечаний', () {
    expect(validateTimings([_cue(1, 0, 2), _cue(2, 2.5, 4)]), isEmpty);
  });

  test('Конец раньше начала — ошибка', () {
    final issues = validateTimings([_cue(1, 5, 3)]);
    expect(issues.single.problem, TimingProblem.endBeforeStart);
    expect(issues.single.cueIndex, 1);
  });

  test('Нулевая длительность — ошибка', () {
    expect(validateTimings([_cue(1, 3, 3)]).single.problem,
        TimingProblem.endBeforeStart);
  });

  test('Перекрытие соседних реплик — ошибка', () {
    final issues = validateTimings([_cue(1, 0, 5), _cue(2, 4.5, 8)]);
    expect(issues.single.problem, TimingProblem.overlapsNext);
    expect(issues.single.cueIndex, 1);
  });

  test('Зацикленный повтор токена ловится с четвёртого раза', () {
    expect(hasRepeatLoop('beramiz beramiz beramiz beramiz'), isTrue);
    expect(hasRepeatLoop('beramiz beramiz beramiz'), isFalse);
    expect(hasRepeatLoop('bu niye çok sulu ***'), isFalse);
  });

  test('Повтор регистронезависим и не путается на пунктуации', () {
    expect(hasRepeatLoop('Da da, da. da da'), isTrue);
  });

  test('Автопометки ставятся по повтору, статусу и провалу перевода', () {
    final flagged = applyAutoFlags([
      _cue(1, 0, 2, orig: 'da da da da da'),
      _cue(2, 3, 5, status: CueStatus.failed, orig: '', ru: ''),
      _cue(3, 6, 8, orig: 'yazı var', ru: ''),
      _cue(4, 9, 11),
    ]);
    expect(flagged[0].flags, contains(CueFlag.repeatLoop));
    expect(flagged[1].flags, contains(CueFlag.translateFailed));
    expect(flagged[2].flags, contains(CueFlag.translateFailed));
    expect(flagged[3].flags, isEmpty);
  });

  test('Пустая по смыслу реплика не помечается провалом перевода', () {
    final flagged = applyAutoFlags([_cue(1, 0, 2, orig: '', ru: '',
        status: CueStatus.empty)]);
    expect(flagged.single.flags, isEmpty);
  });
}
