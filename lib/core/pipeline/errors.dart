/// Исключения конвейера, по которым интерфейс показывает человеку понятное
/// сообщение вместо сырого текста ошибки.
library;

/// Человек нажал «Отмена» раньше, чем появилось что показывать:
/// во время подготовки звука или определения языка.
///
/// Отмена во время распознавания исключением не считается —
/// `Pipeline.process` тогда возвращает частичный результат.
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
