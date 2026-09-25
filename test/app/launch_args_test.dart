import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/launch_args.dart';

void main() {
  test('Видео, перетащенное на значок, приходит первым аргументом', () {
    expect(videoArgument([r'C:\Дела\запись 1.mp4']), r'C:\Дела\запись 1.mp4');
  });

  test('Ключи запуска и пустые аргументы пропускаются', () {
    expect(videoArgument(['--enable-software-rendering', '', r'D:\a.mp4']),
        r'D:\a.mp4');
  });

  test('Без аргументов видео нет', () {
    expect(videoArgument(const []), isNull);
    expect(videoArgument(['--flag', '  ']), isNull);
  });
}
