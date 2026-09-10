import 'package:dio/dio.dart';

import 'api_errors.dart';

/// Языки, которые приложение отправляет в распознавание. Язык всегда задаётся
/// явно: автоопределение для узбекского даёт молчаливые ошибки.
const List<String> kSupportedSttLangs = ['tr-TR', 'uz-UZ'];

class SpeechKitClient {
  final Dio dio;
  final String apiKey;
  final String baseUrl;

  SpeechKitClient({
    required this.dio,
    required this.apiKey,
    this.baseUrl = 'https://stt.api.cloud.yandex.net',
  });

  /// Распознаёт один сегмент. Пустая строка означает «речи не найдено».
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    if (!kSupportedSttLangs.contains(lang)) {
      throw ArgumentError.value(lang, 'lang', 'Поддерживаются $kSupportedSttLangs');
    }

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '$baseUrl/speech/v1/stt:recognize',
        queryParameters: {
          'topic': 'general',
          'format': 'oggopus',
          'lang': lang,
        },
        data: Stream.fromIterable([oggBytes]),
        options: Options(
          headers: {
            'Authorization': 'Api-Key $apiKey',
            Headers.contentLengthHeader: oggBytes.length,
          },
          responseType: ResponseType.json,
        ),
      );
      return (response.data?['result'] as String?) ?? '';
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  ApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException(
        statusCode: status,
        message: status == 401
            ? 'Ключ неверный или отозван'
            : 'У ключа нет роли ai.speechkit-stt.user',
      );
    }
    if (status == 429 || (status != null && status >= 500)) {
      return TransientException(
          statusCode: status, message: 'Сервис распознавания недоступен');
    }
    if (status == null) {
      return const TransientException(message: 'Нет связи с сервисом распознавания');
    }
    return ApiException(
        statusCode: status, message: 'Ошибка распознавания (код $status)');
  }
}
