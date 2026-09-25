import 'dart:convert';

import '../core/cloud/speechkit_client.dart';
import '../core/cloud/translate_client.dart';
import '../core/logging.dart';
import 'user_error.dart';

enum CheckState { unknown, checking, ok, failed }

/// Итог проверки ключа: по индикатору на каждую роль (§4 спецификации) и
/// человеческое сообщение для той, что не прошла.
class KeyCheckResult {
  final CheckState translate;
  final CheckState stt;
  final UserError? translateError;
  final UserError? sttError;

  const KeyCheckResult({
    this.translate = CheckState.unknown,
    this.stt = CheckState.unknown,
    this.translateError,
    this.sttError,
  });

  static const KeyCheckResult idle = KeyCheckResult();

  bool get ok => translate == CheckState.ok && stt == CheckState.ok;
  bool get checking =>
      translate == CheckState.checking || stt == CheckState.checking;

  /// Первое сообщение об ошибке — для места, где помещается одно.
  UserError? get error => translateError ?? sttError;

  KeyCheckResult copyWith({
    CheckState? translate,
    CheckState? stt,
    UserError? translateError,
    UserError? sttError,
  }) =>
      KeyCheckResult(
        translate: translate ?? this.translate,
        stt: stt ?? this.stt,
        translateError: translateError ?? this.translateError,
        sttError: sttError ?? this.sttError,
      );
}

/// Полсекунды тишины в OggOpus (266 байт) — распознаванию нужен хоть
/// какой-то звук, а важен только HTTP-статус ответа. Раньше этот файл
/// каждый раз делал ffmpeg; вшитый в код он не зависит ни от ffmpeg, ни от
/// рабочей папки. Получен той же командой, что и прежде:
/// `ffmpeg -f lavfi -i anullsrc=r=48000:cl=mono:d=0.5 -c:a libopus
/// -b:a 64k -map_metadata -1 probe.ogg` (ffmpeg 9.0.1).
const String _probeOggBase64 =
    'T2dnUwACAAAAAAAAAACg7pqIAAAAAMmgBV8BE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAA'
    'AAAAAKDumogBAAAAR5xYGgE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAxAQAAABwAAABlbmNvZGVy'
    'PUxhdmM2My4xLjEwMSBsaWJvcHVzT2dnUwAE+F4AAAAAAACg7pqIAgAAAO482ygaAwMDAwMDAwMD'
    'AwMDAwMDAwMDAwMDAwMDAwP4//74//74//74//74//74//74//74//74//74//74//74//74//74'
    '//74//74//74//74//74//74//74//74//74//74//74//74//4=';

/// Пробный звук для проверки ключа.
List<int> get probeOgg => base64Decode(_probeOggBase64);

/// Проверяет ключ двумя микрозапросами: перевод одного слова и
/// распознавание полсекунды тишины. Ключ никуда не сохраняет — это дело
/// вызывающего, и только если обе проверки прошли.
class KeyChecker {
  final TranslateClient Function(String apiKey) translate;
  final SpeechKitClient Function(String apiKey) speechKit;
  final DebugLog log;

  /// Язык распознавания для пробы. Любой поддерживаемый: текст ответа не
  /// важен, только то, что сервис принял ключ.
  final String sttLang;

  KeyChecker({
    required this.translate,
    required this.speechKit,
    DebugLog? log,
    this.sttLang = 'tr-TR',
  }) : log = log ?? DebugLog.instance;

  /// [onProgress] получает промежуточные состояния: индикаторы в
  /// интерфейсе меняются по мере ответов, а не разом в конце.
  Future<KeyCheckResult> check(
    String apiKey, {
    void Function(KeyCheckResult)? onProgress,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      const empty = UserError(
        title: 'Ключ пустой',
        hint: 'Вставьте API-ключ сервисного аккаунта Яндекс Облака.',
      );
      return const KeyCheckResult(
        translate: CheckState.failed,
        stt: CheckState.failed,
        translateError: empty,
        sttError: empty,
      );
    }
    // Сразу: дальше ключ может оказаться в тексте любой ошибки.
    log.redact(key);
    log.info('Проверка ключа (${key.length} символов)');

    var result = const KeyCheckResult(
        translate: CheckState.checking, stt: CheckState.checking);
    onProgress?.call(result);

    // 1) Перевод — самая дешёвая проверка.
    try {
      final out = await translate(key)
          .translate(texts: const ['merhaba'], sourceLang: 'tr-TR');
      result = result.copyWith(translate: CheckState.ok);
      log.info('Перевод работает: merhaba → ${out.firstOrNull ?? ''}');
    } catch (e) {
      result = result.copyWith(
        translate: CheckState.failed,
        translateError: describeError(e, mask: log.mask),
      );
      log.error('Перевод недоступен: $e');
    }
    onProgress?.call(result);

    // 2) Распознавание.
    try {
      await speechKit(key).recognize(oggBytes: probeOgg, lang: sttLang);
      result = result.copyWith(stt: CheckState.ok);
      log.info('Распознавание отвечает');
    } catch (e) {
      result = result.copyWith(
        stt: CheckState.failed,
        sttError: describeError(e, mask: log.mask),
      );
      log.error('Распознавание недоступно: $e');
    }
    onProgress?.call(result);
    return result;
  }
}
