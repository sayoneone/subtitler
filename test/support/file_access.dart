/// Файлы, которые нельзя записать: занятые другой программой и лежащие
/// там, где писать запрещено.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Держит файл открытым из другого процесса так, как его держит
/// видеоплеер: без общего доступа. Только Windows — на Unix обязательных
/// блокировок нет.
class FileLockHolder {
  final Process _process;
  final File _release;

  FileLockHolder._(this._process, this._release);

  /// Отпускает файл и ждёт, пока держатель завершится. Если он не
  /// завершился сам — завершает его по PID, который сам же и запускал.
  Future<void> release() async {
    _release.writeAsStringSync('');
    final code =
        await _process.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
      _process.kill();
      return -1;
    });
    if (_release.existsSync()) _release.deleteSync();
    if (code != 0) {
      throw StateError('Держатель блокировки завершился с кодом $code');
    }
  }
}

const String lockSkipReason =
    'Блокировку файла другой программой можно воспроизвести только на Windows';

/// Открывает [path] в PowerShell с `FileShare.None` и ждёт, пока файл
/// действительно заблокирован. Держатель отпускает файл, когда появится
/// файл-сигнал, и в любом случае — через минуту.
Future<FileLockHolder> holdFileLock(String path) async {
  final windowsPath = path.replaceAll('/', r'\');
  final release = File('$path.release');
  if (release.existsSync()) release.deleteSync();
  final releasePath = release.path.replaceAll('/', r'\');
  final script = "\$f = [System.IO.File]::Open('$windowsPath', 'Open', "
      "'Read', 'None'); "
      "[Console]::Out.WriteLine('locked'); [Console]::Out.Flush(); "
      "\$n = 0; while (-not (Test-Path '$releasePath') -and \$n -lt 600) "
      "{ Start-Sleep -Milliseconds 100; \$n++ }; \$f.Close()";
  final process = await Process.start(
      'powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  final locked = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .any((line) => line.contains('locked'))
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  if (!locked) {
    process.kill();
    throw StateError('Не удалось заблокировать $path: $errors');
  }
  return FileLockHolder._(process, release);
}

/// Делает так, что рядом с [video] писать нельзя, и возвращает отмену.
///
/// На Unix — папка без права записи. На Windows права папки меняются
/// только через ACL; вместо этого выходные файлы заранее кладутся
/// «только для чтения»: запись в них отклоняется тем же кодом 5 (нет
/// доступа), что и запись в защищённую папку, — проверено на этой машине.
void Function() makeUnwritable(String folder, String video) {
  if (Platform.isWindows) {
    final base = p.basenameWithoutExtension(video);
    final paths = [
      for (final suffix in ['_orig.srt', '_ru.srt', '_ru.mp4'])
        p.join(folder, '$base$suffix'),
    ];
    for (final path in paths) {
      File(path).writeAsStringSync('');
      Process.runSync('attrib', ['+R', path]);
    }
    return () {
      for (final path in paths) {
        Process.runSync('attrib', ['-R', path]);
      }
    };
  }
  Process.runSync('chmod', ['555', folder]);
  return () => Process.runSync('chmod', ['755', folder]);
}
