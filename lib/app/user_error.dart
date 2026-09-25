import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/cloud/api_errors.dart';
import '../core/logging.dart';
import '../core/pipeline/burner.dart';
import '../core/pipeline/errors.dart';
import 'output_files.dart';
import 'video_probe.dart';

/// Что предложить человеку кнопкой под сообщением об ошибке.
enum UserErrorAction {
  /// «Повторить»: сеть, занятый файл, сбой ffmpeg.
  retry,

  /// «Изменить ключ»: ключ неверный или отозван.
  changeKey,

  /// «На главный экран»: с этим файлом дальше делать нечего.
  home,

  /// Кнопки нет — только «Технические детали».
  none,
}

extension UserErrorActionLabel on UserErrorAction {
  /// Подпись кнопки; для [UserErrorAction.none] — пустая строка.
  String get label => switch (this) {
        UserErrorAction.retry => 'Повторить',
        UserErrorAction.changeKey => 'Изменить ключ',
        UserErrorAction.home => 'На главный экран',
        UserErrorAction.none => '',
      };
}

/// Ошибка человеческим языком (§10 спецификации): что случилось, что
/// делать и какая кнопка поможет. Сырое исключение живёт только в
/// [details] — для «Технических деталей» и разработчика.
class UserError {
  final String title;

  /// Что делать — одно-два предложения.
  final String hint;

  final UserErrorAction action;

  /// Сырой текст ошибки. Уже без ключа: проходит через маску журнала.
  final String details;

  const UserError({
    required this.title,
    required this.hint,
    this.action = UserErrorAction.none,
    this.details = '',
  });

  @override
  String toString() => '$title. $hint';
}

/// Ошибка, которую приложение формулирует само, без исключения ядра.
class NothingToBurnException implements Exception {
  const NothingToBurnException();

  @override
  String toString() => 'Нет ни одной реплики с переводом — вшивать нечего';
}

/// Коды «нет места на диске»: Windows — ERROR_DISK_FULL (112) и
/// ERROR_HANDLE_DISK_FULL (39); Unix и Android — ENOSPC (28).
const Set<int> kWindowsDiskFullCodes = {112, 39};
const int kPosixNoSpace = 28;

/// Переводит исключение в сообщение для человека (§10 спецификации и
/// карта ошибок интерфейса).
///
/// [mask] вырезает секреты из технических деталей — по умолчанию маска
/// общего журнала, где зарегистрирован ключ. [windows] подменяется в
/// тестах: коды ошибок файловой системы у Windows и Unix разные. [srt] —
/// где на самом деле лежат .srt, если сообщение о них говорит.
UserError describeError(
  Object error, {
  String Function(String text)? mask,
  bool? windows,
  SrtFiles? srt,
}) {
  final hide = mask ?? DebugLog.instance.mask;
  final onWindows = windows ?? Platform.isWindows;
  final details = hide('$error');

  UserError make(String title, String hint, UserErrorAction action) =>
      UserError(title: title, hint: hint, action: action, details: details);

  switch (error) {
    case AuthException(statusCode: 401):
      return make(
        'Ключ неверный или отозван',
        'Проверьте ключ в настройках: введите его заново или создайте новый '
            'в консоли Яндекс Облака.',
        UserErrorAction.changeKey,
      );
    case AuthException(:final message):
      // Роль уже названа в тексте клиента: распознавание и перевод
      // требуют разных ролей, и человеку нужна именно недостающая.
      final role = RegExp(r'ai\.[a-z-]+\.user').firstMatch(message)?.group(0);
      return make(
        role == null ? 'У ключа нет нужной роли' : 'У ключа нет роли $role',
        'Добавьте эту роль сервисному аккаунту в консоли Яндекс Облака и '
            'повторите.',
        UserErrorAction.retry,
      );
    case TransientException(statusCode: null):
      return make(
        'Нет доступа к интернету',
        'Обработка возможна только онлайн. Проверьте подключение и повторите.',
        UserErrorAction.retry,
      );
    case TransientException():
      return make(
        'Сервис Яндекса временно недоступен',
        'Подождите немного и повторите.',
        UserErrorAction.retry,
      );
    case ApiException():
      return make(
        'Сервис Яндекса вернул ошибку',
        'Повторите. Если ошибка повторится, сохраните журнал и отправьте '
            'его разработчику.',
        UserErrorAction.retry,
      );
    case NoAudioStreamException():
      return make(
        'В этом видео нет звука',
        'Распознавать нечего. Выберите другой файл.',
        UserErrorAction.home,
      );
    case NotAVideoException(isDirectory: true):
      return make(
        'Это папка, а не видео',
        'Перетащите сам видеофайл.',
        UserErrorAction.none,
      );
    case NotAVideoException():
      return make(
        'Это не видео или файл повреждён',
        'Выберите видеофайл: mp4, mov, mkv, avi и другие.',
        UserErrorAction.none,
      );
    case NoSpeechFoundException():
      return make(
        'Речь в ролике не обнаружена',
        'В записи не нашлось участков с речью. Если речь в ней есть, '
            'сохраните журнал и отправьте его разработчику.',
        UserErrorAction.home,
      );
    case SubtitlesInvisibleException():
      return make(
        'Субтитры не отрисовались — сообщите разработчику',
        'Видео не сохранено: в готовом кадре субтитров не видно. '
            'Сохраните журнал и отправьте его разработчику. '
            '${_srtAlreadySaved(srt)}',
        UserErrorAction.none,
      );
    case FileBusyException(:final path):
      // Имя — по правилам путей той ОС, о которой сообщение ([windows]), а
      // не той, где выполняется код: так же, как у кода 32 ниже.
      final fileName = (onWindows ? p.windows : p.posix).basename(path);
      return make(
        'Файл $fileName открыт в другой программе, закройте его и повторите',
        'Чаще всего это видеоплеер. Закройте его и нажмите «Повторить».',
        UserErrorAction.retry,
      );
    case NothingToBurnException():
      return make(
        'Нет ни одной реплики с переводом',
        'Впишите перевод хотя бы одной реплики — тогда будет что вшить.',
        UserErrorAction.none,
      );
    case PipelineCancelledException():
      return make(
        'Обработка отменена',
        'Уже распознанное сохранено: повторный запуск продолжит с того же '
            'места.',
        UserErrorAction.home,
      );
    case FileSystemException():
      return _describeFileSystem(error, onWindows, details);
    case ProcessException():
      return make(
        'Не удалось запустить компонент обработки видео',
        'Распакуйте архив заново целиком. Если не поможет — возможно, '
            'запуск запрещён антивирусом или политикой: сохраните журнал и '
            'отправьте его разработчику.',
        UserErrorAction.retry,
      );
  }

  final text = '$error';
  if (text.contains('No space left on device')) {
    return _diskFull(details);
  }
  if (text.contains(kInvalidDataMarker)) {
    return make(
      'Это не видео или файл повреждён',
      'Выберите видеофайл: mp4, mov, mkv, avi и другие.',
      UserErrorAction.home,
    );
  }
  if (error is StateError) {
    // Ядро сообщает сбои ffmpeg через StateError с полным выводом.
    return make(
      'Не удалось обработать видео',
      'Повторите. Если ошибка повторится, сохраните журнал и отправьте '
          'его разработчику.',
      UserErrorAction.retry,
    );
  }
  return make(
    'Что-то пошло не так',
    'Повторите. Если ошибка повторится, сохраните журнал и отправьте его '
        'разработчику.',
    UserErrorAction.retry,
  );
}

/// Где уже лежат .srt — по факту записи: в папке только для чтения они
/// уходят в папку программы, и «рядом с видео» было бы неправдой.
String _srtAlreadySaved(SrtFiles? srt) => switch (srt) {
      null => 'Файлы .srt с субтитрами уже сохранены.',
      SrtFiles(inFallback: true, :final names) =>
        'Файлы .srt с субтитрами уже сохранены в папку программы: '
            '${names.dir}.',
      _ => 'Файлы .srt с субтитрами уже лежат рядом с видео.',
    };

UserError _diskFull(String details) => UserError(
      title: 'Недостаточно места на диске для обработки',
      hint: 'Освободите место на диске и повторите.',
      action: UserErrorAction.retry,
      details: details,
    );

UserError _describeFileSystem(
    FileSystemException error, bool windows, String details) {
  final code = error.osError?.errorCode;
  if (windows ? kWindowsDiskFullCodes.contains(code) : code == kPosixNoSpace) {
    return _diskFull(details);
  }
  if (isSharingViolation(error, windows: windows)) {
    final path = error.path;
    final name =
        path == null ? '' : ' ${(windows ? p.windows : p.posix).basename(path)}';
    return UserError(
      title: 'Файл$name открыт в другой программе, закройте его и повторите',
      hint: 'Чаще всего это видеоплеер. Закройте его и нажмите «Повторить».',
      action: UserErrorAction.retry,
      details: details,
    );
  }
  return UserError(
    title: 'Не удалось записать или прочитать файл',
    hint: 'Проверьте, что файл на месте и папка доступна, и повторите.',
    action: UserErrorAction.retry,
    details: details,
  );
}
