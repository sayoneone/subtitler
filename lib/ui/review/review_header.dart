import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models.dart';
import 'review_plate.dart';

/// Пометка пункта меню «Не тот язык?»: бесплатно ли переключение.
String languageChoiceMark(LanguageChoice choice) =>
    choice.ready ? 'готово — переключить' : 'распознать заново — оплачивается';

/// Значение пункта «Другой язык…» в меню — не код языка.
const String _otherLanguage = '…';

/// Шапка предпросмотра: «Реплик N · проверить M» и «Язык: турецкий · Не тот
/// язык?».
class ReviewHeader extends StatelessWidget {
  const ReviewHeader({
    super.key,
    required this.total,
    required this.toCheck,
    required this.languageTitle,
    required this.choices,
    required this.allChoices,
    required this.hasEdits,
    required this.enabled,
    required this.onSwitch,
    this.onNextToCheck,
  });

  final int total;
  final int toCheck;

  /// «турецкий».
  final String languageTitle;

  /// Меню: второй язык первым, затем языки из настроек и уже распознанные
  /// (`AppController.languageChoices`).
  final List<LanguageChoice> choices;

  /// «Другой язык…»: все, кроме текущего.
  final List<LanguageChoice> allChoices;

  /// В этом варианте есть ручные правки — при смене языка они остаются в
  /// резервной копии, а новый вариант их не получит. Меню предупреждает.
  final bool hasEdits;

  /// Сменить язык сейчас можно (ничего не сохраняется и не переключается).
  final bool enabled;

  final ValueChanged<String> onSwitch;

  /// «Следующая на проверку»; `null` — кнопки нет.
  final VoidCallback? onNextToCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        // Wrap, а не Row: на телефоне шапка не помещается в строку.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              toCheck > 0
                  ? 'Реплик $total · проверить $toCheck'
                  : 'Реплик $total',
              style: theme.textTheme.titleMedium,
            ),
            if (onNextToCheck != null && toCheck > 0)
              IconButton(
                tooltip: 'Следующая на проверку',
                icon: const Icon(Icons.arrow_downward),
                onPressed: onNextToCheck,
              ),
          ],
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Язык: $languageTitle', style: theme.textTheme.bodyLarge),
            Text(
              ' · ',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('review-language-menu'),
              enabled: enabled,
              tooltip: 'Распознать ролик на другом языке',
              onSelected: (value) => value == _otherLanguage
                  ? _pickOther(context)
                  : onSwitch(value),
              itemBuilder: (context) => [
                if (hasEdits)
                  PopupMenuItem<String>(
                    enabled: false,
                    child: SizedBox(
                      width: 280,
                      child: Text(
                        'Ваши правки останутся в варианте «$languageTitle» — '
                        'к нему можно вернуться через это же меню',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                for (final choice in choices)
                  PopupMenuItem<String>(
                    value: choice.code,
                    child: _ChoiceLabel(choice),
                  ),
                if (choices.isNotEmpty) const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: _otherLanguage,
                  child: Text('Другой язык…'),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Не тот язык?',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                    decoration: TextDecoration.underline,
                    decorationColor: enabled
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickOther(BuildContext context) async {
    final code = await showDialog<String>(
      context: context,
      builder: (context) => OtherLanguageDialog(choices: allChoices),
    );
    if (code != null) onSwitch(code);
  }
}

class _ChoiceLabel extends StatelessWidget {
  const _ChoiceLabel(this.choice);

  final LanguageChoice choice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(choice.name),
        Text(
          languageChoiceMark(choice),
          style: theme.textTheme.bodySmall?.copyWith(
            color: choice.ready
                ? Colors.green.shade800
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// «Другой язык…»: все языки распознавания. Возвращает код выбранного.
class OtherLanguageDialog extends StatelessWidget {
  const OtherLanguageDialog({super.key, required this.choices});

  final List<LanguageChoice> choices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleDialog(
      title: const Text('На каком языке говорят в ролике?'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'Ролик будет распознан заново на выбранном языке — это '
            'оплачивается. Где написано «готово», ролик на этом языке уже '
            'распознан: переключение бесплатное.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final choice in choices)
          SimpleDialogOption(
            key: ValueKey('other-language-${choice.code}'),
            onPressed: () => Navigator.of(context).pop(choice.code),
            child: Row(
              children: [
                Expanded(child: Text(choice.name)),
                if (choice.ready)
                  Text(
                    'готово',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green.shade800,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Жёлтая плашка, когда автомат в языке сомневается: «Скорее всего
/// турецкий. Если перевод выглядит бессмысленным — [Распознать как
/// узбекский]».
class LanguageDoubtPlate extends StatelessWidget {
  const LanguageDoubtPlate({
    super.key,
    required this.languageTitle,
    required this.confidence,
    required this.runnerUp,
    required this.enabled,
    required this.onSwitch,
  });

  final String languageTitle;
  final LanguageConfidence confidence;

  /// Второй по оценке язык, если он есть.
  final LanguageChoice? runnerUp;
  final bool enabled;
  final ValueChanged<String> onSwitch;

  /// Показывать ли плашку вообще: при уверенном выборе и при языке,
  /// выбранном человеком (`null`), сомневаться не в чем.
  static bool shows(LanguageConfidence? confidence) =>
      confidence == LanguageConfidence.low ||
      confidence == LanguageConfidence.none;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final second = runnerUp;
    final text = confidence == LanguageConfidence.none
        ? 'Язык по речи определить не удалось — выбран $languageTitle. '
              'Если перевод выглядит бессмысленным, выберите язык в меню '
              '«Не тот язык?»'
        : 'Скорее всего $languageTitle. Если перевод выглядит '
              'бессмысленным —';
    return ReviewPlate(
      key: const ValueKey('review-language-doubt'),
      color: kPlateYellow,
      icon: Icons.help_outline,
      iconColor: Colors.amber.shade900,
      message: text,
      actions: [
        if (second != null)
          FilledButton.tonal(
            onPressed: enabled ? () => onSwitch(second.code) : null,
            child: Text('Распознать как ${second.name}'),
          ),
        if (second != null)
          Text(
            second.ready ? 'уже готово — бесплатно' : 'оплачивается',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}
