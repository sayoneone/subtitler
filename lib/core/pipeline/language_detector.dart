import 'dart:math' as math;

import '../models.dart';
import 'lexicon.dart';
import 'validation.dart';

export '../models.dart' show LanguageConfidence;

// ---------------------------------------------------------------------------
// Веса оценки. Подобраны вручную на выдуманных примерах и нарочно простые:
// оценка текста модели на её языке
//
//   S = own + 0.5·ownSuffix − foreign − 0.5·foreignSuffix + 0.2·relLength
//       − 0.3·[зацикливание] − штраф за однообразие,
//
// где own — доля слов из словаря своего языка, ownSuffix — доля слов вне
// словаря, но с характерным окончанием своего языка, foreign и
// foreignSuffix — то же для соседнего языка («чужие» слова, узнанные по
// скелету), relLength — длина текста относительно самой длинной версии той
// же реплики. Доли считаются по весам слов (см. kShortWordWeight).
// ---------------------------------------------------------------------------

const double kWeightOwn = 1.0;
const double kWeightOwnSuffix = 0.5;
const double kWeightForeign = 1.0;
const double kWeightForeignSuffix = 0.5;

/// Слабый признак: ловит модель, которая выбросила бо́льшую часть речи.
const double kWeightRelLength = 0.2;

/// Одно слово подряд четыре раза и больше — типичный сбой «чужой» модели.
const double kPenaltyRepeatLoop = 0.3;

/// Штраф за однообразие растёт линейно, когда разных слов меньше
/// [kMonotonyThreshold] от всех, и достигает [kPenaltyMonotony].
const double kPenaltyMonotony = 0.3;
const double kMonotonyThreshold = 0.6;

/// Вес одно- и двухбуквенных слов. «Чужая» модель охотно рассыпает
/// незнакомую речь на короткие служебные слова своего языка, поэтому
/// они значат меньше длинных.
const double kShortWordWeight = 0.4;

/// Оценка модели, которая ничего не услышала там, где другие услышали.
const double kSilentScore = -1;

// ---------------------------------------------------------------------------
// Пороги уверенности. ТРЕБУЮТ КАЛИБРОВКИ на реальных выводах SpeechKit:
// взяты с прототипа на выдуманных фразах. План калибровки — прогнать
// открытые записи (Common Voice, FLEURS) всеми моделями и подобрать пороги
// по сохранённым выводам.
// ---------------------------------------------------------------------------

/// Минимальный отрыв лидера от второго языка для уверенного выбора.
const double kHighConfidenceGap = 0.25;

/// Меньше слов — слишком мало данных, чтобы быть уверенным.
const int kHighConfidenceMinWords = 12;

/// Минимальная доля «своих» слов у лидера.
const double kHighConfidenceMinOwn = 0.3;

/// Признаки текста одной модели на одной реплике (или на склейке).
class LanguageFeatures {
  /// Число слов.
  final int words;

  /// Доли по весам слов, от 0 до 1.
  final double own;
  final double ownSuffix;
  final double foreign;
  final double foreignSuffix;

  /// Доля разных слов среди всех.
  final double distinctRatio;

  /// Длина относительно самой длинной версии той же реплики, от 0 до 1.
  final double relLength;

  final bool repeatLoop;

  const LanguageFeatures({
    required this.words,
    required this.own,
    required this.ownSuffix,
    required this.foreign,
    required this.foreignSuffix,
    required this.distinctRatio,
    required this.relLength,
    required this.repeatLoop,
  });

  static const LanguageFeatures silent = LanguageFeatures(
    words: 0,
    own: 0,
    ownSuffix: 0,
    foreign: 0,
    foreignSuffix: 0,
    distinctRatio: 0,
    relLength: 0,
    repeatLoop: false,
  );

  double get score {
    if (words == 0) return kSilentScore;
    var s = kWeightOwn * own +
        kWeightOwnSuffix * ownSuffix -
        kWeightForeign * foreign -
        kWeightForeignSuffix * foreignSuffix +
        kWeightRelLength * relLength;
    if (repeatLoop) s -= kPenaltyRepeatLoop;
    if (distinctRatio < kMonotonyThreshold) {
      s -= kPenaltyMonotony *
          (kMonotonyThreshold - distinctRatio) /
          kMonotonyThreshold;
    }
    return s;
  }
}

/// Признаки текста [text], который выдала модель языка [lang].
///
/// [against] — остальные проверяемые языки: слова, чей скелет есть только
/// в словаре одного из них, считаются «чужими». Общие слова соседних
/// языков (bir, bu, siz…) нейтральны. [maxLetters] — число букв в самой
/// длинной версии той же реплики; без него текст считается самым длинным.
LanguageFeatures languageFeatures(
  String text,
  String lang, {
  Iterable<String> against = const [],
  int? maxLetters,
}) {
  final tokens = tokenize(text);
  if (tokens.isEmpty) return LanguageFeatures.silent;

  final lexicon = lexiconFor(lang);
  final script = scriptOf(lang);
  final everyone = {lang, ...against};
  final rivals = [
    for (final other in everyone)
      if (other != lang &&
          scriptOf(other) == script &&
          lexiconFor(other) != null)
        other,
  ];
  final distinctive = [
    for (final rival in rivals) _distinctiveSkeletons(rival, everyone),
  ];

  var total = 0.0;
  var own = 0.0;
  var ownSuffix = 0.0;
  var foreign = 0.0;
  var foreignSuffix = 0.0;
  for (final word in tokens) {
    final weight = word.runes.length >= 3 ? 1.0 : kShortWordWeight;
    total += weight;
    if (lexicon != null && lexicon.words.contains(lexKey(word, lang))) {
      own += weight;
      continue;
    }
    final skel = skeleton(word);
    if (distinctive.any((set) => set.contains(skel))) {
      foreign += weight;
      continue;
    }
    if (lexicon != null && lexicon.hasSuffix(skel)) {
      ownSuffix += weight;
    } else if (rivals.any((rival) => lexiconFor(rival)!.hasSuffix(skel))) {
      foreignSuffix += weight;
    }
  }

  final letters = _letters(tokens);
  return LanguageFeatures(
    words: tokens.length,
    own: own / total,
    ownSuffix: ownSuffix / total,
    foreign: foreign / total,
    foreignSuffix: foreignSuffix / total,
    distinctRatio: tokens.toSet().length / tokens.length,
    relLength: maxLetters == null || maxLetters <= 0
        ? 1.0
        : math.min(1.0, letters / maxLetters),
    repeatLoop: hasRepeatLoop(text),
  );
}

/// Оценка одного текста без сравнения по репликам: сколько в нём слов
/// языка [lang] и сколько — соседних языков из [against].
double scoreLanguage(
  String text,
  String lang, {
  Iterable<String> against = const [],
}) =>
    languageFeatures(text, lang, against: against).score;

int _letters(List<String> tokens) =>
    tokens.fold(0, (sum, t) => sum + t.runes.length);

final Map<String, Set<String>> _distinctiveCache = {};

/// Скелеты, которые есть в словаре [lang] и нет ни у кого из [among].
Set<String> _distinctiveSkeletons(String lang, Set<String> among) {
  final key = '$lang|${(among.toList()..sort()).join(',')}';
  return _distinctiveCache.putIfAbsent(key, () {
    final result = {...lexiconFor(lang)!.skeletons};
    for (final other in among) {
      if (other == lang) continue;
      final lexicon = lexiconFor(other);
      if (lexicon != null) result.removeAll(lexicon.skeletons);
    }
    return result;
  });
}

/// Итог по одному языку.
class LanguageCandidate {
  final String lang;

  /// Что модель распознала на сравнённых репликах, через пробел.
  final String text;

  /// Средняя оценка по репликам, взвешенная по числу слов в реплике.
  final double score;

  /// Слов во всех сравнённых репликах.
  final int words;

  /// Доли своих и «чужих» слов, взвешенные так же, как [score].
  final double own;
  final double foreign;

  /// Сколько реплик этот язык выиграл.
  final int votes;

  /// Участвовал ли язык в сравнении. `false` — модель не ответила ни на
  /// одну из реплик, общих с остальными (ошибки сервиса), и её оценка
  /// ничего не значит.
  final bool compared;

  const LanguageCandidate({
    required this.lang,
    required this.text,
    required this.score,
    this.words = 0,
    this.own = 0,
    this.foreign = 0,
    this.votes = 0,
    this.compared = true,
  });
}

/// Решение о языке. Оно есть всегда: обработка ради выбора языка не
/// останавливается, а неуверенность передаётся дальше — в сессию и в
/// жёлтую плашку редактора.
class LanguageVerdict {
  /// Выбранный язык.
  final String lang;

  final LanguageConfidence confidence;

  /// Второй по оценке язык — его стоит предложить, если выбор неверен.
  /// При [LanguageConfidence.none] — первый из проверенных, кроме [lang].
  final String? runnerUp;

  /// Сравнённые языки по убыванию оценки, за ними — не участвовавшие.
  final List<LanguageCandidate> candidates;

  /// Номера реплик, по которым шло сравнение.
  final List<int> comparedCues;

  /// Реплики «проголосовали» за разные языки: возможно, в ролике говорят
  /// на двух языках.
  final bool mixed;

  const LanguageVerdict({
    required this.lang,
    required this.confidence,
    required this.runnerUp,
    required this.candidates,
    this.comparedCues = const [],
    this.mixed = false,
  });

  LanguageCandidate? candidateFor(String code) {
    for (final candidate in candidates) {
      if (candidate.lang == code) return candidate;
    }
    return null;
  }

  /// Отрыв лидера от второго языка.
  double get gap {
    final compared = candidates.where((c) => c.compared).toList();
    return compared.length < 2 ? 0 : compared[0].score - compared[1].score;
  }

  /// Одна строка для журнала: числа для калибровки порогов, без текстов.
  String describe() {
    final label = switch (confidence) {
      LanguageConfidence.high => 'уверенно',
      LanguageConfidence.low => 'неуверенно',
      LanguageConfidence.none => 'модели молчат',
    };
    final rows = candidates.map((c) => c.compared
        ? '${c.lang} ${c.score.toStringAsFixed(2)} (слов ${c.words}, '
            'свои ${c.own.toStringAsFixed(2)}, '
            'чужие ${c.foreign.toStringAsFixed(2)}, '
            'реплик выиграл ${c.votes})'
        : '${c.lang} — не сравнивался');
    return 'выбран $lang ($label); ${rows.join('; ')}; '
        'отрыв ${gap.toStringAsFixed(2)}; '
        'реплики ${comparedCues.isEmpty ? '—' : comparedCues.join(', ')}'
        '${mixed ? '; реплики разошлись — возможно, два языка' : ''}';
  }
}

/// Выбирает язык по пробным распознаваниям [probes]: язык → номер реплики
/// → текст. Никогда не «спрашивает человека».
///
/// Сравниваются только реплики, распознанные ВСЕМИ ответившими моделями:
/// если на одной из них сервис вернул ошибку, она выпадает из сравнения
/// целиком, а не у одной модели — иначе тексты разных моделей перестали бы
/// совпадать по репликам. Каждая реплика оценивается отдельно, итог — среднее,
/// взвешенное по числу слов.
///
/// [candidates] — порядок языков из настроек: он решает ничью и запасной
/// выбор (по умолчанию — порядок ключей [probes]). Если все модели молчат
/// ([LanguageConfidence.none]), выбирается [previousLang] — язык прошлой
/// обработки, — а без него первый из [candidates].
LanguageVerdict judgeLanguage(
  Map<String, Map<int, String>> probes, {
  List<String>? candidates,
  String? previousLang,
}) {
  final order = <String>[];
  for (final lang in candidates ?? probes.keys) {
    if (!order.contains(lang)) order.add(lang);
  }
  if (order.isEmpty) {
    throw ArgumentError('Не выбрано ни одного языка для определения');
  }
  Map<int, String> answersOf(String lang) => probes[lang] ?? const {};

  // Сравниваются только ответившие модели и только общие для них реплики.
  // Если общих реплик нет (модели спотыкались на разных), по одной
  // выбывает модель с наименьшим числом ответов.
  final participants = [
    for (final lang in order)
      if (answersOf(lang).isNotEmpty) lang,
  ];
  var common = _commonCues(participants, answersOf);
  while (participants.length > 1 && common.isEmpty) {
    participants.remove(participants.reduce((a, b) =>
        answersOf(b).length <= answersOf(a).length ? b : a));
    common = _commonCues(participants, answersOf);
  }

  final scoreSum = {for (final lang in participants) lang: 0.0};
  final ownSum = {for (final lang in participants) lang: 0.0};
  final foreignSum = {for (final lang in participants) lang: 0.0};
  final words = {for (final lang in participants) lang: 0};
  final texts = {for (final lang in participants) lang: <String>[]};
  final votes = <String, int>{};
  final compared = <int>[];
  var weightSum = 0.0;

  for (final cue in common) {
    final tokens = {
      for (final lang in participants) lang: tokenize(answersOf(lang)[cue]!),
    };
    final cueWords = tokens.values.map((t) => t.length).reduce(math.max);
    if (cueWords == 0) continue; // на этой реплике молчат все
    final maxLetters = tokens.values.map(_letters).reduce(math.max);

    final perCue = <LanguageCandidate>[];
    for (final lang in participants) {
      final text = answersOf(lang)[cue]!;
      final f = languageFeatures(text, lang,
          against: order, maxLetters: maxLetters);
      scoreSum[lang] = scoreSum[lang]! + f.score * cueWords;
      ownSum[lang] = ownSum[lang]! + f.own * cueWords;
      foreignSum[lang] = foreignSum[lang]! + f.foreign * cueWords;
      words[lang] = words[lang]! + f.words;
      if (text.trim().isNotEmpty) texts[lang]!.add(text.trim());
      perCue.add(LanguageCandidate(
          lang: lang, text: text, score: f.score, own: f.own, words: f.words));
    }
    perCue.sort((a, b) => _rank(a, b, order));
    votes[perCue.first.lang] = (votes[perCue.first.lang] ?? 0) + 1;
    weightSum += cueWords;
    compared.add(cue);
  }

  final dropped = [
    for (final lang in order)
      if (!participants.contains(lang))
        LanguageCandidate(
            lang: lang, text: '', score: kSilentScore, compared: false),
  ];

  if (weightSum == 0) {
    // Все модели промолчали: сравнивать нечего.
    final lang = previousLang ?? order.first;
    return LanguageVerdict(
      lang: lang,
      confidence: LanguageConfidence.none,
      runnerUp: order.where((l) => l != lang).firstOrNull,
      candidates: [
        for (final l in participants)
          LanguageCandidate(lang: l, text: '', score: kSilentScore),
        ...dropped,
      ],
    );
  }

  final ranked = [
    for (final lang in participants)
      LanguageCandidate(
        lang: lang,
        text: texts[lang]!.join(' '),
        score: scoreSum[lang]! / weightSum,
        words: words[lang]!,
        own: ownSum[lang]! / weightSum,
        foreign: foreignSum[lang]! / weightSum,
        votes: votes[lang] ?? 0,
      ),
  ]..sort((a, b) => _rank(a, b, order));

  final best = ranked.first;
  final mixed = votes.length > 1;
  final gap = ranked.length > 1 ? best.score - ranked[1].score : 0.0;
  final bool high;
  if (order.length == 1) {
    // Один язык — не выбор, а данность: сомневаться не в чем.
    high = true;
  } else {
    high = participants.length == order.length &&
        gap >= kHighConfidenceGap &&
        best.words >= kHighConfidenceMinWords &&
        best.own >= kHighConfidenceMinOwn &&
        !mixed;
  }

  final all = [...ranked, ...dropped];
  return LanguageVerdict(
    lang: best.lang,
    confidence: high ? LanguageConfidence.high : LanguageConfidence.low,
    runnerUp: all.length > 1 ? all[1].lang : null,
    candidates: all,
    comparedCues: compared,
    mixed: mixed,
  );
}

List<int> _commonCues(
  List<String> langs,
  Map<int, String> Function(String) answersOf,
) {
  if (langs.isEmpty) return const [];
  return answersOf(langs.first)
      .keys
      .where((cue) => langs.every((l) => answersOf(l).containsKey(cue)))
      .toList()
    ..sort();
}

/// Порядок вариантов: выше оценка; при равенстве — больше своих слов,
/// затем больше слов, затем раньше в настройках.
int _rank(LanguageCandidate a, LanguageCandidate b, List<String> order) {
  final byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  final byOwn = b.own.compareTo(a.own);
  if (byOwn != 0) return byOwn;
  final byWords = b.words.compareTo(a.words);
  if (byWords != 0) return byWords;
  return order.indexOf(a.lang).compareTo(order.indexOf(b.lang));
}
