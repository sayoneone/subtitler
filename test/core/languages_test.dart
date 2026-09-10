import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/cloud/translate_client.dart';
import 'package:subtitler/core/languages.dart';

void main() {
  test('Все 16 языков модели general на месте', () {
    expect(kLanguages.length, 16);
    for (final code in [
      'ru-RU', 'en-US', 'tr-TR', 'uz-UZ', 'de-DE', 'es-ES', 'fi-FI', 'fr-FR',
      'he-IL', 'it-IT', 'kk-KZ', 'nl-NL', 'pl-PL', 'pt-PT', 'pt-BR', 'sv-SE',
    ]) {
      expect(languageByCode(code), isNotNull, reason: 'нет языка $code');
    }
  });

  test('Коды распознавания и перевода не перепутаны', () {
    expect(toTranslateCode('tr-TR'), 'tr');
    expect(toTranslateCode('ru-RU'), 'ru');
    expect(toTranslateCode('kk-KZ'), 'kk');
    // Узбекский у переводчика — латиница; кириллический там отдельный язык.
    expect(toTranslateCode('uz-UZ'), 'uz');
    // Бразильский португальский переводим базовым кодом: 'pt-BR' как язык
    // источника документация не подтверждает.
    expect(toTranslateCode('pt-BR'), 'pt');
    expect(toTranslateCode('pt-PT'), 'pt');
    expect(() => toTranslateCode('xx-XX'), throwsA(isA<ArgumentError>()));
  });

  test('Коды уникальны, названия заполнены', () {
    final codes = kLanguages.map((l) => l.sttCode).toSet();
    expect(codes.length, kLanguages.length, reason: 'есть дубликаты кодов');
    for (final language in kLanguages) {
      expect(language.name.trim(), isNotEmpty);
      expect(language.translateCode.trim(), isNotEmpty);
    }
  });

  test('Набор для автоопределения по умолчанию — из настоящих языков', () {
    for (final code in kDefaultDetectionCandidates) {
      expect(languageByCode(code), isNotNull);
    }
  });
}
