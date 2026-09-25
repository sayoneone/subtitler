/// Строки экранов оболочки, ключа, главного, обработки, настроек и журнала
/// (§12 спецификации): так их проще вычитать и не разойтись в словах между
/// экранами.
///
/// Не все строки интерфейса здесь. Тексты предпросмотра (`lib/ui/review/`)
/// и плеера (`lib/ui/player/`) живут в самих виджетах. Названия шагов
/// обработки (`ProcessingStepTitle`), тексты ошибок (`describeError`) и
/// подписи кнопок ошибок (`UserErrorActionLabel`) — рядом с логикой в
/// `lib/app/`: их проверяют тесты контроллера. Экран отладочного стенда
/// пишет свои.
abstract final class AppStrings {
  // ------------------------------------------------------------ оболочка
  static const appTitle = 'Subtitler';
  static const settings = 'Настройки';
  static const more = 'Ещё';
  static const menuLog = 'Журнал работы';
  static const menuDebugStand = 'Отладочный стенд';
  static const menuDebugStandHint = 'для разработчика';
  static const close = 'Закрыть';
  static const cancel = 'Отмена';
  static const copy = 'Скопировать';
  static const copied = 'Скопировано';
  static const dropToOpen = 'Отпустите, чтобы открыть это видео';

  // -------------------------------------------------------------- журнал
  static const logTitle = 'Журнал работы';
  static const logShowDebug = 'Подробно';
  static const logShowDebugHint =
      'Показывать подробные записи — они нужны разработчику';
  static const logSaveToFile = 'Сохранить в файл';
  static const logOpenFolder = 'Открыть папку с журналом';
  static const logShare = 'Поделиться журналом';
  static const logClear = 'Очистить';
  static const saveLog = 'Сохранить журнал';
  static const shareLog = 'Отправить журнал';
  // Скрыты только папки с видео: пути профиля (папка программы, рабочая
  // папка) в журнале остаются — обещать «нет названий папок» нельзя.
  static String logSaved(String path) => 'Журнал сохранён: $path. '
      'В нём нет текста записей и названий папок с видео.';
  static const logSaveFailed =
      'Не удалось сохранить журнал — причина записана в журнал работы';
  static const logFileMissing = 'Файл журнала ещё не создан';

  // ------------------------------------------------------------- запуск
  static const starting = 'Подготовка…';

  // ---------------------------------------------------- программа сломана
  static const brokenTitle = 'Не найден компонент обработки видео';
  static const brokenHint = 'Распакуйте архив заново целиком: все папки '
      'должны лежать рядом с subtitler.exe.';

  // ------------------------------------------------------------- ошибки
  static const technicalDetails = 'Технические детали';
  static const recentLog = 'Последние записи журнала:';
  static const failedTitle = 'Что-то пошло не так';
  static const failedHint = 'Повторите. Если ошибка повторится, сохраните '
      'журнал и отправьте его разработчику.';

  // ---------------------------------------------------------------- ключ
  static const keyTitle = 'Ключ Яндекс Облака';
  static const keyIntro = 'Чтобы распознавать речь и переводить её на '
      'русский, программе нужен API-ключ сервисного аккаунта Яндекс Облака. '
      'У сервисного аккаунта должны быть две роли:';
  static const keyRoleStt = 'ai.speechkit-stt.user';
  static const keyRoleSttWhat = 'распознавание речи';
  static const keyRoleTranslate = 'ai.translate.user';
  static const keyRoleTranslateWhat = 'перевод';
  static const keyPrivacy = 'Ключ хранится только здесь, в защищённом '
      'хранилище системы, и отправляется только в Яндекс Облако.';
  static const keyHowTo = 'Как создать ключ';

  /// Сверено с документацией Яндекс Облака (yandex.cloud/ru/docs/iam,
  /// 2026-09-25): назначение роли и создание API-ключа в консоли.
  static const keyHowToSteps = [
    'Откройте консоль Яндекс Облака и выберите каталог.',
    'В сервисе Identity and Access Management → «Сервисные аккаунты» '
        'выберите сервисный аккаунт или создайте новый.',
    'На вкладке каталога «Права доступа» нажмите «Настроить доступ», '
        'выберите «Сервисные аккаунты» и этот аккаунт, нажмите «Добавить '
        'роль», добавьте ai.speechkit-stt.user и ai.translate.user, затем '
        '«Сохранить».',
    'Откройте сервисный аккаунт, нажмите «Создать новый ключ» → «Создать '
        'API-ключ». В поле «Область действия» отметьте '
        'yc.ai.speechkitStt.execute и yc.ai.translate.execute и нажмите '
        '«Создать».',
    'Скопируйте секретный ключ (он начинается с AQVN) и вставьте его ниже. '
        'После закрытия окна консоль его больше не покажет.',
  ];
  static const keyField = 'API-ключ';
  static const keyFieldHint = 'AQVN…';
  static const keySubmit = 'Проверить и сохранить';
  static const keyChecking = 'Проверяем…';
  static const keyCheckTitle = 'Проверка ключа';
  static const keyCheckTranslate = 'Перевод';
  static const keyCheckStt = 'Распознавание';
  static const keyStorageBroken = 'Хранилище ключа недоступно: ключ будет '
      'работать до закрытия программы, а при следующем запуске его '
      'придётся ввести заново.';

  // ------------------------------------------------------- главный экран
  static const homeDrop = 'Перетащите видео сюда';
  static const homeOr = 'или';
  static const homePick = 'Выбрать файл';
  static const homePickMobile = 'Выбрать видео';
  static const homeMobileIntro =
      'Выберите видео — субтитры на русском сделаются сами.';
  static const homeOutputHint =
      'Субтитры и видео с ними сохраняются рядом с исходным файлом.';
  static const homeDropFallback =
      'Если перетаскивание не срабатывает, нажмите «Выбрать файл».';
  static const homeChecking = 'Проверяем файл…';
  static const videoTypeGroup = 'Видео';

  static const longVideoTitle = 'Длинный ролик';
  static String longVideoText(String fileName, Duration duration,
          Duration threshold) =>
      '«$fileName» длится ${_minutes(duration)} — дольше '
      '${threshold.inMinutes} минут. Обработка займёт много времени и '
      'обойдётся дороже. Продолжить?';
  static const longVideoContinue = 'Продолжить';

  static String _minutes(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return seconds == 0 ? '$minutes мин' : '$minutes мин $seconds с';
  }

  // ----------------------------------------------------------- обработка
  static String language(String name) => 'Язык: $name';
  /// Доли у шага «Готовим звук» нет: ядро не сообщает, сколько осталось.
  /// На часовом ролике шаг идёт минуты (сотни коротких запусков ffmpeg на
  /// нарезку), и без честной подписи крутилка выглядит зависанием.
  static const prepareHint = 'Делим запись на фразы — на длинном ролике это '
      'может занять несколько минут.';
  static const stopping = 'Останавливаем…';
  static const stoppingHint = 'Дожидаемся ответа на текущий запрос — новых '
      'платных запросов не будет.';

  /// Пока готовится звук, в Яндекс ничего не отправляется: ждать «ответа
  /// на запрос» неоткуда.
  static const stoppingPrepareHint = 'Дожидаемся конца текущего шага '
      'подготовки звука — платных запросов ещё не было.';
  static const processingMayMinimize =
      'Окно можно свернуть — обработка продолжится.';

  static const cancelledTitle = 'Обработка остановлена';
  static const cancelledText = 'Уже распознанное сохранено: если открыть '
      'это видео снова, обработка продолжится с того же места.';
  static const cancelledNothing = 'Распознать ничего не успели.';
  static const openPartial = 'Открыть, что успели';
  static const goHome = 'На главный экран';

  // ----------------------------------------------------------- настройки
  static const settingsKeySaved = 'Ключ сохранён.';
  static const settingsKeySession =
      'Ключ работает до закрытия программы: сохранить его не удалось.';
  static const settingsKeyNone = 'Ключ не введён.';
  static const settingsKeyBusy =
      'Пока идёт работа, ключ заменить или удалить нельзя.';
  static const keyReplace = 'Заменить ключ';
  static const keyDelete = 'Удалить ключ';
  static const keyDeleteTitle = 'Удалить ключ?';
  static const keyDeleteText = 'Ключ будет удалён с этого устройства. '
      'Чтобы продолжить работу, его придётся ввести заново.';
  static const keyDeleteConfirm = 'Удалить';

  static const languagesTitle = 'Языки ваших записей';
  static const languagesHint = 'Программа сама определяет, на каком языке '
      'говорят в ролике, выбирая среди отмеченных языков. Отмечайте только '
      'те, что встречаются в ваших записях: каждый лишний язык — это '
      'дополнительные платные пробы и больше шансов ошибиться.';
  static const languagesLastOne = 'Хотя бы один язык должен остаться '
      'отмеченным.';

  static const settingsLogOpen = 'Открыть журнал';
  static const aboutTitle = 'О программе';
  static String aboutVersion(String? version) =>
      'Subtitler, версия ${version ?? 'неизвестна'}';
  static const aboutTechnical = 'Технические сведения';
  static String aboutLogFile(String? path) =>
      'Журнал: ${path ?? 'не пишется в файл'}';
}
