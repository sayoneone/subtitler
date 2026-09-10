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

  const Cue({
    required this.index,
    required this.range,
    required this.orig,
    required this.ru,
    required this.status,
    required this.flags,
  });

  Cue copyWith({
    int? index,
    TimeRange? range,
    String? orig,
    String? ru,
    CueStatus? status,
    Set<CueFlag>? flags,
  }) {
    return Cue(
      index: index ?? this.index,
      range: range ?? this.range,
      orig: orig ?? this.orig,
      ru: ru ?? this.ru,
      status: status ?? this.status,
      flags: flags ?? this.flags,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'range': range.toJson(),
        'orig': orig,
        'ru': ru,
        'status': status.name,
        'flags': flags.map((f) => f.name).toList(),
      };

  static Cue fromJson(Map<String, dynamic> json) => Cue(
        index: json['index'] as int,
        range: TimeRange.fromJson(json['range'] as Map<String, dynamic>),
        orig: json['orig'] as String,
        ru: json['ru'] as String,
        status: CueStatus.values.byName(json['status'] as String),
        flags: (json['flags'] as List)
            .map((n) => CueFlag.values.byName(n as String))
            .toSet(),
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

class Session {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String videoPath;
  final SourceFingerprint fingerprint;
  final String lang;
  final String silenceThreshold;
  final bool forcedSplit;
  final List<Cue> cues;

  const Session({
    this.schemaVersion = currentSchemaVersion,
    required this.videoPath,
    required this.fingerprint,
    required this.lang,
    required this.silenceThreshold,
    required this.forcedSplit,
    required this.cues,
  });

  Session copyWith({List<Cue>? cues, String? lang}) => Session(
        schemaVersion: schemaVersion,
        videoPath: videoPath,
        fingerprint: fingerprint,
        lang: lang ?? this.lang,
        silenceThreshold: silenceThreshold,
        forcedSplit: forcedSplit,
        cues: cues ?? this.cues,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'videoPath': videoPath,
        'fingerprint': fingerprint.toJson(),
        'lang': lang,
        'silenceThreshold': silenceThreshold,
        'forcedSplit': forcedSplit,
        'cues': cues.map((c) => c.toJson()).toList(),
      };

  static Session fromJson(Map<String, dynamic> json) => Session(
        schemaVersion: json['schemaVersion'] as int,
        videoPath: json['videoPath'] as String,
        fingerprint:
            SourceFingerprint.fromJson(json['fingerprint'] as Map<String, dynamic>),
        lang: json['lang'] as String,
        silenceThreshold: json['silenceThreshold'] as String,
        forcedSplit: json['forcedSplit'] as bool,
        cues: (json['cues'] as List)
            .map((c) => Cue.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}
