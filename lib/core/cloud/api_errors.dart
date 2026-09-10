class ApiException implements Exception {
  final int? statusCode;
  final String message;
  const ApiException({this.statusCode, required this.message});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// 401/403 — ключ неверен или у сервисного аккаунта нет нужной роли.
/// Повторять бессмысленно: останавливаем весь прогон.
class AuthException extends ApiException {
  const AuthException({super.statusCode, required super.message});
}

/// 429/5xx/обрыв сети — имеет смысл повторить.
class TransientException extends ApiException {
  const TransientException({super.statusCode, required super.message});
}
