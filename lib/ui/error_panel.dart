import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/user_error.dart';
import 'log_actions.dart';
import 'strings.dart';

/// Сообщение об ошибке для человека: что случилось, что делать, кнопка по
/// смыслу. Сырой текст — только в свёрнутых «Технических деталях»:
/// следователю он ничего не скажет, а разработчику нужен целиком.
class ErrorPanel extends StatelessWidget {
  final UserError error;

  /// Кнопки под подсказкой: действие по смыслу ошибки и запасной выход.
  final List<Widget> actions;

  /// Сырой текст для «Технических деталей».
  final String details;

  /// «Сохранить журнал» в деталях; `null` — кнопки нет.
  final VoidCallback? onSaveLog;
  final String saveLogLabel;

  /// Мелкая строка над заголовком — например, имя видео.
  final String? caption;

  final IconData icon;

  const ErrorPanel({
    super.key,
    required this.error,
    required this.details,
    this.actions = const [],
    this.onSaveLog,
    this.saveLogLabel = AppStrings.saveLog,
    this.caption,
    this.icon = Icons.error_outline,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              if (caption != null) ...[
                Text(caption!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(height: 4),
              ],
              Text(error.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(error.hint, style: theme.textTheme.bodyLarge),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(spacing: 12, runSpacing: 8, children: actions),
              ],
              const SizedBox(height: 24),
              TechnicalDetails(
                text: details,
                onSaveLog: onSaveLog,
                saveLogLabel: saveLogLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Свёрнутые «Технические детали»: сырой текст, «Скопировать» и
/// «Сохранить журнал». Пока блок свёрнут, текста нет даже в дереве
/// виджетов.
class TechnicalDetails extends StatelessWidget {
  final String text;
  final VoidCallback? onSaveLog;
  final String saveLogLabel;

  const TechnicalDetails({
    super.key,
    required this.text,
    this.onSaveLog,
    this.saveLogLabel = AppStrings.saveLog,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text(AppStrings.technicalDetails),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.all(8),
            color: theme.colorScheme.surfaceContainerHighest,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            TextButton.icon(
              onPressed: () => unawaited(copyText(context, text)),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text(AppStrings.copy),
            ),
            if (onSaveLog != null)
              TextButton.icon(
                onPressed: onSaveLog,
                icon: const Icon(Icons.save_alt, size: 18),
                label: Text(saveLogLabel),
              ),
          ]),
        ],
      ),
    );
  }
}

/// Текст «Технических деталей»: сырая ошибка и последние записи журнала
/// (ключ в них уже замаскирован).
String technicalText(UserError error, AppController c) {
  final log = c.recentLog();
  return [
    if (error.details.isNotEmpty) error.details,
    if (log.isNotEmpty) '${AppStrings.recentLog}\n$log',
  ].join('\n\n');
}

/// Этап [AppStage.broken]: без ffmpeg (или без папок программы) работать
/// нельзя. Что именно искали и где — в «Технических деталях».
class BrokenView extends StatelessWidget {
  final AppController controller;
  const BrokenView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final error = c.error ??
        UserError(
          title: AppStrings.brokenTitle,
          hint: AppStrings.brokenHint,
          details: c.ffmpegReport,
        );
    void save() => unawaited(saveLogAndShow(context, c));
    return ErrorPanel(
      error: error,
      icon: Icons.build_circle_outlined,
      details: technicalText(error, c),
      actions: [
        FilledButton.icon(
          onPressed: save,
          icon: const Icon(Icons.save_alt),
          label: Text(saveLogLabel(c)),
        ),
      ],
      onSaveLog: save,
      saveLogLabel: saveLogLabel(c),
    );
  }
}

/// Этап [AppStage.failed]: обработка упала. Кнопка по смыслу ошибки и
/// всегда — выход на главный экран.
class FailedView extends StatelessWidget {
  final AppController controller;
  const FailedView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final error = c.error ??
        const UserError(
          title: AppStrings.failedTitle,
          hint: AppStrings.failedHint,
          action: UserErrorAction.retry,
        );
    final busy = c.isBusy;
    VoidCallback? act(UserErrorAction action) => busy
        ? null
        : switch (action) {
            UserErrorAction.retry => () => unawaited(c.retry()),
            UserErrorAction.changeKey => c.changeKey,
            UserErrorAction.home => () => unawaited(c.goHome()),
            UserErrorAction.none => null,
          };
    return ErrorPanel(
      error: error,
      caption: c.videoName,
      details: technicalText(error, c),
      actions: [
        if (error.action != UserErrorAction.none)
          FilledButton(
            onPressed: act(error.action),
            child: Text(error.action.label),
          ),
        if (error.action != UserErrorAction.home)
          OutlinedButton(
            onPressed: act(UserErrorAction.home),
            child: const Text(AppStrings.goHome),
          ),
      ],
      onSaveLog: () => unawaited(saveLogAndShow(context, c)),
      saveLogLabel: saveLogLabel(c),
    );
  }
}
