// Тест ядра лежит здесь, а не в test/core: ему нужен только models.dart, а
// test/core сейчас параллельно перестраивается вместе со схемой сессии.
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cue_timeline.dart';
import 'package:subtitler/core/models.dart';

Cue cue(
  int index,
  double start,
  double end,
  String ru, {
  CueStatus status = CueStatus.ok,
}) =>
    Cue(
      index: index,
      range: TimeRange(start, end),
      orig: 'orig $index',
      ru: ru,
      status: status,
      flags: const {},
    );

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('CueTimeline.at', () {
    final cues = [
      cue(1, 1.0, 3.0, 'Первая'),
      cue(2, 3.0, 5.0, 'Вторая'),
      cue(3, 7.5, 9.25, 'Третья'),
    ];
    final timeline = CueTimeline(cues);

    test('до первой реплики пусто', () {
      expect(timeline.at(Duration.zero), isNull);
      expect(timeline.at(ms(999)), isNull);
    });

    test('начало реплики включено', () {
      expect(timeline.at(ms(1000))?.ru, 'Первая');
    });

    test('последняя миллисекунда реплики ещё её', () {
      expect(timeline.at(ms(2999))?.ru, 'Первая');
    });

    test('на стыке видна следующая, а не предыдущая', () {
      expect(timeline.at(ms(3000))?.ru, 'Вторая');
    });

    test('конец реплики исключён: в паузе пусто', () {
      expect(timeline.at(ms(5000)), isNull);
      expect(timeline.at(ms(7499)), isNull);
    });

    test('дробные границы сравниваются в миллисекундах SRT', () {
      expect(timeline.at(ms(7500))?.ru, 'Третья');
      expect(timeline.at(ms(9249))?.ru, 'Третья');
      expect(timeline.at(ms(9250)), isNull);
    });

    test('границы округляются до миллисекунды так же, как в SRT', () {
      // 1.001 и 2.003 в double — это 1000.99999… и 2002.99999… мс. В SRT
      // уходят 00:00:01,001 и 00:00:02,003; отбрасывание дробной части
      // сдвинуло бы реплику на миллисекунду раньше вшитой.
      final t = CueTimeline([cue(1, 1.001, 2.003, 'Точно')]);
      expect(t.at(ms(1000)), isNull);
      expect(t.at(ms(1001))?.ru, 'Точно');
      expect(t.at(ms(2002))?.ru, 'Точно');
      expect(t.at(ms(2003)), isNull);
    });

    test('после последней реплики пусто', () {
      expect(timeline.at(const Duration(hours: 1)), isNull);
    });
  });

  test('пустой список — всегда пусто', () {
    expect(CueTimeline(const []).at(ms(1000)), isNull);
  });

  test('реплика «речи нет» не показывается, даже с текстом', () {
    final timeline = CueTimeline([
      cue(1, 0, 2, 'Остаток текста', status: CueStatus.empty),
    ]);
    expect(timeline.at(ms(1000)), isNull);
  });

  test('пустой и пробельный перевод не показываются', () {
    final timeline = CueTimeline([
      cue(1, 0, 2, ''),
      cue(2, 2, 4, '  \n '),
      cue(3, 4, 6, 'Есть перевод'),
    ]);
    expect(timeline.at(ms(1000)), isNull);
    expect(timeline.at(ms(3000)), isNull);
    expect(timeline.at(ms(5000))?.ru, 'Есть перевод');
  });

  test('невидимая реплика не прячет соседей', () {
    final timeline = CueTimeline([
      cue(1, 0, 2, 'До'),
      cue(2, 2, 4, '', status: CueStatus.failed),
      cue(3, 4, 6, 'После'),
    ]);
    expect(timeline.at(ms(1999))?.ru, 'До');
    expect(timeline.at(ms(2000)), isNull);
    expect(timeline.at(ms(4000))?.ru, 'После');
  });

  test('ожидающая и неудачная реплика с вписанным текстом показываются', () {
    final timeline = CueTimeline([
      cue(1, 0, 2, 'Вписано вручную', status: CueStatus.failed),
    ]);
    expect(timeline.at(ms(500))?.ru, 'Вписано вручную');
  });

  test('порядок во входном списке не важен', () {
    // Такой порядок ломает двоичный поиск без предварительной сортировки:
    // на 2,5 с он ушёл бы влево от «Вторая» и не нашёл бы ничего.
    final timeline = CueTimeline([
      cue(1, 0, 2, 'Первая'),
      cue(3, 4, 6, 'Третья'),
      cue(2, 2, 4, 'Вторая'),
    ]);
    expect(timeline.at(ms(500))?.ru, 'Первая');
    expect(timeline.at(ms(2500))?.ru, 'Вторая');
    expect(timeline.at(ms(4500))?.ru, 'Третья');
  });

  test('при перекрытии видна начавшаяся позже, а после неё — длинная', () {
    final timeline = CueTimeline([
      cue(1, 0, 10, 'Длинная'),
      cue(2, 2, 4, 'Короткая'),
    ]);
    expect(timeline.at(ms(1000))?.ru, 'Длинная');
    expect(timeline.at(ms(3000))?.ru, 'Короткая');
    // Короткая кончилась, длинная ещё звучит — текст не должен пропасть.
    expect(timeline.at(ms(5000))?.ru, 'Длинная');
    expect(timeline.at(ms(10000)), isNull);
  });

  test('много реплик: поиск находит каждую', () {
    final many = [
      for (var i = 0; i < 500; i++) cue(i, i * 2.0, i * 2.0 + 1.5, 'Реплика $i'),
    ];
    final timeline = CueTimeline(many);
    for (var i = 0; i < 500; i++) {
      expect(timeline.at(ms(i * 2000))?.ru, 'Реплика $i');
      expect(timeline.at(ms(i * 2000 + 1499))?.ru, 'Реплика $i');
      expect(timeline.at(ms(i * 2000 + 1500)), isNull);
    }
  });

  test('cueAt — то же самое разовым вызовом', () {
    expect(cueAt([cue(1, 1, 2, 'Раз')], ms(1500))?.ru, 'Раз');
    expect(cueAt([cue(1, 1, 2, 'Раз')], ms(2000)), isNull);
  });
}
