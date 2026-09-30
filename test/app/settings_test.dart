import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/languages.dart';
import 'package:subtitler/core/logging.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('settings_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('По умолчанию — турецкий и узбекский, языка прошлой обработки нет', () {
    const settings = AppSettings();
    expect(settings.detectionCandidates, kDefaultDetectionCandidates);
    expect(settings.lastLanguage, isNull);
  });

  test('Файл настроек: записали — прочитали то же самое', () async {
    final store = FileSettingsStore(p.join(tmp.path, 'a', 'settings.json'),
        log: DebugLog());
    await store.save(const AppSettings(
        detectionCandidates: ['uz-UZ', 'kk-KZ'], lastLanguage: 'uz-UZ'));
    final loaded = await FileSettingsStore(
            p.join(tmp.path, 'a', 'settings.json'),
            log: DebugLog())
        .load();
    expect(loaded.detectionCandidates, ['uz-UZ', 'kk-KZ']);
    expect(loaded.lastLanguage, 'uz-UZ');
  });

  test('Файла нет — настройки по умолчанию', () async {
    final loaded =
        await FileSettingsStore(p.join(tmp.path, 'нет.json'), log: DebugLog())
            .load();
    expect(loaded.detectionCandidates, kDefaultDetectionCandidates);
  });

  test('Испорченный файл не мешает работе', () async {
    final path = p.join(tmp.path, 'settings.json');
    File(path).writeAsStringSync('{не json');
    final log = DebugLog();
    final loaded = await FileSettingsStore(path, log: log).load();
    expect(loaded.detectionCandidates, kDefaultDetectionCandidates);
    expect(log.asText(), contains('испорчен'));
  });

  test('Неизвестные коды выбрасываются, пустой набор — набор по умолчанию', () {
    expect(
        AppSettings.fromJson(jsonDecode(
                '{"detectionCandidates": ["xx-XX", "tr-TR", "tr-TR", 5],'
                ' "lastLanguage": "yy"}') as Map<String, dynamic>)
            .detectionCandidates,
        ['tr-TR']);
    final empty = AppSettings.fromJson(
        jsonDecode('{"detectionCandidates": []}') as Map<String, dynamic>);
    expect(empty.detectionCandidates, kDefaultDetectionCandidates);
    expect(empty.lastLanguage, isNull);
  });
}
