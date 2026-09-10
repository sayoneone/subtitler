import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/logging.dart';

const String kFontAsset = 'assets/fonts/NotoSans-Regular.ttf';
const String kFontFamily = 'Noto Sans';

/// Готовит папки, которыми пользуется ядро.
///
/// Шрифт лежит внутри бандла приложения, а libass умеет читать только
/// обычные файлы — поэтому при запуске он выкладывается на диск.
class AppRuntime {
  final String supportDir;
  final String fontsDir;
  final String workDir;

  const AppRuntime({
    required this.supportDir,
    required this.fontsDir,
    required this.workDir,
  });

  static Future<AppRuntime> prepare({DebugLog? log}) async {
    final journal = log ?? DebugLog.instance;
    final support = await getApplicationSupportDirectory();
    journal.attachFile(p.join(support.path, 'subtitler.log'));

    final fonts = Directory(p.join(support.path, 'fonts'));
    fonts.createSync(recursive: true);
    final fontFile = File(p.join(fonts.path, p.basename(kFontAsset)));
    final bytes = await rootBundle.load(kFontAsset);
    // Перезаписываем всегда: так обновление приложения обновит и шрифт.
    await fontFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    journal.debug('Шрифт распакован: ${fontFile.path} '
        '(${bytes.lengthInBytes} байт)');

    final work = Directory(p.join(support.path, 'work'));
    work.createSync(recursive: true);

    journal.info('Папка приложения: ${support.path}');
    return AppRuntime(
      supportDir: support.path,
      fontsDir: fonts.path,
      workDir: work.path,
    );
  }

  /// Рабочая папка под конкретное видео: имя стабильно, поэтому повторная
  /// обработка того же файла переиспользует уже нарезанные сегменты.
  String workDirFor(String videoPath) {
    final name = p.basenameWithoutExtension(videoPath);
    final stamp = videoPath.hashCode.toUnsigned(32).toRadixString(16);
    return p.join(workDir, '${_sanitize(name)}_$stamp');
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-zА-Яа-я0-9_-]+'), '_');
}
