import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:subtitler/app/runtime.dart';
import 'package:subtitler/core/logging.dart';

/// Папки, которые на Windows отдал бы path_provider_windows 2.3.0:
/// поддержка — RoamingAppData, кеш — LocalAppData (сверено по исходнику).
class _FakePaths extends PathProviderPlatform {
  final String support;
  final String cache;
  _FakePaths(this.support, this.cache);

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getApplicationCachePath() async => cache;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Рабочая папка — в кеше (LocalAppData), журнал и шрифт — на месте',
      () async {
    final tmp = Directory.systemTemp.createTempSync('runtime_test_');
    final log = DebugLog();
    addTearDown(() async {
      await log.close();
      tmp.deleteSync(recursive: true);
    });
    final roaming = p.join(tmp.path, 'Roaming', 'ru.subtitler', 'subtitler');
    final local = p.join(tmp.path, 'Local', 'ru.subtitler', 'subtitler');
    // Так рабочую папку держали прежние версии — с сотнями мегабайт звука.
    final oldWork = Directory(p.join(roaming, 'work', 'clip_1'))
      ..createSync(recursive: true);
    File(p.join(oldWork.path, 'audio.wav')).writeAsBytesSync([0, 1, 2]);
    PathProviderPlatform.instance = _FakePaths(roaming, local);

    final runtime = await AppRuntime.prepare(log: log);

    expect(runtime.workDir, p.join(local, 'work'));
    expect(Directory(runtime.workDir).existsSync(), isTrue);
    expect(runtime.outputDir,
        p.join(Platform.isAndroid ? roaming : local, 'output'));
    expect(runtime.supportDir, roaming);
    expect(File(p.join(roaming, 'fonts', 'NotoSans-Regular.ttf')).existsSync(),
        isTrue);
    expect(log.filePath, p.join(roaming, 'subtitler.log'));
    expect(runtime.workDirFor(p.join('дело', 'clip.mp4')),
        startsWith(runtime.workDir));

    // Прежняя рабочая папка в Roaming убирается в фоне.
    final removed = Directory(p.join(roaming, 'work'));
    for (var i = 0; i < 50 && removed.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(removed.existsSync(), isFalse);
  });

  // Нарезку и SRT для вшивания программа убирает сама, но у недоделанных
  // сессий (отмена, нет сети, программу закрыли) рабочая папка остаётся.
  // Раньше такие папки со звуком из материалов дела лежали вечно.
  test('При запуске удаляются рабочие папки, не тронутые дольше недели',
      () async {
    final tmp = Directory.systemTemp.createTempSync('runtime_test_');
    final log = DebugLog();
    addTearDown(() async {
      await log.close();
      tmp.deleteSync(recursive: true);
    });
    final roaming = p.join(tmp.path, 'Roaming', 'ru.subtitler', 'subtitler');
    final local = p.join(tmp.path, 'Local', 'ru.subtitler', 'subtitler');
    final old = DateTime.now().subtract(const Duration(days: 8));

    File file(String path, {DateTime? modified}) {
      final f = File(path)..parent.createSync(recursive: true);
      f.writeAsBytesSync([1, 2, 3]);
      if (modified != null) f.setLastModifiedSync(modified);
      return f;
    }

    final stale =
        file(p.join(local, 'work', 'clip_0001', 'segments', 'seg_001.ogg'),
            modified: old);
    final fresh =
        file(p.join(local, 'work', 'clip_0002', 'segments', 'seg_001.ogg'));
    // Результаты и сессии лежат в других папках — их не трогаем, сколько
    // бы им ни было.
    final result = file(p.join(local, 'output', 'clip_ru.mp4'), modified: old);
    final session =
        file(p.join(roaming, 'clip.mp4.subtitler.json'), modified: old);
    PathProviderPlatform.instance = _FakePaths(roaming, local);

    await AppRuntime.prepare(log: log);

    expect(stale.parent.parent.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(result.existsSync(), isTrue);
    expect(session.existsSync(), isTrue);
  });

  group('Уборка старых рабочих папок', () {
    late Directory root;
    final now = DateTime(2026, 9, 25, 12);

    setUp(() => root = Directory.systemTemp.createTempSync('work_cleanup_'));
    tearDown(() => root.deleteSync(recursive: true));

    File file(String relative, DateTime modified) {
      final f = File(p.join(root.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1]);
      f.setLastModifiedSync(modified);
      return f;
    }

    test('возраст — по самому свежему файлу внутри папки', () async {
      // Нарезка старая, но SRT для вшивания писали вчера — папка живая.
      file(p.join('work', 'a_1', 'segments', 'seg_001.ogg'),
          now.subtract(const Duration(days: 30)));
      final yesterday = file(p.join('work', 'a_1', 'burn_ru.srt'),
          now.subtract(const Duration(days: 1)));
      final old = file(p.join('work', 'b_2', 'segments', 'seg_001.ogg'),
          now.subtract(kWorkDirMaxAge + const Duration(hours: 1)));
      Directory(p.join(root.path, 'work', 'c_3')).createSync();

      await removeStaleWorkDirs(p.join(root.path, 'work'), now: now);

      expect(yesterday.existsSync(), isTrue);
      expect(old.parent.parent.existsSync(), isFalse);
      expect(Directory(p.join(root.path, 'work', 'c_3')).existsSync(), isFalse,
          reason: 'пустая папка — брошенная');
    });

    test('за пределы папки work не выходит', () async {
      final ancient = now.subtract(const Duration(days: 365));
      final beside = file(p.join('output', 'clip_ru.mp4'), ancient);
      final loose = file(p.join('work', 'заметка.txt'), ancient);

      await removeStaleWorkDirs(p.join(root.path, 'work'), now: now);

      expect(beside.existsSync(), isTrue);
      expect(loose.existsSync(), isTrue, reason: 'трогаем только папки видео');
    });

    test('папки work нет — ничего не делает', () async {
      await removeStaleWorkDirs(p.join(root.path, 'нет такой'), now: now);
    });
  });
}
