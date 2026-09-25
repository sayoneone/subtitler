import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../player/video_preview.dart';

/// Как выглядит строка реплики в списке предпросмотра.
enum CueTone {
  /// Обычная строка: смотреть незачем.
  normal,

  /// Жёлтая: у реплики есть причина её проверить.
  review,

  /// Серая «речи нет»: распознавание вернуло пустоту, перевода нет.
  empty,

  /// Серая «ещё не распознано»: обработку остановили раньше.
  pending,
}

/// Почему реплику стоит проверить — по-русски, по одной строке на причину.
///
/// Принудительная нарезка (`forcedSplit`) сюда нарочно не входит: она
/// ставится на КАЖДУЮ реплику ролика, и жёлтым стал бы весь список (дефект 7
/// карты интерфейса). О ней говорит одна плашка над списком. Поэтому и
/// жёлтые строки, и число «проверить M» в шапке
/// (`AppController.reviewCount`) считают одни и те же пометки.
List<String> cueReviewReasons(Cue cue) => [
  if (cue.flags.contains(CueFlag.repeatLoop))
    'возможен сбой распознавания — повтор слова',
  // Ядро ставит translateFailed и нераспознанной реплике: перевода
  // нет, потому что нечего переводить. Человеку важнее первое.
  if (cue.flags.contains(CueFlag.translateFailed))
    cue.status == CueStatus.failed
        ? 'не распознано — впишите сами'
        : 'перевод не получен',
];

CueTone cueTone(Cue cue) {
  if (cueReviewReasons(cue).isNotEmpty) return CueTone.review;
  // Вписанный текст делает строку обычной: контроллер в этот момент и
  // статус меняет на ok, но строка не должна ждать и этого.
  if (cue.ru.trim().isNotEmpty) return CueTone.normal;
  return switch (cue.status) {
    CueStatus.empty => CueTone.empty,
    CueStatus.pending => CueTone.pending,
    _ => CueTone.normal,
  };
}

/// Подпись серой строки. Имя перечисления (`empty`, `pending`) человеку
/// не показывается никогда (дефект 10).
String? cueToneCaption(CueTone tone) => switch (tone) {
  CueTone.empty => 'речи нет',
  CueTone.pending => 'ещё не распознано',
  _ => null,
};

/// Фон строки. Цвета из схемы темы, кроме жёлтого: «на проверку» должно
/// читаться одинаково при любой теме.
Color? cueToneColor(CueTone tone, ColorScheme scheme) => switch (tone) {
  CueTone.normal => null,
  CueTone.review => kReviewYellow,
  CueTone.empty || CueTone.pending => scheme.surfaceContainerHighest,
};

/// Жёлтый строк и плашек «проверьте».
final Color kReviewYellow = Colors.amber.withValues(alpha: 0.18);

int _ms(double seconds) => (seconds * 1000).round();

/// Реплика, чей отрезок времени идёт в момент [t], — номер ([Cue.index]) или
/// `null` в паузе между репликами.
///
/// В отличие от оверлея (`CueTimeline`), здесь важны и реплики без текста:
/// человек слушает «не распознано — впишите сами», и строка должна
/// подсвечиваться. Интервал полуоткрытый, как у libass; при перекрытии —
/// начавшаяся позже.
int? currentCueAt(List<Cue> cues, Duration t) {
  final ms = t.inMilliseconds;
  Cue? found;
  for (final cue in cues) {
    final start = _ms(cue.range.start);
    if (start <= ms &&
        ms < _ms(cue.range.end) &&
        (found == null || start >= _ms(found.range.start))) {
      found = cue;
    }
  }
  return found?.index;
}

/// Время начала реплики в списке — так же, как его показывает плеер.
String formatCueTime(double seconds) =>
    formatPreviewTime(Duration(milliseconds: _ms(seconds)));

/// «Сохраняем видео с субтитрами… 47 %». Проценты вниз: «100 %» — только
/// когда кодирование действительно закончилось. Пробел неразрывный, чтобы
/// «%» не уехал на отдельную строку.
String savingLabel(double fraction) {
  final percent = (fraction.clamp(0.0, 1.0) * 100 + 1e-9).floor();
  return 'Сохраняем видео с субтитрами… $percent %';
}

/// Сколько реплик распознано в сессии, которую остановили: `null`, если
/// нераспознанных нет (сессия не частичная).
({int recognized, int total})? partialProgress(Session session) {
  final pending = session.cues
      .where((c) => c.status == CueStatus.pending)
      .length;
  if (pending == 0) return null;
  return (
    recognized: session.cues.length - pending,
    total: session.cues.length,
  );
}
