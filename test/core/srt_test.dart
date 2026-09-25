import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/core/srt.dart';

const _cues = [
  Cue(index: 1, range: TimeRange(0.0, 2.4), orig: 'ağabey haber ver',
      ru: 'Брат, дай знать.', status: CueStatus.ok, flags: {}),
  Cue(index: 2, range: TimeRange(3.9, 8.12), orig: '', ru: '',
      status: CueStatus.empty, flags: {}),
  Cue(index: 3, range: TimeRange(9.03, 14.6), orig: 'kaç kişi geldi bugün',
      ru: 'Сколько человек сегодня пришло.', status: CueStatus.ok, flags: {}),
];

void main() {
  test('Таймкод форматируется как ЧЧ:ММ:СС,ммм', () {
    expect(formatSrtTimestamp(0), '00:00:00,000');
    expect(formatSrtTimestamp(5.83), '00:00:05,830');
    expect(formatSrtTimestamp(63.456), '00:01:03,456');
    expect(formatSrtTimestamp(3723.9), '01:02:03,900');
  });

  test('Таймкод разбирается обратно', () {
    expect(parseSrtTimestamp('00:00:05,830'), closeTo(5.83, 1e-9));
    expect(parseSrtTimestamp('01:02:03,456'), closeTo(3723.456, 1e-9));
  });

  test('Пустые реплики не попадают в SRT, нумерация сплошная', () {
    final srt = buildSrt(_cues, field: SrtField.ru);
    expect(srt, contains('1\n00:00:00,000 --> 00:00:02,400\nБрат, дай знать.'));
    expect(srt, contains('2\n00:00:09,030 --> 00:00:14,600\nСколько человек сегодня пришло.'));
    expect(srt, isNot(contains('00:00:03,900')), reason: 'пустая реплика пропущена');
  });

  test('Поле выбирается параметром', () {
    expect(buildSrt(_cues, field: SrtField.orig), contains('ağabey haber ver'));
    expect(buildSrt(_cues, field: SrtField.orig), isNot(contains('Брат')));
  });

  test('Разбор SRT возвращает те же тайминги и тексты', () {
    final parsed = parseSrt(buildSrt(_cues, field: SrtField.ru));
    expect(parsed.length, 2);
    expect(parsed.first.range.start, closeTo(0.0, 1e-9));
    expect(parsed.first.range.end, closeTo(2.4, 1e-9));
    expect(parsed.first.ru, 'Брат, дай знать.');
    expect(parsed.last.range.start, closeTo(9.03, 1e-9));
  });

  test('Многострочный текст реплики сохраняется', () {
    const multi = [
      Cue(index: 1, range: TimeRange(0, 2), orig: '', ru: 'Первая строка\nВторая строка',
          status: CueStatus.ok, flags: {}),
    ];
    final parsed = parseSrt(buildSrt(multi, field: SrtField.ru));
    expect(parsed.single.ru, 'Первая строка\nВторая строка');
  });
}
