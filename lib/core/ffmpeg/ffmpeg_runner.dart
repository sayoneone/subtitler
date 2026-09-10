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
