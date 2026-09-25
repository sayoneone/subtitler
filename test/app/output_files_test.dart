import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/output_files.dart';
import 'package:subtitler/app/runtime.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/models.dart';

import '../support/file_access.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('output_files_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const cues = [
    Cue(
      index: 1,
      range: TimeRange(0, 2),
      orig: 'yarın sabah erkenden çarşıya gideceğiz',
      ru: 'завтра рано утром пойдём на рынок',
      status: CueStatus.ok,
      flags: {},
    ),
  ];

  group('Имена', () {
    test('рядом с видео: _ru.mp4, _orig.srt, _ru.srt и временный .partial', () {
      final names = outputNamesBeside(p.join('дело 5', 'запись.звонка.mp4'));
      expect(names.dir, 'дело 5');
      expect(p.basename(names.video), 'запись.звонка_ru.mp4');
      expect(p.basename(names.partialVideo), 'запись.звонка_ru.partial.mp4');
      expect(p.basename(names.origSrt), 'запись.звонка_orig.srt');
      expect(p.basename(names.ruSrt), 'запись.звонка_ru.srt');
    });

    test('запасная папка своя у каждого видео, даже с одинаковыми именами', () {
      final a = outputNamesInFallback(p.join('дело 1', 'VID_0001.mp4'), 'out');
      final b = outputNamesInFallback(p.join('дело 2', 'VID_0001.mp4'), 'out');
      expect(a.dir, isNot(b.dir));
      expect(p.dirname(a.dir), 'out');
      expect(p.basename(a.video), 'VID_0001_ru.mp4',
          reason: 'имена файлов те же, что рядом с видео');
      // Имя папки не зависит от запуска: повторное сохранение попадает туда же.
      expect(
          outputNamesInFallback(p.join('дело 1', 'VID_0001.mp4'), 'out').dir,
          a.dir);
    });

    test('имя запасной папки — стабильный хеш пути (FNV-1a)', () {
      // Эталоны посчитаны заранее отдельной программой. С String.hashCode
      // после обновления Dart результат того же видео лёг бы в новую папку.
      expect(
          p.basename(
              outputNamesInFallback('/дела/дело 12/VID_0001.mp4', 'out').dir),
          'VID_0001_56ea54bf');
      expect(
          p.basename(
              outputNamesInFallback('/дела/дело 13/VID_0001.mp4', 'out').dir),
          'VID_0001_08b08d3a');
    });

    test('стабильный хеш пути не меняется между версиями', () {
      // Эталон FNV-1a: если значение поменяется, после обновления
      // приложения уже нарезанное придётся резать заново.
      expect(stablePathHash(''), '811c9dc5');
      expect(stablePathHash('a'), 'e40c292c');
    });
  });

  group('Субтитры', () {
    test('пишутся рядом с видео', () async {
      final video = p.join(tmp.path, 'clip.mp4');
      File(video).writeAsStringSync('видео');
      final files = OutputFiles(
          videoPath: video, fallbackRoot: p.join(tmp.path, 'out'), log: DebugLog());
      final written = await files.writeSrts(cues);
      expect(written.inFallback, isFalse);
      expect(File(p.join(tmp.path, 'clip_ru.srt')).readAsStringSync(),
          contains('завтра рано утром пойдём на рынок'));
      expect(File(p.join(tmp.path, 'clip_orig.srt')).readAsStringSync(),
          contains('yarın sabah'));
    });

    test('рядом с видео нельзя — уходят в запасную папку', () async {
      final folder = Directory(p.join(tmp.path, 'вещдок'))..createSync();
      final video = p.join(folder.path, 'clip.mp4');
      File(video).writeAsStringSync('видео');
      final undo = makeUnwritable(folder.path, video);
      addTearDown(undo);

      final files = OutputFiles(
          videoPath: video, fallbackRoot: p.join(tmp.path, 'out'), log: DebugLog());
      final written = await files.writeSrts(cues);
      expect(written.inFallback, isTrue);
      expect(written.names.dir, startsWith(p.join(tmp.path, 'out')));
      expect(File(written.names.ruSrt).readAsStringSync(),
          contains('завтра рано утром'));
    });
  });

  group('Замена готового файла', () {
    test('нет файла, папка доступна — можно', () {
      final files = OutputFiles(
          videoPath: p.join(tmp.path, 'clip.mp4'),
          fallbackRoot: tmp.path,
          log: DebugLog());
      expect(files.canReplace(p.join(tmp.path, 'clip_ru.mp4')), isTrue);
      expect(tmp.listSync(), isEmpty, reason: 'пробный файл убран');
    });

    test('replace ставит новый файл на место старого', () {
      final from = File(p.join(tmp.path, 'a.partial.mp4'))..writeAsStringSync('новое');
      final to = File(p.join(tmp.path, 'a.mp4'))..writeAsStringSync('старое');
      OutputFiles(videoPath: to.path, fallbackRoot: tmp.path, log: DebugLog())
          .replace(from.path, to.path);
      expect(to.readAsStringSync(), 'новое');
      expect(from.existsSync(), isFalse);
    });

    test('файл открыт другой программой — FileBusyException, а не «нет прав»',
        () async {
      final target = File(p.join(tmp.path, 'clip_ru.mp4'))
        ..writeAsStringSync('старое');
      final lock = await holdFileLock(target.path);
      final files = OutputFiles(
          videoPath: p.join(tmp.path, 'clip.mp4'),
          fallbackRoot: tmp.path,
          log: DebugLog());
      try {
        expect(() => files.canReplace(target.path),
            throwsA(isA<FileBusyException>()));
        final partial = File(p.join(tmp.path, 'clip_ru.partial.mp4'))
          ..writeAsStringSync('новое');
        expect(() => files.replace(partial.path, target.path),
            throwsA(isA<FileBusyException>()));
      } finally {
        await lock.release();
      }
    }, skip: Platform.isWindows ? null : lockSkipReason);

    test('isSharingViolation — только коды Windows 32 и 33', () {
      FileSystemException withCode(int code) =>
          FileSystemException('x', 'y', OSError('z', code));
      expect(isSharingViolation(withCode(32), windows: true), isTrue);
      expect(isSharingViolation(withCode(33), windows: true), isTrue);
      expect(isSharingViolation(withCode(5), windows: true), isFalse);
      expect(isSharingViolation(withCode(32), windows: false), isFalse);
    });
  });
}
