class FfmpegResult {
  final int exitCode;
  final String log;
  const FfmpegResult({required this.exitCode, required this.log});
  bool get ok => exitCode == 0;
}

/// Единственная точка, где ядро зависит от того, как именно доступен ffmpeg:
/// внешним процессом на десктопе или библиотекой на Android.
abstract class FfmpegRunner {
  /// [onProgress] получает позицию обработки в секундах, если команда
  /// запущена с `-progress pipe:1`.
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  });

  Future<double> probeDuration(String path);
}

/// Раннер, который может остановить запущенные им ffmpeg.
///
/// На десктопе ffmpeg — отдельный процесс, и выход программы его не
/// останавливает: Dart не привязывает дочерние процессы к родителю. Без
/// остановки закрытое окно оставляло бы ffmpeg кодировать в фоне.
abstract interface class StoppableFfmpegRunner implements FfmpegRunner {
  /// Останавливает все запущенные этим раннером ffmpeg и ждёт, пока они
  /// завершатся. Каждый — по своему процессу (PID), а не по имени: у
  /// человека может работать и чужой ffmpeg. Новые команды после этого
  /// не запускаются: программа закрывается.
  Future<void> stopAll();
}
