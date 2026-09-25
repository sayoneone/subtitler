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
}
