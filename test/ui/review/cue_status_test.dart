import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/review/cue_status.dart';

import '../../support/app_harness.dart';

Cue _cue(
  int index,
  double start,
  double end, {
  String orig = 'söz',
  String ru = 'слово',
  CueStatus status = CueStatus.ok,
  Set<CueFlag> flags = const {},
}) => Cue(
  index: index,
  range: TimeRange(start, end),
  orig: orig,
  ru: ru,
  status: status,
  flags: flags,
);

void main() {
  group('Причины проверки', () {
    test('по пометкам, по-русски', () {
      final cues = {for (final c in sampleSession().cues) c.index: c};
      expect(cueReviewReasons(cues[1]!), isEmpty);
      expect(cueReviewReasons(cues[2]!), [
        'возможен сбой распознавания — повтор слова',
      ]);
      expect(cueReviewReasons(cues[3]!), ['не распознано — впишите сами']);
      expect(cueReviewReasons(cues[4]!), ['перевод не получен']);
      expect(cueReviewReasons(cues[5]!), isEmpty);
    });

    test('принудительная нарезка причиной не считается', () {
      final cue = _cue(1, 0, 1, flags: const {CueFlag.forcedSplit});
      expect(cueReviewReasons(cue), isEmpty);
      expect(cueTone(cue), CueTone.normal);
    });

    test('несколько причин — все', () {
      final cue = _cue(
        1,
        0,
        1,
        ru: '',
        flags: const {CueFlag.repeatLoop, CueFlag.translateFailed},
      );
      expect(cueReviewReasons(cue), hasLength(2));
    });
  });

  group('Вид строки', () {
    test('«речи нет» серая, пока в ней нет текста', () {
      final empty = _cue(1, 0, 1, orig: '', ru: '', status: CueStatus.empty);
      expect(cueTone(empty), CueTone.empty);
      expect(cueToneCaption(CueTone.empty), 'речи нет');
      expect(cueTone(empty.copyWith(ru: 'шёпот')), CueTone.normal);
      expect(cueTone(empty.copyWith(ru: '   ')), CueTone.empty);
    });

    test('ещё не распознанная — серая «ещё не распознано»', () {
      final pending = _cue(
        1,
        0,
        1,
        orig: '',
        ru: '',
        status: CueStatus.pending,
      );
      expect(cueTone(pending), CueTone.pending);
      expect(cueToneCaption(CueTone.pending), 'ещё не распознано');
    });

    test('нераспознанная с вписанным переводом — обычная', () {
      // Контроллер снимает translateFailed, как только текст вписан.
      final written = _cue(
        1,
        0,
        1,
        orig: '',
        ru: 'вписано вручную',
        status: CueStatus.failed,
      );
      expect(cueTone(written), CueTone.normal);
    });
  });

  group('Текущая реплика', () {
    final cues = [
      _cue(1, 1.0, 3.0),
      _cue(2, 3.0, 5.0, ru: '', status: CueStatus.failed),
      _cue(3, 6.0, 7.0, orig: '', ru: '', status: CueStatus.empty),
    ];

    test('начало включено, конец исключён', () {
      expect(currentCueAt(cues, const Duration(milliseconds: 999)), isNull);
      expect(currentCueAt(cues, const Duration(seconds: 1)), 1);
      expect(currentCueAt(cues, const Duration(milliseconds: 2999)), 1);
      expect(currentCueAt(cues, const Duration(seconds: 3)), 2);
    });

    test('реплики без текста тоже подсвечиваются, в паузе — ничего', () {
      expect(currentCueAt(cues, const Duration(seconds: 4)), 2);
      expect(currentCueAt(cues, const Duration(milliseconds: 5500)), isNull);
      expect(currentCueAt(cues, const Duration(milliseconds: 6500)), 3);
    });

    test('при перекрытии — начавшаяся позже', () {
      final overlapping = [_cue(1, 0, 10), _cue(2, 4, 6)];
      expect(currentCueAt(overlapping, const Duration(seconds: 5)), 2);
      expect(currentCueAt(overlapping, const Duration(seconds: 7)), 1);
    });
  });

  test('проценты сохранения — вниз, «100 %» только в конце', () {
    expect(savingLabel(0.47), 'Сохраняем видео с субтитрами… 47 %');
    expect(savingLabel(0), 'Сохраняем видео с субтитрами… 0 %');
    expect(savingLabel(0.999), 'Сохраняем видео с субтитрами… 99 %');
    expect(savingLabel(1), 'Сохраняем видео с субтитрами… 100 %');
    expect(savingLabel(1.3), 'Сохраняем видео с субтитрами… 100 %');
  });

  test('частичный результат — сколько распознано', () {
    expect(partialProgress(sampleSession()), isNull);
    final s = sampleSession();
    final partial = s.copyWith(
      cues: [
        for (final c in s.cues)
          c.index > 3 ? c.copyWith(status: CueStatus.pending) : c,
      ],
    );
    expect(partialProgress(partial), (recognized: 3, total: 5));
  });

  test('время строки — как в плеере', () {
    expect(formatCueTime(0.5), '0:00');
    expect(formatCueTime(65.2), '1:05');
    expect(formatCueTime(3725), '1:02:05');
  });
}
