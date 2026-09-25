import '../models.dart';

/// Выбирает реплики для пробного распознавания на нескольких языках.
///
/// Берутся самые длинные реплики — на них у моделей больше шансов
/// проявить различия, а оплачиваются они так же, как короткие (каждая
/// реплика до 15 с стоит один блок). Но по возможности из разных частей
/// ролика: соседние реплики часто принадлежат одному говорящему, и если
/// он, например, вставил фразу по-русски, обе пробы окажутся нетипичными.
///
/// Правило для каждой следующей реплики, по порядку предпочтения:
/// 1. самая длинная из «далёких» — не соседних ни с одной уже выбранной
///    (включая [taken]) и отстоящих от каждой не меньше чем на четверть
///    записи, — если она хотя бы вдвое не короче самой длинной из
///    оставшихся;
/// 2. иначе самая длинная из просто не соседних;
/// 3. иначе самая длинная из оставшихся.
///
/// [taken] — реплики, уже пробованные раньше: они не повторяются, и от них
/// новые тоже держатся подальше. Результат упорядочен по номерам реплик.
List<Cue> pickProbeCues(
  List<Cue> cues, {
  int count = 2,
  Iterable<Cue> taken = const [],
}) {
  if (cues.isEmpty || count <= 0) return const [];

  final takenIndices = {for (final cue in taken) cue.index};
  final pool = [
    for (final cue in cues)
      if (!takenIndices.contains(cue.index)) cue,
  ]..sort((a, b) {
      final byLength = b.range.duration.compareTo(a.range.duration);
      return byLength != 0 ? byLength : a.index.compareTo(b.index);
    });

  final span = cues.map((c) => c.range.end).reduce((a, b) => a > b ? a : b) -
      cues.map((c) => c.range.start).reduce((a, b) => a < b ? a : b);
  final minDistance = span / 4;
  double middle(Cue cue) => (cue.range.start + cue.range.end) / 2;

  final anchors = [...taken];
  final picked = <Cue>[];
  while (picked.length < count && pool.isNotEmpty) {
    bool notNeighbour(Cue cue) =>
        anchors.every((a) => (a.index - cue.index).abs() > 1);
    bool far(Cue cue) =>
        notNeighbour(cue) &&
        anchors.every((a) => (middle(a) - middle(cue)).abs() >= minDistance);

    final longest = pool.first.range.duration;
    final choice = pool.firstWhere(
      (c) => far(c) && c.range.duration >= longest / 2,
      orElse: () => pool.firstWhere(notNeighbour, orElse: () => pool.first),
    );
    picked.add(choice);
    anchors.add(choice);
    pool.remove(choice);
  }
  return picked..sort((a, b) => a.index.compareTo(b.index));
}
