import 'dart:io';
import 'dart:math' as math;

import '../ffmpeg/commands.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models.dart';

/// В какой момент проверять, что субтитры видны: середина реплики с самым
/// длинным переводом. Раньше бралась первая реплика, а она в разговоре
/// часто в одно слово («Алло?», «Да.») и даёт мало пикселей. null — если
/// вшивать нечего.
double? visibilityCheckPoint(List<Cue> cues) {
  Cue? best;
  for (final cue in cues) {
    final length = cue.ru.trim().length;
    if (length == 0) continue;
    if (best == null || length > best.ru.trim().length) best = cue;
  }
  if (best == null) return null;
  return (best.range.start + best.range.end) / 2;
}

/// Насколько должна сдвинуться яркость пикселя, чтобы считать, что его
/// изменили субтитры, а не шум перекодирования.
const int kSubtitlePixelDelta = 64;

/// Доля площади нижней полосы, которую должны изменить субтитры.
const double kSubtitleMinChangedFraction = 0.0005;

/// Нижняя граница порога: на маленьких кадрах доля выходит слишком мелкой.
///
/// Число пикселей текста растёт с высотой кадра, а этот предел — нет, так
/// что он должен пропускать короткую реплику на маленьком кадре: «А?» на
/// 320x240 изменяет около 28 пикселей. Без субтитров на тёмном, светлом,
/// пёстром, шумном, повёрнутом и сдвинутом ролике изменённых пикселей
/// намерено 0–3, так что 12 оставляет запас в обе стороны.
const int kSubtitleMinChangedPixelsFloor = 12;

/// Сколько секунд исходника по обе стороны от проверяемого момента
/// сравнивать с кадром вшитого ролика.
const double kSubtitleCheckWindow = 0.1;

/// Сколько пикселей изменили яркость сильнее, чем на [kSubtitlePixelDelta].
int countChangedPixels(List<int> before, List<int> after) {
  if (before.length != after.length) {
    throw StateError('Кадры разного размера: ${before.length} и '
        '${after.length} байт — сравнивать их нельзя');
  }
  var changed = 0;
  for (var i = 0; i < before.length; i++) {
    if ((after[i] - before[i]).abs() > kSubtitlePixelDelta) changed++;
  }
  return changed;
}

/// Сравнивает кадр вшитого ролика с каждым кадром окна исходника и берёт
/// лучшее совпадение.
///
/// Один и тот же момент в исходнике и в перекодированном файле бывает
/// соседними кадрами: кодировщик округляет начало видео до кадра, а у
/// телефонов частота кадров ещё и плавает. На движущейся картинке
/// сравнение «кадр с кадром» тогда видит тысячи изменённых пикселей там,
/// где субтитров нет. Подходящий кадр окна отличается от вшитого только
/// субтитрами, остальные — ещё и движением, поэтому берётся минимум.
/// Попиксельное «отличается от всех кадров окна» для этого не годится:
/// на движущемся фоне у пикселя текста почти всегда находится похожий
/// кадр, и видимые субтитры теряются.
int fewestChangedPixels(List<int> windowFrames, List<int> after) {
  final n = after.length;
  if (n == 0 || windowFrames.isEmpty || windowFrames.length % n != 0) {
    throw StateError('Окно исходника (${windowFrames.length} байт) не '
        'делится на кадры по $n байт — сравнивать их нельзя');
  }
  var fewest = n;
  for (var start = 0; start < windowFrames.length; start += n) {
    final changed =
        countChangedPixels(windowFrames.sublist(start, start + n), after);
    if (changed < fewest) fewest = changed;
  }
  return fewest;
}

/// Сколько пикселей нижней полосы должны измениться, чтобы поверить,
/// что субтитры отрисовались.
int subtitleMinChangedPixels(int bandPixels) => math.max(
      kSubtitleMinChangedPixelsFloor,
      (bandPixels * kSubtitleMinChangedFraction).round(),
    );

/// Итог проверки кадра — с числами, чтобы в журнале было видно, насколько
/// уверенно проверка ответила.
class VisibilityCheck {
  final double atSeconds;
  final int changedPixels;
  final int requiredPixels;

  const VisibilityCheck({
    required this.atSeconds,
    required this.changedPixels,
    required this.requiredPixels,
  });

  bool get visible => changedPixels >= requiredPixels;

  String describe() => 'кадр ${atSeconds.toStringAsFixed(2)} с: '
      'изменилось $changedPixels пикселей нижней полосы, '
      'нужно не меньше $requiredPixels';
}

class SubtitlesInvisibleException implements Exception {
  final VisibilityCheck check;
  const SubtitlesInvisibleException(this.check);

  String get message => 'Субтитры не отрисовались (${check.describe()})';

  @override
  String toString() => message;
}

/// ffmpeg не смог открыть выходной файл: ему нет доступа к папке.
///
/// Бывает, когда писать туда может сама программа, а ffmpeg — нет:
/// «Контролируемый доступ к папкам» разрешается отдельно для каждого exe,
/// и проба записи из subtitler.exe проходит, а ffmpeg.exe получает отказ.
/// Приложение тогда вшивает в запасную папку.
class OutputAccessDeniedException implements Exception {
  final String output;
  final String log;
  const OutputAccessDeniedException(this.output, this.log);

  @override
  String toString() => 'ffmpeg не может записать $output: нет доступа\n$log';
}

/// Так ffmpeg 9.0.1 сообщает, что выходной файл ему открыть не дали:
/// «Error opening output <путь>: Permission denied» и итоговая строка
/// «Error opening output files: Permission denied». Проверено на этой
/// машине запретом записи в папку (ACL) и файлом «только для чтения».
/// Отказ открыть ВХОДНОЙ файл пишется как «Error opening input…» и сюда
/// не относится.
final RegExp _outputAccessDenied =
    RegExp(r'Error opening output[^\n]*: Permission denied');

bool isOutputAccessDenied(String ffmpegLog) =>
    _outputAccessDenied.hasMatch(ffmpegLog);

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
      if (isOutputAccessDenied(result.log)) {
        throw OutputAccessDeniedException(output, result.log);
      }
      throw StateError('Не удалось вшить субтитры: ${result.log}');
    }
  }

  /// Вшивает и сразу проверяет результат. Это основной вход для приложения:
  /// «ffmpeg вернул 0» само по себе ничего не гарантирует.
  Future<VisibilityCheck> burnAndVerify({
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
    final check = await checkVisibility(
      original: input,
      burned: output,
      atSeconds: checkAtSeconds,
    );
    if (!check.visible) throw SubtitlesInvisibleException(check);
    return check;
  }

  Future<bool> subtitlesVisible({
    required String original,
    required String burned,
    required double atSeconds,
  }) async =>
      (await checkVisibility(
              original: original, burned: burned, atSeconds: atSeconds))
          .visible;

  /// Сравнивает нижнюю полосу кадра до и после вшивания.
  /// Нулевой код возврата ffmpeg здесь не показатель: libass без шрифта
  /// «успешно» рисует пустоту.
  ///
  /// Считаются пиксели, изменившиеся сильно в ЛЮБУЮ сторону. Раньше
  /// считался прирост светлых пикселей, и на светлом низу кадра проверка
  /// врала: белый текст там ничего не добавляет, а чёрная обводка гасит
  /// светлое — счётчик падал ниже нуля, хотя субтитры были видны.
  /// Шум перекодирования с -crf 18 сдвигает яркость слабо и порог не
  /// переходит (замерено на тёмном, светлом, пёстром и шумном кадре).
  ///
  /// Кадр вшитого ролика берётся один, а из исходника — все кадры в окне
  /// ±[kSubtitleCheckWindow] с, и засчитывается лучшее совпадение
  /// ([fewestChangedPixels]).
  Future<VisibilityCheck> checkVisibility({
    required String original,
    required String burned,
    required double atSeconds,
  }) async {
    final after = await _extract(
      burned,
      atSeconds,
      (output, exact) => FfmpegCommands.grayBand(
          input: burned,
          atSeconds: atSeconds,
          output: output,
          exactSeek: exact),
    );
    final from = math.max(0.0, atSeconds - kSubtitleCheckWindow);
    final window = await _extract(
      original,
      atSeconds,
      (output, exact) => FfmpegCommands.grayWindow(
          input: original,
          fromSeconds: from,
          durationSeconds: atSeconds + kSubtitleCheckWindow - from,
          output: output,
          exactSeek: exact),
    );
    return VisibilityCheck(
      atSeconds: atSeconds,
      changedPixels: fewestChangedPixels(window, after),
      requiredPixels: subtitleMinChangedPixels(after.length),
    );
  }

  /// Сначала быстро; если кадр не нашёлся — точно, декодированием с начала.
  /// Быструю перемотку в MPEG-TS с редкими ключевыми кадрами ffmpeg
  /// выполняет, не выдав ни одного кадра.
  Future<List<int>> _extract(String video, double atSeconds,
      List<String> Function(String output, bool exactSeek) command) async {
    for (final exact in [false, true]) {
      final bytes = await _runToBytes(video, command, exact);
      if (bytes.isNotEmpty) return bytes;
    }
    throw StateError('Не удалось получить кадр ${atSeconds.toStringAsFixed(2)} с '
        'из $video: ffmpeg не выдал ни одного кадра');
  }

  Future<List<int>> _runToBytes(String video,
      List<String> Function(String output, bool exactSeek) command,
      bool exactSeek) async {
    final dir = Directory.systemTemp.createTempSync('band_');
    try {
      final bandPath = '${dir.path}${Platform.pathSeparator}band.gray';
      final result = await runner.run(command(bandPath, exactSeek));
      if (!result.ok) {
        throw StateError('Не удалось получить кадр из $video: ${result.log}');
      }
      final band = File(bandPath);
      return band.existsSync() ? band.readAsBytesSync() : const <int>[];
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}
