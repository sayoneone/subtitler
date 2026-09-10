import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../core/logging.dart';

/// Где хранится ключ пользователя.
abstract class KeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();

  /// Короткое пояснение для интерфейса: пользователь должен понимать,
  /// где лежит его ключ.
  String get description;

  /// Проверка на старте: пробная запись и чтение. Про неработающее
  /// хранилище лучше узнать сразу, а не после ввода ключа.
  Future<bool> selfTest();
}

/// Системное защищённое хранилище: Credential Manager на Windows,
/// Keystore на Android. Это рабочий вариант для продукта.
class SecureKeyStore implements KeyStore {
  static const _name = 'yc_api_key';
  final DebugLog log;
  final _storage = const FlutterSecureStorage(
    // На macOS «защищённая» Связка требует entitlement и подписи с Team ID;
    // обычная работает без них.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  SecureKeyStore({DebugLog? log}) : log = log ?? DebugLog.instance;

  @override
  String get description => 'системное защищённое хранилище';

  @override
  Future<String?> read() =>
      _storage.read(key: _name).timeout(const Duration(seconds: 10));

  @override
  Future<void> write(String value) =>
      _storage.write(key: _name, value: value).timeout(const Duration(seconds: 20));

  @override
  Future<void> clear() => _storage.delete(key: _name);

  @override
  Future<bool> selfTest() async {
    try {
      await _storage
          .write(key: 'storage_probe', value: 'ok')
          .timeout(const Duration(seconds: 10));
      final back = await _storage.read(key: 'storage_probe');
      await _storage.delete(key: 'storage_probe');
      return back == 'ok';
    } catch (e) {
      log.warn('Защищённое хранилище недоступно: $e');
      return false;
    }
  }
}

/// Файл рядом с настройками приложения, права 600 — читать может только
/// владелец.
///
/// Так сделано только для macOS-стенда. Причина: приложение здесь
/// пересобирается по многу раз в день, у каждой сборки своя подпись, и
/// Связка ключей на каждую новую подпись спрашивает пароль. Для инструмента,
/// который запускают десятки раз, это невыносимо.
///
/// В продукте (Windows, Android) используется [SecureKeyStore]: там
/// приложение подписывается один раз и ставится один раз, никаких
/// повторных вопросов не будет, а ключ лежит зашифрованным.
class LocalFileKeyStore implements KeyStore {
  final String path;
  final DebugLog log;

  LocalFileKeyStore({required String supportDir, DebugLog? log})
      : path = p.join(supportDir, 'api_key'),
        log = log ?? DebugLog.instance;

  @override
  String get description => 'файл $path (права 600, без шифрования)';

  @override
  Future<String?> read() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final value = (await file.readAsString()).trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String value) async {
    final file = File(path);
    await file.writeAsString(value, flush: true);
    // Права выставляем после записи: создаётся файл с umask по умолчанию.
    await Process.run('chmod', ['600', path]);
  }

  @override
  Future<void> clear() async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<bool> selfTest() async {
    try {
      final probe = File('$path.probe');
      await probe.writeAsString('ok', flush: true);
      final back = await probe.readAsString();
      await probe.delete();
      return back == 'ok';
    } catch (e) {
      log.warn('Не удалось писать в папку приложения: $e');
      return false;
    }
  }
}

/// macOS — стенд разработчика, остальное — продукт.
KeyStore createKeyStore({required String supportDir, DebugLog? log}) =>
    Platform.isMacOS
        ? LocalFileKeyStore(supportDir: supportDir, log: log)
        : SecureKeyStore(log: log);
