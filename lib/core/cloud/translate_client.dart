import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_errors.dart';

/// Лимит одного запроса: считается по сумме длин всех строк батча.
const int kTranslateBatchCharLimit = 10000;

/// Узбекский в переводчике представлен двумя языками: `uz` — латиница,
/// `uzbcyr` — кириллица. Распознавание отдаёт узбекский латиницей,
/// поэтому здесь `uz`. Если текст реплики отредактируют кириллицей,
/// для неё понадобится `uzbcyr` — это задача редактора, не этого клиента.
const Map<String, String> _sttToTranslate = {'tr-TR': 'tr', 'uz-UZ': 'uz'};

/// Translate v2 принимает короткие коды языков, а не полные локали.
String toTranslateCode(String sttLang) {
  final code = _sttToTranslate[sttLang];
  if (code == null) {
    throw ArgumentError.value(sttLang, 'sttLang', 'Неизвестный язык распознавания');
  }
  return code;
}

List<List<String>> splitIntoBatches(List<String> texts) {
  final batches = <List<String>>[];
  var current = <String>[];
  var currentLength = 0;

  for (final text in texts) {
    if (current.isNotEmpty &&
        currentLength + text.length > kTranslateBatchCharLimit) {
      batches.add(current);
      current = <String>[];
      currentLength = 0;
    }
    current.add(text);
    currentLength += text.length;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}

class TranslateClient {
  final Dio dio;
  final String apiKey;
  final String baseUrl;

  TranslateClient({
    required this.dio,
    required this.apiKey,
    this.baseUrl = 'https://translate.api.cloud.yandex.net',
  });

  /// Переводит тексты на русский, сохраняя порядок.
  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLang,
  }) async {
    if (texts.isEmpty) return const [];
    final source = toTranslateCode(sourceLang);
    final result = <String>[];

    for (final batch in splitIntoBatches(texts)) {
      try {
        final response = await dio.post<dynamic>(
          '$baseUrl/translate/v2/translate',
          data: {
            'targetLanguageCode': 'ru',
            'sourceLanguageCode': source,
            'texts': batch,
          },
          options: Options(headers: {'Authorization': 'Api-Key $apiKey'}),
        );
        // Dio парсит тело в Map автоматически, только если сервер прислал
        // корректный Content-Type: application/json. Не все реализации его
        // выставляют, поэтому декодируем вручную, если пришла сырая строка.
        final raw = response.data;
        final Map<String, dynamic>? body = raw == null
            ? null
            : raw is String
                ? jsonDecode(raw) as Map<String, dynamic>
                : raw as Map<String, dynamic>;
        final translations = (body?['translations'] as List?) ?? const [];
        result.addAll(translations.map((t) => (t as Map)['text'] as String));
      } on DioException catch (e) {
        throw _mapError(e);
      }
    }
    return result;
  }

  ApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException(
        statusCode: status,
        message: status == 401
            ? 'Ключ неверный или отозван'
            : 'У ключа нет роли ai.translate.user',
      );
    }
    if (status == 429 || (status != null && status >= 500)) {
      return TransientException(
          statusCode: status, message: 'Сервис перевода недоступен');
    }
    if (status == null) {
      return const TransientException(message: 'Нет связи с сервисом перевода');
    }
    return ApiException(
        statusCode: status, message: 'Ошибка перевода (код $status)');
  }
}
