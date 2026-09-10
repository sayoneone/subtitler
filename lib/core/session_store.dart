// lib/core/session_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// Читает и пишет `<имя>.subtitler.json`. Если папка с исходником недоступна
/// для записи (вещдок на защищённом носителе), файл уходит в [fallbackDir].
class SessionStore {
  final String fallbackDir;
  SessionStore({required this.fallbackDir});

  String sessionPathFor(String videoPath) => '$videoPath.subtitler.json';

  String fallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.json');

  /// Возвращает сессию, только если отпечаток совпал с [actual].
  Future<Session?> load(String videoPath, SourceFingerprint actual) async {
    for (final path in [sessionPathFor(videoPath), fallbackPathFor(videoPath)]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final session = Session.fromJson(json);
        if (session.schemaVersion != Session.currentSchemaVersion) continue;
        if (!session.fingerprint.matches(actual)) continue;
        return session;
      } on FormatException {
        continue; // битый файл — как будто сессии нет
      } on TypeError {
        continue;
      }
    }
    return null;
  }

  /// Пишет сессию и возвращает фактический путь.
  Future<String> save(Session session) async {
    final content = const JsonEncoder.withIndent(' ').convert(session.toJson());
    final primary = sessionPathFor(session.videoPath);
    try {
      await File(primary).writeAsString(content, flush: true);
      return primary;
    } on FileSystemException {
      final fallback = fallbackPathFor(session.videoPath);
      Directory(fallbackDir).createSync(recursive: true);
      await File(fallback).writeAsString(content, flush: true);
      return fallback;
    }
  }
}
