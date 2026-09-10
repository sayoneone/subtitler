import 'dart:io';

import 'package:dio/dio.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/pipeline/burner.dart';
import 'package:subtitler/core/pipeline/pipeline.dart';
import 'package:subtitler/core/session_store.dart';
import 'package:subtitler/core/srt.dart';

/// Отладочный запуск ядра без интерфейса:
///   YC_API_KEY=... dart run tool/pipeline_cli.dart video.mp4 --lang tr-TR
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Использование: pipeline_cli <видео> --lang tr-TR|uz-UZ');
    exit(2);
  }

  final videoPath = args.first;
  if (!File(videoPath).existsSync()) {
    stderr.writeln('Файл не найден: $videoPath');
    exit(2);
  }

  final langIndex = args.indexOf('--lang');
  final lang =
      langIndex >= 0 && langIndex + 1 < args.length ? args[langIndex + 1] : 'tr-TR';
  if (!kSupportedSttLangs.contains(lang)) {
    stderr.writeln('Язык $lang не поддерживается. Доступны: $kSupportedSttLangs');
    exit(2);
  }

  final apiKey = Platform.environment['YC_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Не задан YC_API_KEY');
    exit(2);
  }

  final dio = Dio();
  final runner = ProcessFfmpegRunner.fromEnvironment();
  final workDir = Directory.systemTemp.createTempSync('subtitler_cli_').path;

  final pipeline = Pipeline(
    runner: runner,
    stt: SpeechKitClient(dio: dio, apiKey: apiKey),
    translate: TranslateClient(dio: dio, apiKey: apiKey),
    store: SessionStore(fallbackDir: workDir),
    workDir: workDir,
  );

  final session = await pipeline.process(
    videoPath: videoPath,
    lang: lang,
    onProgress: (p) => stdout.writeln(
        '${p.stage.name}${p.total > 0 ? ' ${p.done}/${p.total}' : ''}'),
  );

  final base = videoPath.replaceAll(RegExp(r'\.[^.]+$'), '');
  final ruSrtPath = '${base}_ru.srt';
  File('${base}_orig.srt')
      .writeAsStringSync(buildSrt(session.cues, field: SrtField.orig));
  File(ruSrtPath).writeAsStringSync(buildSrt(session.cues, field: SrtField.ru));

  final flagged = session.cues.where((c) => c.flags.isNotEmpty).length;
  stdout
    ..writeln('Порог тишины: ${session.silenceThreshold}'
        '${session.forcedSplit ? ' (пауз не нашлось, нарезка принудительная)' : ''}')
    ..writeln('Реплик: ${session.cues.length}, на проверку: $flagged')
    ..writeln('Субтитры: ${base}_orig.srt и $ruSrtPath');

  if (!_hasSubtitlesFilter(runner)) {
    stderr.writeln(
        'Вшивание пропущено: ffmpeg в PATH собран без libass, фильтра '
        'subtitles в нём нет. Субтитры выше готовы; чтобы вшить их, укажите '
        'сборку с libass через переменную $kFfmpegPathEnv или соберите '
        'на Windows/Android, где libass есть в комплекте.');
    exit(3);
  }

  final firstVisible = session.cues.firstWhere(
    (c) => c.ru.trim().isNotEmpty,
    orElse: () => session.cues.first,
  );
  final output = '${base}_ru.mp4';

  try {
    await SubtitleBurner(runner).burnAndVerify(
      input: videoPath,
      srtPath: ruSrtPath,
      fontsDir: 'assets/fonts',
      output: output,
      checkAtSeconds: (firstVisible.range.start + firstVisible.range.end) / 2,
    );
  } on SubtitlesInvisibleException catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  stdout.writeln('Готово: $output (субтитры в кадре видны)');
}

bool _hasSubtitlesFilter(ProcessFfmpegRunner runner) {
  final result = Process.runSync(runner.ffmpegPath, ['-hide_banner', '-filters']);
  return RegExp(r'\bsubtitles\b').hasMatch(result.stdout as String);
}
