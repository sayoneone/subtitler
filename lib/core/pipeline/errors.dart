/// Исключения конвейера, по которым интерфейс показывает человеку понятное
/// сообщение вместо сырого текста ошибки.
library;

/// Человек нажал «Отмена», а показать нечего — ни одной распознанной
/// реплики: так бывает при подготовке звука и определении языка нового
/// видео, а также при повторной нарезке сессии, в которой ещё ничего не
/// распознано.
///
/// Если распознанное уже есть — отмена во время распознавания, перевода
/// или повторной нарезки начатой сессии, — `Pipeline.process` исключения
/// не бросает, а возвращает частичный результат. Внутри конвейера это
/// исключение бросает и `withRetry`, когда отмена пришла в паузе между
/// повторами; там, где распознанное уже есть, конвейер его ловит.
class PipelineCancelledException implements Exception {
  const PipelineCancelledException();

  @override
  String toString() => 'Обработка отменена';
}

/// В видео нет звуковой дорожки — распознавать нечего.
class NoAudioStreamException implements Exception {
  const NoAudioStreamException();

  /// ffmpeg сообщает об этом при извлечении звука так:
  /// `Output file does not contain any stream` (в старых версиях —
  /// `Output file #0 does not contain any stream`).
  static bool matches(String ffmpegLog) =>
      ffmpegLog.contains('does not contain any stream');

  @override
  String toString() => 'В этом видео нет звука';
}

/// Звук в файле есть, но речи не нашлось нигде.
class NoSpeechFoundException implements Exception {
  const NoSpeechFoundException();

  @override
  String toString() => 'Речь в ролике не обнаружена';
}

/// Бросает [PipelineCancelledException], если [cancelled] говорит «да».
void throwIfCancelled(bool Function()? cancelled) {
  if (cancelled != null && cancelled()) throw const PipelineCancelledException();
}
