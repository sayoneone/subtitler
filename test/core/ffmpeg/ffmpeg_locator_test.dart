import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_locator.dart';
import 'package:subtitler/core/ffmpeg/process_runner.dart';

/// Раскладка переносимой сборки под Windows: exe и рядом с ним tools\ffmpeg.
/// Ровно это собирает .github/workflows/build.yml и ровно это следователь
/// распаковывает из ZIP-архива.
const _appDir = r'C:\Users\sled\Desktop\subtitler';
const _bundled = r'C:\Users\sled\Desktop\subtitler\tools\ffmpeg\ffmpeg.exe';

void main() {
  List<String> windowsCandidates({String? override, Map<String, String>? env}) =>
      FfmpegLocator.candidates(
        override: override,
        env: env ?? const {},
        appDir: _appDir,
        windows: true,
      );

  test('На Windows ffmpeg ищется рядом с приложением', () {
    // Главный случай: служебный ПК без прав администратора. Ни переменной
    // окружения, ни ffmpeg в PATH там нет — есть только распакованная папка.
    expect(windowsCandidates(), contains(_bundled),
        reason: 'иначе приложение не найдёт собственный ffmpeg и '
            'не сможет сделать вообще ничего');
  });

  test('Своя сборка проверяется раньше системной и раньше PATH', () {
    final list = windowsCandidates();
    // Сначала убеждаемся, что путь вообще есть: indexOf отсутствующего
    // элемента даёт −1, и сравнение порядка прошло бы вхолостую.
    expect(list, contains(_bundled));
    expect(list.indexOf(_bundled), lessThan(list.indexOf('ffmpeg')),
        reason: 'приложение не должно зависеть от того, что стоит '
            'на машине пользователя');
  });

  test('На Windows unix-пути не перебираются', () {
    // Их там не бывает, а в журнале они превращаются в пять строк
    // «не найдено» перед настоящей причиной.
    expect(windowsCandidates(), isNot(contains('/usr/bin/ffmpeg')));
  });

  test('Переменная окружения сильнее бандла: ею пользуются CI и разработчик', () {
    const own = r'D:\ffmpeg\bin\ffmpeg.exe';
    final list = windowsCandidates(env: const {kFfmpegPathEnv: own});
    expect(list.first, own);
    expect(list.indexOf(own), lessThan(list.indexOf(_bundled)));
  });

  test('Путь, указанный руками в интерфейсе, сильнее всего', () {
    const typed = r'E:\свой\ffmpeg.exe';
    final list = windowsCandidates(
      override: '  $typed  ',
      env: const {kFfmpegPathEnv: r'D:\ffmpeg\bin\ffmpeg.exe'},
    );
    expect(list.first, typed, reason: 'пробелы по краям обрезаются');
  });

  test('На macOS и Linux бандл добавляется, системные пути остаются', () {
    // Стенд разработчика: рядом с бинарником ffmpeg обычно нет, и перебор
    // системных мест по-прежнему нужен.
    final list = FfmpegLocator.candidates(
      env: const {},
      appDir: '/Applications/subtitler.app/Contents/MacOS',
      windows: false,
    );
    expect(list,
        contains('/Applications/subtitler.app/Contents/MacOS/tools/ffmpeg/ffmpeg'));
    expect(list, containsAll(FfmpegLocator.knownPaths));
    expect(list.last, 'ffmpeg');
  });

  test('Имя бинарника зависит от платформы, а не от хозяйской ОС', () {
    // Тесты идут и на Linux-раннере: раскладка Windows должна собираться
    // там так же, как на самой Windows.
    expect(FfmpegLocator.bundledPaths(appDir: _appDir, windows: true),
        [_bundled, r'C:\Users\sled\Desktop\subtitler\ffmpeg.exe']);
    expect(FfmpegLocator.bundledPaths(appDir: '/opt/subtitler', windows: false),
        ['/opt/subtitler/tools/ffmpeg/ffmpeg', '/opt/subtitler/ffmpeg']);
  });
}
