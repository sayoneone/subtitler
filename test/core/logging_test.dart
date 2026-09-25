import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/core/ffmpeg/process_runner.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('log_test_');
    path = '${tmp.path}${Platform.pathSeparator}subtitler.log';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> runOnce(String message) async {
    final log = DebugLog()..attachFile(path);
    log.info(message);
    await log.close();
  }

  test('Журнал прошлого запуска не затирается новым', () async {
    // Человек при сбое первым делом перезапускает программу. Раньше новый
    // запуск перезаписывал subtitler.log, и журнал сбоя пропадал.
    await runOnce('запуск со сбоем');
    await runOnce('следующий запуск');

    final previous = File(DebugLog.previousPath(path)).readAsStringSync();
    final current = File(path).readAsStringSync();
    expect(previous, contains('запуск со сбоем'));
    expect(current, contains('следующий запуск'));
    expect(current, isNot(contains('запуск со сбоем')));
  });

  test('Хранятся только два запуска', () async {
    await runOnce('первый');
    await runOnce('второй');
    await runOnce('третий');

    final previous = File(DebugLog.previousPath(path)).readAsStringSync();
    expect(previous, contains('второй'));
    expect(previous, isNot(contains('первый')));
    expect(File(path).readAsStringSync(), contains('третий'));
  });

  group('Папка видео в журнал не попадает', () {
    test('вместо папки «…», имя файла остаётся — и в памяти, и в файле',
        () async {
      final log = DebugLog()..attachFile(path);
      final video = p.join(tmp.path, 'Дела', 'Дело №7 (тест)', 'clip.mp4');
      log.hideFolderOf(video);
      log.info('Выбрано видео: $video');
      log.error('ffmpeg ✘ код 1\n'
          "Input #0, mov,mp4, from '$video':\n"
          '${video.replaceAll(r'\', '/')}: Invalid data');
      await log.close();

      for (final text in [log.asText(), File(path).readAsStringSync()]) {
        expect(text, isNot(contains('Дело №7')));
        expect(text, contains(p.join('…', 'clip.mp4')));
      }
    });

    test('вложенная папка прячется целиком, а не по родительской', () {
      final log = DebugLog();
      final outer = p.join(tmp.path, 'Дела', 'clip.mp4');
      final inner = p.join(tmp.path, 'Дела', 'Дело №7', 'clip.mp4');
      log
        ..hideFolderOf(outer)
        ..hideFolderOf(inner);
      expect(log.mask(inner), p.join('…', 'clip.mp4'));
    });

    test('корень диска не прячется — иначе исчезли бы все пути', () {
      final log = DebugLog();
      final root = p.rootPrefix(tmp.path);
      log.hideFolderOf(p.join(root, 'clip.mp4'));
      expect(log.mask(path), path);
    });

    test('ключ по-прежнему замаскирован', () {
      final log = DebugLog();
      const key = 'AQVN-vydumannyj-testovyj-klyuch-0001';
      log
        ..redact(key)
        ..hideFolderOf(p.join(tmp.path, 'Дело', 'clip.mp4'));
      log.warn('ключ $key, папка ${p.join(tmp.path, 'Дело')}');
      expect(log.asText(), contains('***КЛЮЧ***'));
      expect(log.asText(), isNot(contains(key)));
      expect(log.asText(), isNot(contains('Дело')));
    });

    test('вывод настоящего ffmpeg тоже проходит через маску', () async {
      final log = DebugLog();
      final missing = p.join(tmp.path, 'Дело №7 (тест)', 'нет такого.mp4');
      log.hideFolderOf(missing);
      final ffmpeg = ProcessFfmpegRunner(
        ffmpegPath: ProcessFfmpegRunner.fromEnvironment().ffmpegPath,
        log: log,
      );
      final result = await ffmpeg.run(['-hide_banner', '-i', missing]);
      expect(result.ok, isFalse);
      expect(result.log, contains('Дело №7'),
          reason: 'ffmpeg правда печатает путь — маска журнала его прячет');
      expect(log.asText(), contains('нет такого.mp4'));
      expect(log.asText(), isNot(contains('Дело №7')));
    });
  });

  test('Имя файла прошлого запуска стоит рядом с текущим', () {
    expect(DebugLog.previousPath(r'C:\app\subtitler.log'),
        r'C:\app\subtitler.prev.log');
    expect(DebugLog.previousPath('/tmp/journal'), '/tmp/journal.prev');
  });
}
