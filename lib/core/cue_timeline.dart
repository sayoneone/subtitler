import 'models.dart';
import 'srt.dart';

/// Реплика попадает в кадр ровно тогда, когда `buildSrt` берёт её во
/// вшивание: правило общее ([subtitleText]), иначе предпросмотр разошёлся
/// бы с готовым видео.
///
/// Раньше реплика «речи нет» (`empty`) скрывалась и с текстом. Но текст
/// у неё бывает вписан человеком: реплика не распозналась, он вписал, а
/// при повторном открытии видео распознавание вернуло пустоту. Вшивание
/// такой текст показывает — теперь и предпросмотр.
bool isCueVisible(Cue cue) => subtitleText(cue, SrtField.ru).isNotEmpty;

/// Миллисекунды — точность SRT, через который субтитры попадают в libass.
/// Сравнивать надо в них, а не в долях секунды: иначе на стыке двух реплик
/// предпросмотр и вшитое видео разошлись бы на кадр.
int _ms(double seconds) => (seconds * 1000).round();

/// Какая реплика звучит в момент [t] — для оверлея субтитров в плеере.
///
/// Интервал полуоткрытый, как у libass: реплика видна с начала включительно
/// до конца исключительно. Поэтому на стыке `…—5.0` и `5.0—…` видна уже
/// вторая, а не обе сразу.
///
/// Позиция приходит из плеера до 30 раз в секунду, поэтому видимые реплики
/// один раз отбираются и сортируются в конструкторе, а поиск — двоичный.
class CueTimeline {
  CueTimeline(Iterable<Cue> cues)
      : _cues = cues.where(isCueVisible).toList()
          ..sort((a, b) => _ms(a.range.start).compareTo(_ms(b.range.start))) {
    _starts = [for (final c in _cues) _ms(c.range.start)];
    // Наибольший конец среди реплик 0..i: позволяет найти реплику, которая
    // началась раньше и ещё звучит, когда более поздняя уже кончилась.
    // Реплики сегментатора не перекрываются, но ручная правка времени —
    // может, и тогда оверлей не должен молча терять текст.
    var maxEnd = -1;
    _maxEndUpTo = [
      for (final c in _cues) maxEnd = _max(maxEnd, _ms(c.range.end)),
    ];
  }

  final List<Cue> _cues;
  late final List<int> _starts;
  late final List<int> _maxEndUpTo;

  static int _max(int a, int b) => a > b ? a : b;

  /// Видимые реплики в порядке начала.
  List<Cue> get visible => List.unmodifiable(_cues);

  /// Реплика в момент [t] или `null`, если в этот момент в кадре пусто.
  /// Если реплики перекрываются, берётся начавшаяся позже.
  Cue? at(Duration t) {
    final ms = t.inMilliseconds;
    // Последняя реплика, начавшаяся не позже ms.
    var lo = 0;
    var hi = _starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_starts[mid] <= ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo - 1; i >= 0 && _maxEndUpTo[i] > ms; i--) {
      if (_ms(_cues[i].range.end) > ms) return _cues[i];
    }
    return null;
  }
}

/// Разовый вопрос «что в кадре в момент [t]». Для потока позиций плеера
/// выгоднее один раз построить [CueTimeline].
Cue? cueAt(Iterable<Cue> cues, Duration t) => CueTimeline(cues).at(t);
