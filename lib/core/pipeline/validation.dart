import '../models.dart';

enum TimingProblem { endBeforeStart, overlapsNext }

class TimingIssue {
  final int cueIndex;
  final TimingProblem problem;
  const TimingIssue(this.cueIndex, this.problem);
}

/// Проверяет тайминги после ручной правки: некорректный SRT лучше не собирать.
List<TimingIssue> validateTimings(List<Cue> cues) {
  final issues = <TimingIssue>[];
  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    if (cue.range.end <= cue.range.start) {
      issues.add(TimingIssue(cue.index, TimingProblem.endBeforeStart));
      continue;
    }
    if (i + 1 < cues.length && cue.range.end > cues[i + 1].range.start) {
      issues.add(TimingIssue(cue.index, TimingProblem.overlapsNext));
    }
  }
  return issues;
}

/// Ловит характерный сбой распознавания — зацикливание: одно и то же
/// слово подряд четыре раза и больше.
bool hasRepeatLoop(String text) {
  final tokens = text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((t) => t.isNotEmpty)
      .toList();
  var streak = 1;
  for (var i = 1; i < tokens.length; i++) {
    streak = tokens[i] == tokens[i - 1] ? streak + 1 : 1;
    if (streak >= 4) return true;
  }
  return false;
}

/// Проставляет пометки «стоит посмотреть человеку».
List<Cue> applyAutoFlags(List<Cue> cues) {
  return cues.map((cue) {
    final flags = <CueFlag>{...cue.flags};
    if (hasRepeatLoop(cue.orig)) flags.add(CueFlag.repeatLoop);
    if (cue.status == CueStatus.failed) flags.add(CueFlag.translateFailed);
    if (cue.orig.trim().isNotEmpty && cue.ru.trim().isEmpty) {
      flags.add(CueFlag.translateFailed);
    }
    return cue.copyWith(flags: flags);
  }).toList();
}
