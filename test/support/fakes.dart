/// Подделки облака и окружения, общие для тестов ядра и контроллера.
///
/// Тексты во всех подделках выдуманные: настоящих материалов из работы в
/// тестах нет и быть не должно.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/app/key_store.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/cloud/api_errors.dart';
import 'package:subtitler/core/cloud/speechkit_client.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/ffmpeg/ffmpeg_runner.dart';

/// Подставной STT: отдаёт заранее заданные тексты по порядку и считает вызовы.
///
/// [failCalls] первых обращений падают с [failWith]. Считаются именно
/// обращения, а не сегменты: чтобы сегмент действительно провалился,
/// уронить надо все его попытки, иначе повтор молча всё починит и тест
/// проверит не то, что заявлено.
class FakeStt implements SpeechKitClient {
  final List<String> texts;
  int calls = 0;
  int failCalls = 0;
  Object? failWith;

  FakeStt(this.texts);

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    calls++;
    if (calls <= failCalls) throw failWith!;
    final index = calls - failCalls - 1;
    return index < texts.length ? texts[index] : '';
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

/// Подставной STT для определения языка: ответ зависит от пары
/// (язык, реплика), а не от порядка вызовов — порядок проб меняется
/// вместе с алгоритмом, и тест не должен на него опираться.
///
/// Какая это реплика, узнаём по байтам: сравниваем тело запроса с файлами
/// сегментов `seg_NNN.ogg` где угодно внутри [workDir] — это рабочая
/// папка одного прогона или общая папка всех рабочих папок приложения.
class ScriptedStt implements SpeechKitClient {
  final String workDir;
  final Map<String, Map<int, String>> texts;

  /// Пары (язык, реплика), на которых сервис отвечает ошибкой всегда —
  /// то есть и на все повторы.
  final Set<(String, int)> failing;
  final List<(String, int)> calls = [];

  ScriptedStt(this.workDir, this.texts, {this.failing = const {}});

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    // Проверка ключа шлёт полсекунды тишины, а не сегмент ролика.
    if (_sameBytes(oggBytes, probeOgg)) return '';
    final cue = _cueIndexOf(oggBytes);
    calls.add((lang, cue));
    if (failing.contains((lang, cue))) {
      throw const TransientException(statusCode: 500, message: 'boom');
    }
    return texts[lang]?[cue] ?? '';
  }

  static final _segment = RegExp(r'seg_(\d+)\.ogg$');

  int _cueIndexOf(List<int> bytes) {
    final files = Directory(workDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => _segment.hasMatch(f.path));
    for (final file in files) {
      if (_sameBytes(file.readAsBytesSync(), bytes)) {
        return int.parse(_segment.firstMatch(file.path)!.group(1)!);
      }
    }
    throw StateError('Запрос не совпал ни с одним сегментом');
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<(String, int)> callsFor(String lang) =>
      calls.where((c) => c.$1 == lang).toList();

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

/// Держит [gateAt]-й запрос, пока тест не вызовет [release]: так тест
/// нажимает «Отмена» ровно в тот момент, когда запрос уже ушёл.
class GatedStt implements SpeechKitClient {
  final SpeechKitClient inner;
  final int gateAt;
  final _reached = Completer<void>();
  final _gate = Completer<void>();
  int calls = 0;

  GatedStt(this.inner, {this.gateAt = 1});

  /// Запрос номер [gateAt] ушёл и ждёт.
  Future<void> get reached => _reached.future;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String> recognize({
    required List<int> oggBytes,
    required String lang,
  }) async {
    calls++;
    if (calls == gateAt) {
      _reached.complete();
      await _gate.future;
    }
    return inner.recognize(oggBytes: oggBytes, lang: lang);
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

class FakeTranslate implements TranslateClient {
  int calls = 0;
  List<String> lastTexts = const [];

  /// Если задано — каждый вызов падает с этим исключением.
  Object? failWith;

  @override
  Future<List<String>> translate({
    required List<String> texts,
    required String sourceLang,
  }) async {
    calls++;
    lastTexts = texts;
    if (failWith != null) throw failWith!;
    return texts.map((t) => 'RU:$t').toList();
  }

  @override
  Dio get dio => throw UnimplementedError();
  @override
  String get apiKey => 'fake';
  @override
  String get baseUrl => 'fake';
}

/// Хранилище ключа в памяти. Умеет ломаться так, как ломаются настоящие:
/// не читается после переустановки ОС, не пишет, не проходит самопроверку.
class MemoryKeyStore implements KeyStore {
  String? value;
  bool failRead = false;
  bool failWrite = false;
  bool selfTestResult = true;
  int writes = 0;

  MemoryKeyStore([this.value]);

  @override
  String get description => 'память теста';

  @override
  Future<String?> read() async {
    if (failRead) throw const FileSystemException('хранилище не читается');
    return value;
  }

  @override
  Future<void> write(String newValue) async {
    if (failWrite) throw const FileSystemException('хранилище не пишет');
    writes++;
    value = newValue;
  }

  @override
  Future<void> clear() async => value = null;

  @override
  Future<bool> selfTest() async => selfTestResult;
}

class MemorySettingsStore implements SettingsStore {
  AppSettings value;
  int saves = 0;

  MemorySettingsStore([this.value = const AppSettings()]);

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    saves++;
    value = settings;
  }
}

/// Настоящий ffmpeg с записью вызовов и крючками для вшивания.
class RecordingRunner implements StoppableFfmpegRunner {
  final FfmpegRunner inner;
  final List<List<String>> calls = [];

  /// Позиции (в секундах), которые сообщить как прогресс вшивания до
  /// настоящего запуска: у короткого тестового ролика ffmpeg успевает
  /// закончить раньше, чем пришлёт промежуточный прогресс.
  List<double> burnProgress = const [];

  /// Вызывается перед вшиванием — например, чтобы прочитать SRT, который
  /// в этот момент уходит в ffmpeg.
  void Function(List<String> args)? onBurn;

  /// Подменяет команду вшивания.
  List<String> Function(List<String> args)? rewriteBurn;

  /// Подменяет итог вшивания: вернула не `null` — ffmpeg не запускается,
  /// вызов сразу получает этот итог (например, «нет доступа к папке»).
  FfmpegResult? Function(List<String> args)? answerBurn;

  /// Подменяет любую команду, не только вшивание (после [rewriteBurn]).
  List<String> Function(List<String> args)? rewrite;

  RecordingRunner(this.inner);

  static bool isBurn(List<String> args) =>
      args.any((a) => a.startsWith('subtitles='));

  int get burnCalls => calls.where(isBurn).length;

  @override
  Future<FfmpegResult> run(
    List<String> args, {
    void Function(double seconds)? onProgress,
  }) async {
    calls.add(args);
    var actual = args;
    if (isBurn(args)) {
      onBurn?.call(args);
      final answer = answerBurn?.call(args);
      if (answer != null) return answer;
      for (final position in burnProgress) {
        onProgress?.call(position);
      }
      actual = rewriteBurn?.call(args) ?? args;
    }
    actual = rewrite?.call(actual) ?? actual;
    return inner.run(actual, onProgress: onProgress);
  }

  @override
  Future<double> probeDuration(String path) => inner.probeDuration(path);

  @override
  Future<void> stopAll() async {
    final runner = inner;
    if (runner is StoppableFfmpegRunner) {
      await runner.stopAll();
    }
  }
}

/// ffmpeg читает вход со скоростью воспроизведения (`-re`): пятнадцать
/// секунд тестового ролика обрабатываются пятнадцать секунд. Так тест
/// успевает закрыть окно посреди работы.
List<String> inRealTime(List<String> args) => [
      for (final arg in args) ...[if (arg == '-i') '-re', arg],
    ];

/// Вшивание без libass: фильтр субтитров заменён пустым. ffmpeg выходит с
/// кодом 0, а текста в кадре нет — ровно тот сбой, ради которого есть
/// проверка видимости.
List<String> withoutSubtitles(List<String> args) => [
      for (final arg in args) arg.startsWith('subtitles=') ? 'null' : arg,
    ];
