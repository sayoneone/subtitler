import 'dart:io';

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';

/// Яркость, выше которой пиксель считаем частью белого текста субтитров.
const int kSubtitleLumaThreshold = 200;

/// На столько должно вырасти число светлых пикселей в нижней полосе кадра,
/// чтобы считать субтитры отрисованными. Шум компрессии столько не даёт.
const int kSubtitleMinNewPixels = 300;

int countBrightPixels(List<int> grayBytes) =>
    grayBytes.where((b) => b > kSubtitleLumaThreshold).length;

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
    final before = await _brightPixels(original, atSeconds);
    final after = await _brightPixels(burned, atSeconds);
    return after - before >= kSubtitleMinNewPixels;
  }

  Future<int> _brightPixels(String video, double atSeconds) async {
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
      return countBrightPixels(File(bandPath).readAsBytesSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}
