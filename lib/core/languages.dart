/// Письменность, которой распознавание возвращает текст.
enum Script { latin, cyrillic, hebrew }

/// Язык, который умеет распознавать SpeechKit и переводить Translate.
class SpeechLanguage {
  /// Код для распознавания, полный: 'tr-TR'.
  final String sttCode;

  /// Название по-русски, для интерфейса.
  final String name;

  /// Код источника для переводчика: 'tr'. Отличается от кода распознавания
  /// и не всегда получается простым отбрасыванием региона.
  final String translateCode;

  final Script script;

  const SpeechLanguage({
    required this.sttCode,
    required this.name,
    required this.translateCode,
    required this.script,
  });
}

/// Все языки модели `general` синхронного распознавания SpeechKit v1
/// (сверено с документацией 2026-09-11). Добавление языка — одна строка;
/// менять что-то ещё в коде не нужно.
///
/// Значения `auto` в v1 нет: определение языка и языковые метки есть только
/// в API v3 (сверено с aistudio.yandex.ru/docs/ru/speechkit/stt/models
/// 2026-09-25). Ограничено ли оно потоковым режимом, документация не
/// говорит, но единственный её пример — потоковый; живой проверки v3 у нас
/// не было. Поэтому язык мы определяем сами: пробами v1 и оценкой текста
/// (`pipeline/language_detector.dart`).
const List<SpeechLanguage> kLanguages = [
  SpeechLanguage(
    sttCode: 'ru-RU',
    name: 'русский',
    translateCode: 'ru',
    script: Script.cyrillic,
  ),
  SpeechLanguage(
    sttCode: 'tr-TR',
    name: 'турецкий',
    translateCode: 'tr',
    script: Script.latin,
  ),
  SpeechLanguage(
    // Распознавание отдаёт узбекский ТОЛЬКО латиницей; кода для кириллицы
    // в SpeechKit нет. У переводчика кириллический узбекский — отдельный
    // язык 'uzbcyr', он понадобится, только если текст перепишут вручную.
    sttCode: 'uz-UZ',
    name: 'узбекский',
    translateCode: 'uz',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'kk-KZ',
    name: 'казахский',
    translateCode: 'kk',
    script: Script.cyrillic,
  ),
  SpeechLanguage(
    sttCode: 'en-US',
    name: 'английский',
    translateCode: 'en',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'de-DE',
    name: 'немецкий',
    translateCode: 'de',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'fr-FR',
    name: 'французский',
    translateCode: 'fr',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'es-ES',
    name: 'испанский',
    translateCode: 'es',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'it-IT',
    name: 'итальянский',
    translateCode: 'it',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'pt-PT',
    name: 'португальский',
    translateCode: 'pt',
    script: Script.latin,
  ),
  SpeechLanguage(
    // Отдельная модель распознавания, но переводчику отдаём базовый 'pt':
    // документация не подтверждает, что 'pt-BR' принимается как язык
    // источника, а базовый код принимается точно.
    sttCode: 'pt-BR',
    name: 'португальский (Бразилия)',
    translateCode: 'pt',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'pl-PL',
    name: 'польский',
    translateCode: 'pl',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'nl-NL',
    name: 'нидерландский',
    translateCode: 'nl',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'fi-FI',
    name: 'финский',
    translateCode: 'fi',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'sv-SE',
    name: 'шведский',
    translateCode: 'sv',
    script: Script.latin,
  ),
  SpeechLanguage(
    sttCode: 'he-IL',
    name: 'иврит',
    translateCode: 'he',
    script: Script.hebrew,
  ),
];

SpeechLanguage? languageByCode(String sttCode) {
  for (final language in kLanguages) {
    if (language.sttCode == sttCode) return language;
  }
  return null;
}

String languageName(String sttCode) =>
    languageByCode(sttCode)?.name ?? sttCode;

List<String> kLanguageCodes =
    kLanguages.map((l) => l.sttCode).toList(growable: false);

/// Среди каких языков выбирать автоматически, если пользователь ничего не
/// менял в настройках. Каждый язык — это ещё платные пробы, а чем больше
/// похожих кандидатов, тем реже выбор уверенный.
///
/// Только турецкий и узбекский — единственная пара, которую следователь
/// не различит на слух. Русский при оценке по тексту почти не может
/// выиграть (пробы впустую), казахский выигрывает ложно; русскую и
/// казахскую речь человек узнаёт сам и переключает язык в одно нажатие.
const List<String> kDefaultDetectionCandidates = ['tr-TR', 'uz-UZ'];
