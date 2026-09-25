import 'dart:convert';
import 'dart:io';

import '../core/languages.dart';
import '../core/logging.dart';

/// Настройки, которые переживают перезапуск. Их немного, и все они —
/// выбор человека, а не состояние обработки.
class AppSettings {
  /// Языки, среди которых автоматически выбирается язык ролика
  /// («Языки ваших записей» в настройках). Порядок важен: при полном
  /// молчании моделей и без языка прошлой обработки берётся первый.
  final List<String> detectionCandidates;

  /// Язык прошлой обработки: его берём, если все модели промолчали.
  final String? lastLanguage;

  const AppSettings({
    this.detectionCandidates = kDefaultDetectionCandidates,
    this.lastLanguage,
  });

  AppSettings copyWith({
    List<String>? detectionCandidates,
    String? lastLanguage,
  }) =>
      AppSettings(
        detectionCandidates: detectionCandidates ?? this.detectionCandidates,
        lastLanguage: lastLanguage ?? this.lastLanguage,
      );

  Map<String, dynamic> toJson() => {
        'detectionCandidates': detectionCandidates,
        'lastLanguage': lastLanguage,
      };

  /// Читает настройки, прощая всё: неизвестные коды выбрасываются, пустой
  /// набор языков заменяется набором по умолчанию. Испорченный файл
  /// настроек не должен мешать работе.
  static AppSettings fromJson(Map<String, dynamic> json) {
    final raw = json['detectionCandidates'];
    final candidates = <String>[
      if (raw is List)
        for (final code in raw)
          if (code is String && languageByCode(code) != null) code,
    ];
    final last = json['lastLanguage'];
    return AppSettings(
      detectionCandidates: candidates.isEmpty
          ? kDefaultDetectionCandidates
          : List.unmodifiable(candidates.toSet()),
      lastLanguage:
          last is String && languageByCode(last) != null ? last : null,
    );
  }
}

/// Где лежат настройки.
abstract interface class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// Небольшой JSON-файл в папке приложения.
class FileSettingsStore implements SettingsStore {
  final String path;
  final DebugLog log;

  FileSettingsStore(this.path, {DebugLog? log})
      : log = log ?? DebugLog.instance;

  @override
  Future<AppSettings> load() async {
    final file = File(path);
    if (!file.existsSync()) return const AppSettings();
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) return AppSettings.fromJson(json);
      log.warn('Файл настроек испорчен ($path) — беру настройки по умолчанию');
    } on FormatException catch (e) {
      log.warn('Файл настроек испорчен ($path): $e — беру настройки по '
          'умолчанию');
    } on FileSystemException catch (e) {
      log.warn('Не удалось прочитать настройки ($path): $e');
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) async {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent(' ').convert(settings.toJson()),
          flush: true);
    } on FileSystemException catch (e) {
      // Настройка применится в этом запуске; при следующем — прежняя.
      log.warn('Не удалось сохранить настройки ($path): $e');
    }
  }
}
