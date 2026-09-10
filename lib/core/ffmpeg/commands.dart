/// Экранирует значение внутри аргумента фильтра ffmpeg.
/// Порядок важен: сначала обратный слэш, иначе экранируем собственные вставки.
String escapeFilterArg(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll(':', r'\:')
    .replaceAll("'", r"\'");

class FfmpegCommands {
  static List<String> extractAudio({
    required String input,
    required String output,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-i', input,
        '-vn', '-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le',
        output,
      ];

  static List<String> detectSilence({
    required String input,
    required String noise,
    required double minDuration,
  }) =>
      [
        '-hide_banner', '-nostats',
        '-i', input,
        '-af', 'silencedetect=noise=$noise:d=$minDuration',
        '-f', 'null', '-',
      ];

  static List<String> cutSegment({
    required String input,
    required String output,
    required double start,
    required double end,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-i', input,
        '-ss', start.toStringAsFixed(2),
        '-to', end.toStringAsFixed(2),
        '-vn', '-ac', '1', '-c:a', 'libopus', '-b:a', '64k',
        output,
      ];

  static List<String> burnSubtitles({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
  }) {
    final filter = 'subtitles=${escapeFilterArg(srtPath)}'
        ':fontsdir=${escapeFilterArg(fontsDir)}'
        ":force_style='FontName=Noto Sans,Outline=2'";
    return [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-i', input,
      '-vf', filter,
      '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast',
      '-c:a', 'copy',
      '-movflags', '+faststart',
      '-progress', 'pipe:1',
      output,
    ];
  }

  /// Один кадр нижних 20 % экрана в виде сырых байт яркости —
  /// вход для проверки, что субтитры действительно нарисовались.
  /// Пишем в файл, а не в stdout: библиотечный раннер на Android
  /// не отдаёт поток вывода наружу.
  static List<String> grayBand({
    required String input,
    required double atSeconds,
    required String output,
  }) =>
      [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-ss', atSeconds.toStringAsFixed(2),
        '-i', input,
        '-vf', 'crop=iw:ih*0.2:0:ih*0.8,format=gray',
        '-frames:v', '1',
        '-f', 'rawvideo', output,
      ];
}
