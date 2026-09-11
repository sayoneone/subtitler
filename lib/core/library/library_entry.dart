// lib/core/library/library_entry.dart

/// Одна обработка в истории.
class LibraryEntry {
  final String id;
  final String sourceName;
  final DateTime createdAt;
  final String lang;
  final int cueCount;
  final int flaggedCount;

  /// Закреплённые записи автоматическая очистка не трогает никогда.
  final bool pinned;

  /// Видео удалено ради места, текст остался.
  final bool mediaRemoved;

  /// Сколько занимают исходник и результат вместе.
  final int mediaBytes;

  const LibraryEntry({
    required this.id,
    required this.sourceName,
    required this.createdAt,
    required this.lang,
    required this.cueCount,
    required this.flaggedCount,
    required this.pinned,
    required this.mediaRemoved,
    required this.mediaBytes,
  });

  LibraryEntry copyWith({
    bool? pinned,
    bool? mediaRemoved,
    int? mediaBytes,
    int? cueCount,
    int? flaggedCount,
  }) =>
      LibraryEntry(
        id: id,
        sourceName: sourceName,
        createdAt: createdAt,
        lang: lang,
        cueCount: cueCount ?? this.cueCount,
        flaggedCount: flaggedCount ?? this.flaggedCount,
        pinned: pinned ?? this.pinned,
        mediaRemoved: mediaRemoved ?? this.mediaRemoved,
        mediaBytes: mediaBytes ?? this.mediaBytes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceName': sourceName,
        'createdAt': createdAt.toIso8601String(),
        'lang': lang,
        'cueCount': cueCount,
        'flaggedCount': flaggedCount,
        'pinned': pinned,
        'mediaRemoved': mediaRemoved,
        'mediaBytes': mediaBytes,
      };

  static LibraryEntry fromJson(Map<String, dynamic> json) => LibraryEntry(
        id: json['id'] as String,
        sourceName: json['sourceName'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        lang: json['lang'] as String? ?? '',
        cueCount: json['cueCount'] as int? ?? 0,
        flaggedCount: json['flaggedCount'] as int? ?? 0,
        pinned: json['pinned'] as bool? ?? false,
        mediaRemoved: json['mediaRemoved'] as bool? ?? false,
        mediaBytes: json['mediaBytes'] as int? ?? 0,
      );
}

class LibraryIndex {
  static const int currentVersion = 1;
  final List<LibraryEntry> entries;

  const LibraryIndex({required this.entries});

  int get totalBytes =>
      entries.fold(0, (sum, e) => sum + (e.mediaRemoved ? 0 : e.mediaBytes));

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  static LibraryIndex fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    if (raw is! List) return const LibraryIndex(entries: []);
    return LibraryIndex(
      entries: raw
          .whereType<Map<String, dynamic>>()
          .map(LibraryEntry.fromJson)
          .toList(),
    );
  }
}
