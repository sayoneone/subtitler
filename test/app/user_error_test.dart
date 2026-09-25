import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/output_files.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/app/video_probe.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/logging.dart';
import 'package:subtitler/core/pipeline/burner.dart';
import 'package:subtitler/core/pipeline/errors.dart';

/// Карта ошибок §10 спецификации: каждая ситуация — человеческим языком и
/// с кнопкой по смыслу, сырой текст — только в деталях.
void main() {
  UserError describe(Object e, {bool windows = true}) =>
      describeError(e, mask: (t) => t, windows: windows);

  FileSystemException fsError(int code, {String path = r'C:\дело\clip_ru.mp4'}) =>
      FileSystemException('ошибка', path, OSError('системный текст', code));

  test('401 — ключ неверный, кнопка «Изменить ключ»', () {
    final error = describe(
        const AuthException(statusCode: 401, message: 'Ключ неверный или отозван'));
    expect(error.title, 'Ключ неверный или отозван');
    expect(error.hint, contains('настройках'));
    expect(error.action, UserErrorAction.changeKey);
    expect(error.action.label, 'Изменить ключ');
  });

  test('403 — называется именно недостающая роль', () {
    final stt = describe(const AuthException(
        statusCode: 403, message: 'У ключа нет роли ai.speechkit-stt.user'));
    expect(stt.title, 'У ключа нет роли ai.speechkit-stt.user');
    expect(stt.hint, contains('консоли'));

    final translate = describe(const AuthException(
        statusCode: 403, message: 'У ключа нет роли ai.translate.user'));
    expect(translate.title, 'У ключа нет роли ai.translate.user');
    expect(translate.action, UserErrorAction.retry);
  });

  test('Нет сети — «Нет доступа к интернету»', () {
    final error = describe(
        const TransientException(message: 'Нет связи с сервисом перевода'));
    expect(error.title, 'Нет доступа к интернету');
    expect(error.hint, contains('только онлайн'));
    expect(error.action, UserErrorAction.retry);
  });

  test('429/5xx после повторов — сервис временно недоступен', () {
    final error = describe(const TransientException(
        statusCode: 503, message: 'Сервис распознавания недоступен'));
    expect(error.title, 'Сервис Яндекса временно недоступен');
  });

  test('Видео без звука', () {
    final error = describe(const NoAudioStreamException());
    expect(error.title, 'В этом видео нет звука');
    expect(error.action, UserErrorAction.home);
  });

  test('Не видео — и своим исключением, и по тексту ffmpeg', () {
    expect(describe(const NotAVideoException('a.docx', 'не распознан')).title,
        'Это не видео или файл повреждён');
    expect(
        describe(StateError('Не удалось прочитать видео: '
                'Error opening input: $kInvalidDataMarker'))
            .title,
        'Это не видео или файл повреждён');
    expect(
        describe(const NotAVideoException('папка', 'это папка',
                isDirectory: true))
            .title,
        'Это папка, а не видео');
  });

  test('Речь не найдена', () {
    expect(describe(const NoSpeechFoundException()).title,
        'Речь в ролике не обнаружена');
  });

  test('Субтитры не отрисовались — сообщить разработчику, числа в деталях', () {
    final error = describe(const SubtitlesInvisibleException(VisibilityCheck(
        atSeconds: 2.5, changedPixels: 3, requiredPixels: 12)));
    expect(error.title, 'Субтитры не отрисовались — сообщите разработчику');
    expect(error.details, contains('изменилось 3 пикселей'));
    expect(error.action, UserErrorAction.none);
  });

  test('Занятый выходной файл — имя файла и «закройте его и повторите»', () {
    final error = describe(const FileBusyException(r'C:\дело\clip_ru.mp4'));
    expect(error.title,
        'Файл clip_ru.mp4 открыт в другой программе, закройте его и повторите');
    expect(error.action, UserErrorAction.retry);

    // Имя берётся по правилам путей той ОС, для которой составлено
    // сообщение, а не той, где идут тесты: CI гоняет их и на Linux. Там
    // обратная косая черта — обычный символ имени файла.
    expect(
        describe(const FileBusyException(r'/дело/клип\2_ru.mp4'),
                windows: false)
            .title,
        r'Файл клип\2_ru.mp4 открыт в другой программе, закройте его и '
        'повторите');

    // То же по коду ошибки Windows (32 — ERROR_SHARING_VIOLATION).
    expect(describe(fsError(32)).title,
        'Файл clip_ru.mp4 открыт в другой программе, закройте его и повторите');
    // На Unix номер 32 — это EPIPE, а не «файл занят».
    expect(describe(fsError(32), windows: false).title,
        isNot(contains('открыт в другой программе')));
  });

  test('Нет места: коды Windows 112 и 39, Unix 28, текст ffmpeg', () {
    const title = 'Недостаточно места на диске для обработки';
    expect(describe(fsError(112)).title, title);
    expect(describe(fsError(39)).title, title);
    expect(describe(fsError(28, path: '/x/clip_ru.mp4'), windows: false).title,
        title);
    // 39 на Unix — ENOTEMPTY, к месту на диске отношения не имеет.
    expect(describe(fsError(39), windows: false).title, isNot(title));
    expect(
        describe(StateError('Не удалось вшить субтитры: '
                'av_interleaved_write_frame(): No space left on device'))
            .title,
        title);
  });

  test('ffmpeg упал — «Не удалось обработать видео», сырое — в деталях', () {
    final error =
        describe(StateError('Не удалось вшить субтитры: [AVFilterGraph] boom'));
    expect(error.title, 'Не удалось обработать видео');
    expect(error.title, isNot(contains('boom')));
    expect(error.details, contains('[AVFilterGraph] boom'));
  });

  test('ffmpeg не запускается (антивирус, политика) — своё сообщение', () {
    final error = describe(const ProcessException('ffmpeg.exe', [], 'нет', 1260));
    expect(error.title, 'Не удалось запустить компонент обработки видео');
  });

  test('Прочее — общее сообщение с кнопкой «Повторить»', () {
    final error = describe(const FormatException('странное'));
    expect(error.title, 'Что-то пошло не так');
    expect(error.action, UserErrorAction.retry);
    expect(error.details, contains('странное'));
  });

  test('Ключ не попадает в технические детали', () {
    const key = 'AQVN-vydumannyj-klyuch-dlya-testa-maski';
    final log = DebugLog()..redact(key);
    final error = describeError(
      ApiException(statusCode: 400, message: 'заголовок Api-Key $key отклонён'),
      mask: log.mask,
    );
    expect(error.details, isNot(contains(key)));
    expect(error.details, contains('***КЛЮЧ***'));
  });

  test('По умолчанию детали проходят через маску общего журнала', () {
    const key = 'AQVN-vydumannyj-klyuch-obshchego-zhurnala';
    DebugLog.instance.redact(key);
    final error = describeError(StateError('упало с ключом $key'));
    expect(error.details, isNot(contains(key)));
  });
}
