import 'dart:io';
import 'dart:math' as math;

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';

/// Яркость, выше которой пиксель считаем частью белого текста субтитров.
const int kSubtitleLumaThreshold = 200;

/// Доля площади нижней полосы, которую должен занять появившийся текст.
const double kSubtitleMinNewFraction = 0.0015;

/// Нижняя граница порога: на маленьких кадрах доля выходит слишком мелкой.
const int kSubtitleMinNewPixelsFloor = 120;

int countBrightPixels(List<int> grayBytes) =>
    grayBytes.where((b) => b > kSubtitleLumaThreshold).length;

/// Насколько должно вырасти число светлых пикселей, чтобы поверить,
/// что субтитры отрисовались.
///
/// Пороги замерены на этой сборке (2026-09-11, ffmpeg 9.0.1 + libass 0.17.5):
/// перекодирование ЯРКОГО ролика 848x480 без субтитров сдвигает счётчик
/// примерно на 60 пикселей в любую сторону — это шум компрессии;
/// одна реальная реплика на таком же кадре добавляет около 1100.
/// Порог берём долей от площади полосы, чтобы он не терял смысл на кадрах
/// другого размера, где шум растёт вместе с площадью.
int subtitleMinNewPixels(int bandPixels) => math.max(
      kSubtitleMinNewPixelsFloor,
      (bandPixels * kSubtitleMinNewFraction).round(),
    );

class SubtitlesInvisibleException implements Exception {
  final String message;
  const SubtitlesInvisibleException(this.message);
  @override
  String toString() => message;
}

class SubtitleBurner {
  final FfmpegRunner runner;
  SubtitleBurner(this.runner);

  Future<void> burn({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
    void Function(double seconds)? onProgress,
  }) async {
    final result = await runner.run(
      FfmpegCommands.burnSubtitles(
        input: input,
        srtPath: srtPath,
        fontsDir: fontsDir,
        output: output,
      ),
      onProgress: onProgress,
    );
    if (!result.ok) {
      throw StateError('Не удалось вшить субтитры: ${result.log}');
    }
  }

  /// Вшивает и сразу проверяет результат. Это основной вход для приложения:
  /// «ffmpeg вернул 0» само по себе ничего не гарантирует.
  Future<void> burnAndVerify({
    required String input,
    required String srtPath,
    required String fontsDir,
    required String output,
    required double checkAtSeconds,
    void Function(double seconds)? onProgress,
  }) async {
    await burn(
      input: input,
      srtPath: srtPath,
      fontsDir: fontsDir,
      output: output,
      onProgress: onProgress,
    );
    final visible = await subtitlesVisible(
      original: input,
      burned: output,
      atSeconds: checkAtSeconds,
    );
    if (!visible) {
      throw const SubtitlesInvisibleException(
          'Субтитры не отрисовались: проверьте, что шрифт зарегистрирован');
    }
  }

  /// Сравнивает нижнюю полосу кадра до и после вшивания.
  /// Ненулевой код возврата ffmpeg здесь не показатель: libass без шрифта
  /// «успешно» рисует пустоту.
  Future<bool> subtitlesVisible({
    required String original,
    required String burned,
    required double atSeconds,
  }) async {
    final before = await _grayBand(original, atSeconds);
    final after = await _grayBand(burned, atSeconds);
    final grew = countBrightPixels(after) - countBrightPixels(before);
    return grew >= subtitleMinNewPixels(after.length);
  }

  Future<List<int>> _grayBand(String video, double atSeconds) async {
    final dir = Directory.systemTemp.createTempSync('band_');
    try {
      final bandPath = '${dir.path}${Platform.pathSeparator}band.gray';
      final result = await runner.run(FfmpegCommands.grayBand(
        input: video,
        atSeconds: atSeconds,
        output: bandPath,
      ));
      if (!result.ok) {
        throw StateError('Не удалось получить кадр из $video: ${result.log}');
      }
      return File(bandPath).readAsBytesSync();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}
