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

  /// Буквы и сочетания, которые в этом языке есть, а в большинстве
  /// соседних — нет. Пусто, если отличительных признаков не нашлось
  /// (английский, нидерландский): такой язык просто не получает бонуса
  /// при автоопределении, и решать будет человек.
  final Set<String> markers;

  const SpeechLanguage({
    required this.sttCode,
    required this.name,
    required this.translateCode,
    required this.script,
    this.markers = const {},
  });
}

/// Все языки модели `general` синхронного распознавания SpeechKit v1
/// (сверено с документацией 2026-09-11). Добавление языка — одна строка;
/// менять что-то ещё в коде не нужно.
///
/// Значения `auto` в v1 нет: автоопределение языка есть только в API v3
/// и только для потокового распознавания. Поэтому язык мы либо определяем
/// сами пробами, либо спрашиваем.
const List<SpeechLanguage> kLanguages = [
  SpeechLanguage(
    sttCode: 'ru-RU',
    name: 'русский',
    translateCode: 'ru',
    script: Script.cyrillic,
    markers: {'ы', 'э', 'ъ', 'ё', 'щ'},
  ),
  SpeechLanguage(
    sttCode: 'tr-TR',
    name: 'турецкий',
    translateCode: 'tr',
    script: Script.latin,
    markers: {'ğ', 'ı', 'ş', 'ç'},
  ),
  SpeechLanguage(
    // Распознавание отдаёт узбекский ТОЛЬКО латиницей; кода для кириллицы
    // в SpeechKit нет. У переводчика кириллический узбекский — отдельный
    // язык 'uzbcyr', он понадобится, только если текст перепишут вручную.
    sttCode: 'uz-UZ',
    name: 'узбекский',
    translateCode: 'uz',
    script: Script.latin,
    markers: {'ʻ', 'sh', 'ch', 'q', 'x'},
  ),
  SpeechLanguage(
    sttCode: 'kk-KZ',
    name: 'казахский',
    translateCode: 'kk',
    script: Script.cyrillic,
    markers: {'ә', 'ғ', 'қ', 'ң', 'ө', 'ұ', 'ү', 'һ', 'і'},
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
    markers: {'ß', 'ä'},
  ),
  SpeechLanguage(
    sttCode: 'fr-FR',
    name: 'французский',
    translateCode: 'fr',
    script: Script.latin,
    markers: {'é', 'è', 'ê', 'à', 'ù', 'œ'},
  ),
  SpeechLanguage(
    sttCode: 'es-ES',
    name: 'испанский',
    translateCode: 'es',
    script: Script.latin,
    markers: {'ñ', '¿', '¡'},
  ),
  SpeechLanguage(
    sttCode: 'it-IT',
    name: 'итальянский',
    translateCode: 'it',
    script: Script.latin,
    markers: {'ì', 'ò', 'gli'},
  ),
  SpeechLanguage(
    sttCode: 'pt-PT',
    name: 'португальский',
    translateCode: 'pt',
    script: Script.latin,
    markers: {'ã', 'õ', 'ç'},
  ),
  SpeechLanguage(
    // Отдельная модель распознавания, но переводчику отдаём базовый 'pt':
    // документация не подтверждает, что 'pt-BR' принимается как язык
    // источника, а базовый код принимается точно.
    sttCode: 'pt-BR',
    name: 'португальский (Бразилия)',
    translateCode: 'pt',
    script: Script.latin,
    markers: {'ã', 'õ', 'ç'},
  ),
  SpeechLanguage(
    sttCode: 'pl-PL',
    name: 'польский',
    translateCode: 'pl',
    script: Script.latin,
    markers: {'ł', 'ą', 'ę', 'ś', 'ż', 'ź', 'ć'},
  ),
  SpeechLanguage(
    sttCode: 'nl-NL',
    name: 'нидерландский',
    translateCode: 'nl',
    script: Script.latin,
    markers: {'ij'},
  ),
  SpeechLanguage(
    sttCode: 'fi-FI',
    name: 'финский',
    translateCode: 'fi',
    script: Script.latin,
    markers: {'ää', 'öö', 'yy', 'kk', 'tt'},
  ),
  SpeechLanguage(
    sttCode: 'sv-SE',
    name: 'шведский',
    translateCode: 'sv',
    script: Script.latin,
    markers: {'å'},
  ),
  SpeechLanguage(
    sttCode: 'he-IL',
    name: 'иврит',
    translateCode: 'he',
    script: Script.hebrew,
    markers: {'א', 'ב', 'ש', 'ת', 'ל'},
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

/// С чего начинать автоопределение, если пользователь ничего не выбрал.
/// Проверять все шестнадцать языков дорого и бессмысленно: каждая проба —
/// это платный запрос, а чем больше похожих кандидатов, тем реже
/// определение вообще даёт уверенный ответ.
const List<String> kDefaultDetectionCandidates = ['tr-TR', 'uz-UZ', 'ru-RU'];
