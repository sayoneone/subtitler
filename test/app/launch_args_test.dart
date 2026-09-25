import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/launch_args.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('Повторный запуск (Windows)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// Запускалка присылает аргументы второго запуска первой копии.
    Future<void> launchAgain(List<Object?> args) =>
        messenger.handlePlatformMessage(
          kInstanceChannel.name,
          kInstanceChannel.codec
              .encodeMethodCall(MethodCall('open', args)),
          (_) {},
        );

    test('видео второго запуска доходит до программы, запускалке сообщено, '
        'что можно слать', () async {
      final sent = <String>[];
      messenger.setMockMethodCallHandler(kInstanceChannel, (call) async {
        sent.add(call.method);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(kInstanceChannel, null);
        kInstanceChannel.setMethodCallHandler(null);
      });
      final received = <String?>[];

      await listenForOtherLaunches(received.add);
      // Пока Dart не готов, запускалка копит аргументы у себя.
      expect(sent, ['ready']);

      await launchAgain(['--flag', r'C:\Дела\запись 2.mp4']);
      await launchAgain(const []);
      expect(received, [r'C:\Дела\запись 2.mp4', null]);
    });

    test('на платформе без запускалки Windows слушать нечего — без ошибки',
        () async {
      addTearDown(() => kInstanceChannel.setMethodCallHandler(null));
      // Обработчика на стороне платформы нет: MissingPluginException.
      await expectLater(listenForOtherLaunches((_) {}), completes);
    });
  });
}
