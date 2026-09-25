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
    // Журнал — не в перемещаемом профиле: он уезжал бы на сервер
    // профилей (на Android — среди постоянных файлов, как раньше).
    final logs = Platform.isAndroid ? roaming : local;
    expect(log.filePath, p.join(logs, 'subtitler.log'));
    expect(runtime.logDir, logs);
    expect(runtime.workDirFor(p.join('дело', 'clip.mp4')),
        startsWith(runtime.workDir));

    // Прежняя рабочая папка в Roaming убирается в фоне.
    final removed = Directory(p.join(roaming, 'work'));
    for (var i = 0; i < 50 && removed.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(removed.existsSync(), isFalse);
  });

  // Выпущенные 0.1.0 и 0.1.1 писали журнал в папку приложения (Roaming):
  // subtitler.log, subtitler.prev.log и «Сохранить в файл» —
  // subtitler-debug.log. Ранние сборки нового окна клали туда же копии
  // «Сохранить журнал» (subtitler-log-*.txt). В них распознанный текст и
  // полные пути к видео, а перемещаемый профиль уезжает на сервер
  // профилей. Журнал теперь пишется в LocalAppData, и прежние файлы
  // раньше так и оставались в Roaming навсегда.
  test('Журналы прежних версий из папки приложения (Roaming) удаляются',
      () async {
    final tmp = Directory.systemTemp.createTempSync('runtime_test_');
    final log = DebugLog();
    addTearDown(() async {
      await log.close();
      tmp.deleteSync(recursive: true);
    });
    final roaming = p.join(tmp.path, 'Roaming', 'ru.subtitler', 'subtitler');
    final local = p.join(tmp.path, 'Local', 'ru.subtitler', 'subtitler');
    Directory(roaming).createSync(recursive: true);
    File inRoaming(String name, String text) =>
        File(p.join(roaming, name))..writeAsStringSync(text);

    const oldJournal = 'INFO  [tr-TR] реплика 1: выдуманная тестовая фраза\n'
        r'INFO  Обработка: D:\Дела\Дело 0 (тест)\clip.mp4, язык tr-TR'
        '\n';
    final journals = [
      inRoaming('subtitler.log', oldJournal),
      inRoaming('subtitler.prev.log', oldJournal),
      inRoaming('subtitler-debug.log', oldJournal),
      inRoaming('subtitler-log-2026-09-20T10-00-00.txt', oldJournal),
    ];
    // Остальное в папке приложения — настройки и запасные сессии — не
    // журналы: их не трогаем.
    final kept = [
      inRoaming('settings.json', '{}'),
      inRoaming('clip.mp4.1a2b3c4d.subtitler.json', '{}'),
      inRoaming('заметка.txt', 'не журнал'),
    ];
    PathProviderPlatform.instance = _FakePaths(roaming, local);

    await AppRuntime.prepare(log: log);

    // Удаляются в фоне — запуск этого не ждёт.
    for (var i = 0; i < 50 && journals.any((f) => f.existsSync()); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect([for (final f in journals) if (f.existsSync()) p.basename(f.path)],
        isEmpty);
    expect([for (final f in kept) if (!f.existsSync()) p.basename(f.path)],
        isEmpty);
    expect(File(p.join(local, 'subtitler.log')).existsSync(), isTrue,
        reason: 'журнал этого запуска — на месте');
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

  group('Имя рабочей папки видео', () {
    const runtime = AppRuntime(
      supportDir: 'support',
      fontsDir: 'fonts',
      workDir: 'work',
      outputDir: 'output',
    );

    // Эталоны посчитаны заранее отдельной программой (FNV-1a по кодовым
    // единицам UTF-16). Имя обязано совпасть с ними и после обновления
    // Dart: String.hashCode этого не обещает, и тогда уже нарезанное
    // пришлось бы резать заново.
    test('строится стабильным хешем пути (FNV-1a), а не String.hashCode', () {
      expect(p.basename(runtime.workDirFor('/дела/дело 12/VID_0001.mp4')),
          'VID_0001_56ea54bf');
      expect(p.basename(runtime.workDirFor('/дела/дело 12/запись звонка.mp4')),
          'запись_звонка_b57381cf');
    });

    test('одинаковые имена из разных дел — разные папки', () {
      expect(p.basename(runtime.workDirFor('/дела/дело 13/VID_0001.mp4')),
          'VID_0001_08b08d3a');
    });
  });
}
