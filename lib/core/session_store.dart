// lib/core/session_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'languages.dart';
import 'logging.dart';
import 'models.dart';
import 'path_hash.dart';

/// Читает и пишет `<имя>.subtitler.json`. Если папка с исходником недоступна
/// для записи (вещдок на защищённом носителе), файл уходит в [fallbackDir].
///
/// Рядом с основной сессией могут лежать резервные копии для других языков —
/// `<имя>.subtitler.<язык>.json`. Туда уходит сессия, когда человек меняет
/// язык: вернуться к прежнему варианту можно бесплатно, вместе с правками.
class SessionStore {
  final String fallbackDir;
  final DebugLog log;

  SessionStore({required this.fallbackDir, DebugLog? log})
      : log = log ?? DebugLog.instance;

  String sessionPathFor(String videoPath) => '$videoPath.subtitler.json';

  /// В запасной папке лежат сессии видео со всех носителей, а копии
  /// вещдоков часто называются одинаково («VID_0001.mp4» из разных дел).
  /// Поэтому к имени видео добавлен хеш полного пути: иначе сессия
  /// одного дела молча затирала бы сессию другого — с ручными правками,
  /// а ролик пришлось бы оплачивать заново. Читаются и файлы под чужим
  /// хешем: путь к тому же видео мог смениться (см. [_otherPathFallbacks]).
  String fallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${_fallbackStem(videoPath)}.subtitler.json');

  String backupPathFor(String videoPath, String lang) =>
      '$videoPath.subtitler.$lang.json';

  String fallbackBackupPathFor(String videoPath, String lang) => p.join(
      fallbackDir, '${_fallbackStem(videoPath)}.subtitler.$lang.json');

  /// «VID_0001.mp4.1a2b3c4d»: человек узнаёт видео по началу имени.
  /// Очень длинное имя обрезается: вместе с хешем и хвостом оно упёрлось
  /// бы в предел длины имени файла (255 символов), а уникальность и так
  /// даёт хеш.
  String _fallbackStem(String videoPath) =>
      '${_shortName(videoPath)}.${stablePathHash(videoPath)}';

  static String _shortName(String videoPath) {
    final name = p.basename(videoPath);
    return name.length > 100 ? name.substring(0, 100) : name;
  }

  /// Запасные файлы видео с таким же именем, записанные по другому пути:
  /// `<имя видео>.<любой хеш>.<tail>`, кроме своего.
  ///
  /// Хеш защищает от затирания при записи, но путь к тому же видео
  /// меняется: защищённую флешку вставили под другой буквой, в сетевую
  /// папку «только на чтение» зашли не через букву диска, а по имени
  /// сервера, папку дела переложили на другой защищённый носитель. Искать
  /// только под своим хешем значит не найти сессию — ролик оплачивался бы
  /// заново, а правки остались бы в осиротевшем файле. Своё ли это видео,
  /// решает отпечаток (см. [_loadFreshest]), как и для файла рядом с
  /// видео, который перенесли вместе с ним.
  ///
  /// [names] — имена файлов запасной папки ([_fallbackNames]); порядок
  /// не важен, из подходящих берётся самый свежий.
  List<String> _otherPathFallbacks(
      String videoPath, String tail, List<String> names) {
    final pattern = RegExp('^${RegExp.escape(_shortName(videoPath))}'
        r'\.[0-9a-f]{8}\.'
        '${RegExp.escape(tail)}\$');
    final own = '${_fallbackStem(videoPath)}.$tail';
    return [
      for (final name in names)
        if (name != own && pattern.hasMatch(name)) p.join(fallbackDir, name),
    ];
  }

  /// Имена файлов в запасной папке; пусто, если её ещё нет или она не
  /// читается.
  List<String> _fallbackNames() {
    try {
      return [
        for (final entity in Directory(fallbackDir).listSync())
          if (entity is File) p.basename(entity.path),
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  /// Так запасные файлы называла прежняя версия — только по имени видео.
  /// Они читаются, чтобы не оплачивать уже обработанное заново, но не
  /// пишутся: такой файл общий для всех одноимённых видео.
  String _legacyFallbackPathFor(String videoPath) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.json');

  String _legacyFallbackBackupPathFor(String videoPath, String lang) =>
      p.join(fallbackDir, '${p.basename(videoPath)}.subtitler.$lang.json');

  /// Возвращает сессию, только если отпечаток совпал с [actual]; если
  /// подходят и файл рядом с видео, и запасной — более свежий.
  /// Сессии прежних схем читаются (см. [Session.fromJson]). В запасной
  /// папке ищется и сессия, записанная, когда путь к видео был другим
  /// (см. [_otherPathFallbacks]).
  ///
  /// Сессия привязывается к [videoPath] — пути, по которому её открыли,
  /// а не к записанному внутри JSON (см. [_loadFreshest]).
  Future<Session?> load(String videoPath, SourceFingerprint actual) =>
      _loadFreshest(videoPath, [
        sessionPathFor(videoPath),
        fallbackPathFor(videoPath),
        _legacyFallbackPathFor(videoPath),
        ..._otherPathFallbacks(videoPath, 'subtitler.json', _fallbackNames()),
      ], actual);

  /// Пишет сессию и возвращает фактический путь.
  Future<String> save(Session session) => _write(
        session,
        sessionPathFor(session.videoPath),
        fallbackPathFor(session.videoPath),
      );

  /// Кладёт [session] в резервную копию для её языка и возвращает путь.
  /// Прежняя копия того же языка заменяется: она старше.
  Future<String> saveBackup(Session session) => _write(
        session,
        backupPathFor(session.videoPath, session.lang),
        fallbackBackupPathFor(session.videoPath, session.lang),
      );

  /// Резервная копия для [lang], если она есть и относится к этому же файлу.
  /// Ищется так же, как основная сессия (см. [load]).
  Future<Session?> loadBackup(
    String videoPath,
    String lang,
    SourceFingerprint actual,
  ) =>
      _loadBackup(videoPath, lang, actual, _fallbackNames());

  Future<Session?> _loadBackup(
    String videoPath,
    String lang,
    SourceFingerprint actual,
    List<String> fallbackNames,
  ) async {
    final session = await _loadFreshest(videoPath, [
      backupPathFor(videoPath, lang),
      fallbackBackupPathFor(videoPath, lang),
      _legacyFallbackBackupPathFor(videoPath, lang),
      ..._otherPathFallbacks(
          videoPath, 'subtitler.$lang.json', fallbackNames),
    ], actual);
    // Копию могли переименовать руками — язык внутри важнее имени файла.
    return session?.lang == lang ? session : null;
  }

  /// Все резервные копии этого файла: язык → сессия. Копия может быть
  /// недоделанной — обработку на этом языке остановили, — поэтому «готово»
  /// в меню «Не тот язык?» решает не само наличие копии, а её полнота.
  Future<Map<String, Session>> loadBackups(
    String videoPath,
    SourceFingerprint actual,
  ) async {
    // Запасная папка общая для всех видео — просматривается один раз, а
    // не для каждого языка.
    final names = _fallbackNames();
    final found = <String, Session>{};
    for (final lang in kLanguageCodes) {
      final backup = await _loadBackup(videoPath, lang, actual, names);
      if (backup != null) found[lang] = backup;
    }
    return found;
  }

  /// Языки, для которых есть резервная копия (любая, и недоделанная).
  Future<Set<String>> backupLanguages(
    String videoPath,
    SourceFingerprint actual,
  ) async =>
      (await loadBackups(videoPath, actual)).keys.toSet();

  /// Смена языка без оплаты: если для [lang] есть резервная копия, она
  /// становится основной сессией, а [current] уходит в свою копию.
  ///
  /// Возвращает восстановленную сессию или `null`, если копии нет —
  /// тогда ничего не записывается, и распознавать придётся заново
  /// (`Pipeline.process` с `resumeFrom: current`).
  ///
  /// Язык теперь выбран человеком: уверенность сбрасывается в `null`,
  /// вторым языком становится тот, с которого переключились. Пробы обеих
  /// сессий объединяются — за все уже заплачено.
  ///
  /// Копия ищется и пишется по `current.videoPath`, восстановленная
  /// сессия привязана к нему же.
  Future<Session?> swapWithBackup(Session current, String lang) async {
    if (lang == current.lang) return null;
    final backup =
        await loadBackup(current.videoPath, lang, current.fingerprint);
    if (backup == null) return null;

    await saveBackup(current);
    final restored = backup.copyWith(
      langConfidence: null,
      langRunnerUp: current.lang,
      probeTexts: mergeProbeTexts(backup.probeTexts, current.probeTexts),
    );
    await save(restored);
    return restored;
  }

  /// Самая свежая из подходящих сессий по [paths].
  ///
  /// Файл может быть и рядом с видео, и в запасной папке: сессию создали,
  /// пока в папку видео можно было писать, а потом папку записали на диск
  /// или защитили от записи — правки ушли в запасную папку, а файл рядом
  /// с видео остался прежним. Первый попавшийся вернул бы старый текст, и
  /// правки молча пропали бы. Поля времени в схеме нет, поэтому сравнивается
  /// время изменения файла. На Windows Dart отдаёт его с точностью до
  /// секунды (проверено прогоном); при равенстве берётся файл, стоящий в
  /// [paths] раньше, — обычное место рядом с видео.
  ///
  /// Возвращённая сессия привязана к [videoPath]. Отпечаток — только размер
  /// и длительность, путь в него не входит: сессия подходит и видео,
  /// которое перенесли вместе с ней (скопировали папку дела, флешка
  /// получила другую букву диска). Внутри JSON при этом прежний путь, и
  /// всё, что пишется по `session.videoPath`, — правки, .srt, резервные
  /// копии языков — уходило бы к прежнему месту: в чужую копию вещдока
  /// или, если его уже нет, в запасную папку с ложной плашкой «рядом с
  /// видео записать нельзя».
  Future<Session?> _loadFreshest(String videoPath, List<String> paths,
      SourceFingerprint actual) async {
    Session? freshest;
    DateTime? freshestTime;
    for (final path in paths) {
      final file = File(path);
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      final (session, problem) = await _read(file);
      if (session == null) {
        // Битый файл или схема новее нашей — как будто сессии нет. Затирать
        // его не будем: см. [_keepUnreadable].
        log.warn('Файл сессии $path не читается: ${_describe(problem)}');
        continue;
      }
      _checked.add(path);
      if (!session.fingerprint.matches(actual)) continue;
      if (freshestTime == null || stat.modified.isAfter(freshestTime)) {
        freshest = session;
        freshestTime = stat.modified;
      }
    }
    return freshest?.copyWith(videoPath: videoPath);
  }

  Future<String> _write(Session session, String primary, String fallback) async {
    final content = const JsonEncoder.withIndent(' ').convert(session.toJson());
    try {
      await _replace(primary, content);
      return primary;
    } on FileSystemException {
      Directory(fallbackDir).createSync(recursive: true);
      await _replace(fallback, content);
      return fallback;
    }
  }

  /// Пишет файл целиком или никак.
  ///
  /// `writeAsString` открывает файл в режиме [FileMode.write], и тот
  /// обнуляется ещё до записи данных. Закрыли окно или программа упала
  /// в этот момент — остаётся пустой файл: сессии «нет», ролик
  /// распознаётся заново за деньги, ручные правки пропали. Поэтому
  /// данные пишутся во временный файл рядом, а на место встают
  /// переименованием: на Windows это `MoveFileExW` с
  /// `MOVEFILE_REPLACE_EXISTING` (runtime/bin/file_win.cc в Dart SDK), в
  /// Unix — `rename`; прежний файл заменяется целиком.
  ///
  /// Переименование отклоняется (код 5), если прежний файл «только для
  /// чтения» или его держит другая программа без права удаления, —
  /// проверено на Windows. Тогда, как и при отказе прямой записи,
  /// сессия уходит в запасную папку, а временный файл удаляется.
  Future<void> _replace(String path, String content) async {
    await _keepUnreadable(path);
    final temp = File('$path.tmp');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(path);
    } on FileSystemException {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Не удалось убрать за собой — не повод терять саму запись.
      }
      rethrow;
    }
    _checked.add(path);
  }

  /// Пути, которые в этом запуске уже прочитаны как сессия или записаны
  /// нами: проверять их перед заменой ещё раз незачем.
  final Set<String> _checked = {};

  /// Не затирает файл сессии, который есть, но не читается: записан более
  /// новой версией программы (у коллеги в общей папке дела), обрезан
  /// сбоем, испорчен. В нём могут быть оплаченное распознавание и ручные
  /// правки. Такой файл откладывается под именем
  /// `<имя>.subtitler.broken-<время>.json` — его можно открыть новой
  /// версией или восстановить, — это пишется в журнал, а работа идёт
  /// дальше с новой сессией.
  ///
  /// Если отложить не удалось, [FileSystemException] уходит выше: запись
  /// в этот путь не делается, сессия уходит в запасную папку.
  Future<void> _keepUnreadable(String path) async {
    if (_checked.contains(path)) return;
    final file = File(path);
    if (file.statSync().type != FileSystemEntityType.file) return;
    final (session, problem) = await _read(file);
    if (session != null) {
      _checked.add(path);
      return;
    }
    final aside = _asidePathFor(path);
    final why = _describe(problem);
    try {
      await file.rename(aside);
    } on FileSystemException catch (e) {
      log.warn('Файл сессии $path не читается ($why), и отложить его '
          'не удалось ($e) — не затираем, пишем в другое место');
      rethrow;
    }
    log.warn('Файл сессии $path не читается ($why) — он сохранён как '
        '$aside, записываем новую сессию');
  }

  /// Почему файл не читается — для журнала: вид ошибки и место, без
  /// содержимого файла. `FormatException.toString()` приводит строку
  /// исходного текста у места ошибки (dart:core, FormatException), а у
  /// обрезанного файла это обычно перевод, правка следователя или
  /// распознанная речь. `ArgumentError.toString()` приводит само неверное
  /// значение. Журнал сохраняют и отправляют разработчику, его хвост
  /// попадает в «Технические детали» — текста дела там быть не должно.
  /// У `TypeError` в тексте только названия типов (проверено прогоном).
  static String _describe(Object? problem) => switch (problem) {
        FormatException(:final message, :final offset) =>
          'FormatException: $message'
              '${offset == null ? '' : ' (позиция $offset)'}',
        ArgumentError(:final message) => 'ArgumentError: $message',
        TypeError() => 'TypeError: $problem',
        _ => '${problem.runtimeType}',
      };

  /// `clip.mp4.subtitler.json` → `clip.mp4.subtitler.broken-20260925-184500.json`.
  static String _asidePathFor(String path) {
    final stem =
        path.endsWith('.json') ? path.substring(0, path.length - 5) : path;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var aside = '$stem.broken-$stamp.json';
    // Переименование поверх существующего файла его заменило бы.
    for (var n = 2; File(aside).existsSync(); n++) {
      aside = '$stem.broken-$stamp-$n.json';
    }
    return aside;
  }

  /// Сессия из [file] или `null` с причиной, если файл не читается как
  /// сессия: обрезан (FormatException из jsonDecode), схема новее нашей
  /// (FormatException из [Session.fromJson]), не те типы полей
  /// (TypeError), неизвестное значение статуса или пометки
  /// (ArgumentError). Ошибка чтения самого файла ([FileSystemException])
  /// уходит выше.
  static Future<(Session?, Object?)> _read(File file) async {
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (Session.fromJson(json), null);
    } on FormatException catch (e) {
      return (null, e);
    } on TypeError catch (e) {
      return (null, e);
    } on ArgumentError catch (e) {
      return (null, e);
    }
  }
}

/// Объединяет пробные распознавания двух сессий одного файла.
/// При совпадении реплики берётся текст из [b].
Map<String, Map<int, String>> mergeProbeTexts(
  Map<String, Map<int, String>> a,
  Map<String, Map<int, String>> b,
) {
  final merged = <String, Map<int, String>>{};
  for (final source in [a, b]) {
    for (final entry in source.entries) {
      (merged[entry.key] ??= {}).addAll(entry.value);
    }
  }
  return merged;
}
