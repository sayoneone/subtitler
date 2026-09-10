/// Письменность, которой распознавание возвращает текст.
enum Script { latin, cyrillic, arabic }

/// Язык, который умеет распознавать SpeechKit и переводить Translate.
class SpeechLanguage {
  /// Код для распознавания, полный: 'tr-TR'.
  final String sttCode;

  /// Название по-русски, для интерфейса.
  final String name;

  /// Короткий код для переводчика: 'tr'. У некоторых языков он зависит
  /// от письменности (узбекская латиница — uz, кириллица — uzbcyr).
  final String translateCode;

  final Script script;

  /// Буквы и сочетания, которые в этом языке есть, а в соседних по списку —
  /// как правило нет. Пусто, если отличительных признаков не нашлось:
  /// тогда язык просто не будет получать бонус при автоопределении.
  final Set<String> markers;

  const SpeechLanguage({
    required this.sttCode,
    required this.name,
    required this.translateCode,
    required this.script,
    this.markers = const {},
  });
}

/// Все языки, которые приложение готово распознавать.
/// Список наполняется по документации SpeechKit; добавление языка —
/// одна строка здесь, менять больше ничего не нужно.
const List<SpeechLanguage> kLanguages = [];

SpeechLanguage? languageByCode(String sttCode) {
  for (final language in kLanguages) {
    if (language.sttCode == sttCode) return language;
  }
  return null;
}

String languageName(String sttCode) =>
    languageByCode(sttCode)?.name ?? sttCode;

List<String> get kLanguageCodes =>
    kLanguages.map((l) => l.sttCode).toList(growable: false);
