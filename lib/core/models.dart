/// Отрезок времени в секундах от начала видео.
class TimeRange {
  final double start;
  final double end;
  const TimeRange(this.start, this.end);

  double get duration => end - start;

  Map<String, dynamic> toJson() => {'start': start, 'end': end};

  static TimeRange fromJson(Map<String, dynamic> json) =>
      TimeRange((json['start'] as num).toDouble(), (json['end'] as num).toDouble());
}

/// Что уже известно о реплике. От статуса зависит, пойдёт ли она в платный API
/// при возобновлении сессии.
enum CueStatus { pending, ok, empty, failed }

/// Пометки, из-за которых реплику стоит показать человеку.
enum CueFlag { repeatLoop, translateFailed, forcedSplit }

class Cue {
  final int index;
  final TimeRange range;
  final String orig;
  final String ru;
  final CueStatus status;
  final Set<CueFlag> flags;

  /// Перевод правил человек. Пустой [ru] у такой реплики — его решение
  /// («этой строки в видео не будет»), а не «перевод ещё не получен»:
  /// заново она не переводится.
  final bool edited;

  const Cue({
    required this.index,
    required this.range,
    required this.orig,
    required this.ru,
    required this.status,
    required this.flags,
    this.edited = false,
  });

  /// Перевод ещё предстоит получить: текст распознан, перевода нет, и
  /// человек его не стирал. Пустой оригинал переводить нечего.
  bool get awaitsTranslation =>
      status == CueStatus.ok &&
      ru.trim().isEmpty &&
      orig.trim().isNotEmpty &&
      !edited;

  Cue copyWith({
    int? index,
    TimeRange? range,
    String? orig,
    String? ru,
    CueStatus? status,
    Set<CueFlag>? flags,
    bool? edited,
  }) {
    return Cue(
      index: index ?? this.index,
      range: range ?? this.range,
      orig: orig ?? this.orig,
      ru: ru ?? this.ru,
      status: status ?? this.status,
      flags: flags ?? this.flags,
      edited: edited ?? this.edited,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'range': range.toJson(),
        'orig': orig,
        'ru': ru,
        'status': status.name,
        'flags': flags.map((f) => f.name).toList(),
        if (edited) 'edited': true,
      };

  /// Поля `edited` у сессий, записанных до него, нет — значит, `false`.
  /// Поле необязательное, поэтому схема сессии из-за него не меняется:
  /// прежние версии программы такую сессию прочитают, просто без него.
  static Cue fromJson(Map<String, dynamic> json) => Cue(
        index: json['index'] as int,
        range: TimeRange.fromJson(json['range'] as Map<String, dynamic>),
        orig: json['orig'] as String,
        ru: json['ru'] as String,
        status: CueStatus.values.byName(json['status'] as String),
        flags: (json['flags'] as List)
            .map((n) => CueFlag.values.byName(n as String))
            .toSet(),
        edited: json['edited'] as bool? ?? false,
      );
}

/// Лёгкий отпечаток исходного файла: защищает от подстановки чужой сессии
/// другому видео с тем же именем.
class SourceFingerprint {
  final int sizeBytes;
  final double durationSec;

  const SourceFingerprint({required this.sizeBytes, required this.durationSec});

  bool matches(SourceFingerprint other) =>
      sizeBytes == other.sizeBytes &&
      (durationSec - other.durationSec).abs() < 0.01;

  Map<String, dynamic> toJson() =>
      {'sizeBytes': sizeBytes, 'durationSec': durationSec};

  static SourceFingerprint fromJson(Map<String, dynamic> json) =>
      SourceFingerprint(
        sizeBytes: json['sizeBytes'] as int,
        durationSec: (json['durationSec'] as num).toDouble(),
      );
}

/// Насколько автомат уверен в выбранном языке.
enum LanguageConfidence {
  /// Язык уверенно впереди — жёлтой плашки сомнения нет, остаётся только
  /// меню «Не тот язык?».
  high,

  /// Выбран лучший вариант, но отрыв мал, слов мало или реплики
  /// «проголосовали» по-разному. Обработка всё равно идёт дальше,
  /// а в редакторе показывается жёлтая плашка со вторым языком.
  low,

  /// Все модели промолчали: сравнивать было нечего, язык взят
  /// из прошлой обработки или первый из настроек.
  none,
}

class Session {
  /// 2 — добавлены [langConfidence], [langRunnerUp] и [probeTexts].
  /// `Cue.edited` появился без смены схемы: поле необязательное, и
  /// сессии схем 1 и 2 без него читаются как «правок не было».
  static const int currentSchemaVersion = 2;

  final int schemaVersion;
  final String videoPath;
  final SourceFingerprint fingerprint;
  final String lang;

  /// Уверенность автоматического выбора языка. `null` — язык выбрал
  /// человек (сменил его в редакторе) или сессия записана версией,
  /// которая этого ещё не хранила: сомневаться тогда не в чем.
  final LanguageConfidence? langConfidence;

  /// Второй по оценке язык — его меню «Не тот язык?» предлагает первым.
  final String? langRunnerUp;

  /// Пробные распознавания ВСЕХ проверенных языков: язык → номер
  /// реплики → текст. За них уже заплачено, поэтому при смене языка
  /// эти реплики повторно не распознаются.
  final Map<String, Map<int, String>> probeTexts;

  final String silenceThreshold;
  final bool forcedSplit;
  final List<Cue> cues;

  const Session({
    this.schemaVersion = currentSchemaVersion,
    required this.videoPath,
    required this.fingerprint,
    required this.lang,
    this.langConfidence,
    this.langRunnerUp,
    this.probeTexts = const {},
    required this.silenceThreshold,
    required this.forcedSplit,
    required this.cues,
  });

  /// [langConfidence] и [langRunnerUp] можно сбросить в `null`, передав
  /// `null` явно; не переданные поля остаются как были.
  ///
  /// [videoPath] меняется, когда сессию открыли по другому пути, чем
  /// записали: папку дела скопировали, флешка получила другую букву.
  Session copyWith({
    String? videoPath,
    List<Cue>? cues,
    String? lang,
    Object? langConfidence = _keep,
    Object? langRunnerUp = _keep,
    Map<String, Map<int, String>>? probeTexts,
    String? silenceThreshold,
    bool? forcedSplit,
  }) =>
      Session(
        schemaVersion: schemaVersion,
        videoPath: videoPath ?? this.videoPath,
        fingerprint: fingerprint,
        lang: lang ?? this.lang,
        langConfidence: identical(langConfidence, _keep)
            ? this.langConfidence
            : langConfidence as LanguageConfidence?,
        langRunnerUp: identical(langRunnerUp, _keep)
            ? this.langRunnerUp
            : langRunnerUp as String?,
        probeTexts: probeTexts ?? this.probeTexts,
        silenceThreshold: silenceThreshold ?? this.silenceThreshold,
        forcedSplit: forcedSplit ?? this.forcedSplit,
        cues: cues ?? this.cues,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'videoPath': videoPath,
        'fingerprint': fingerprint.toJson(),
        'lang': lang,
        'langConfidence': langConfidence?.name,
        'langRunnerUp': langRunnerUp,
        // Ключи JSON — только строки, поэтому номер реплики пишется строкой.
        'probeTexts': {
          for (final entry in probeTexts.entries)
            entry.key: {
              for (final text in entry.value.entries) '${text.key}': text.value,
            },
        },
        'silenceThreshold': silenceThreshold,
        'forcedSplit': forcedSplit,
        'cues': cues.map((c) => c.toJson()).toList(),
      };

  /// Читает сессию текущей схемы и всех прежних.
  ///
  /// Сессия прежней схемы поднимается до текущей: недостающие поля получают
  /// значения по умолчанию. Отказываться от неё нельзя — иначе после
  /// обновления приложения каждый уже обработанный ролик пришлось бы
  /// оплачивать заново. Схему новее текущей не угадываем: [FormatException].
  static Session fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int;
    if (version < 1 || version > currentSchemaVersion) {
      throw FormatException('Неизвестная версия схемы сессии: $version');
    }
    // Схема 1 не знала про уверенность и пробы: поля отсутствуют,
    // и ниже они получают значения «язык выбран человеком, проб нет».
    return Session(
      videoPath: json['videoPath'] as String,
      fingerprint:
          SourceFingerprint.fromJson(json['fingerprint'] as Map<String, dynamic>),
      lang: json['lang'] as String,
      langConfidence: LanguageConfidence.values
          .asNameMap()[json['langConfidence'] as String?],
      langRunnerUp: json['langRunnerUp'] as String?,
      probeTexts: _probeTextsFromJson(json['probeTexts']),
      silenceThreshold: json['silenceThreshold'] as String,
      forcedSplit: json['forcedSplit'] as bool,
      cues: (json['cues'] as List)
          .map((c) => Cue.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }

  static Map<String, Map<int, String>> _probeTextsFromJson(Object? raw) {
    if (raw == null) return const {};
    return {
      for (final entry in (raw as Map<String, dynamic>).entries)
        entry.key: {
          for (final text in (entry.value as Map<String, dynamic>).entries)
            int.parse(text.key): text.value as String,
        },
    };
  }
}

/// Метка «поле не передано» для [Session.copyWith]: отличает её от
/// явного `null`, которым поле сбрасывается.
const Object _keep = Object();
