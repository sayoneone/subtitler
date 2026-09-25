import 'package:flutter/services.dart';

/// Видео из командной строки: первый аргумент, не похожий на ключ запуска.
///
/// Так Windows передаёт файл, перетащенный на значок программы или на её
/// ярлык, и файл из «Открыть с помощью». Проверять, видео ли это, здесь не
/// нужно: это сделает обычный путь открытия и скажет человеку понятно.
String? videoArgument(List<String> args) {
  for (final arg in args) {
    final value = arg.trim();
    if (value.isEmpty || value.startsWith('-')) continue;
    return value;
  }
  return null;
}

/// Канал запускалки Windows (windows/runner/flutter_window.cpp).
///
/// Программа работает в одной копии: повторный запуск (видео бросили на
/// значок, когда окно уже открыто) не открывает второе окно, а передаёт
/// свои аргументы этой копии и выводит её окно вперёд. Иначе две копии
/// писали бы в один журнал, одну рабочую папку и одни настройки, а то же
/// видео распознавалось бы и оплачивалось дважды.
///
/// Запускалка вызывает `open` со списком аргументов второго запуска, а
/// Dart отвечает `ready`, когда готов их принимать: до этого запускалка
/// копит их у себя.
const MethodChannel kInstanceChannel = MethodChannel('ru.subtitler/instance');

/// Принимает видео от повторных запусков программы: [onVideo] получает
/// путь или `null`, если второй запуск был без видео.
///
/// На других платформах запускалки нет, и слушать нечего.
Future<void> listenForOtherLaunches(
  void Function(String? video) onVideo, {
  MethodChannel channel = kInstanceChannel,
}) async {
  channel.setMethodCallHandler((call) async {
    if (call.method != 'open') throw MissingPluginException();
    final args = (call.arguments as List<Object?>? ?? const [])
        .whereType<String>()
        .toList();
    onVideo(videoArgument(args));
  });
  try {
    await channel.invokeMethod<void>('ready');
  } on MissingPluginException {
    // Не Windows: повторные запуски сюда не приходят.
  }
}
