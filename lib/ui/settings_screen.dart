import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/languages.dart';
import 'log_actions.dart';
import 'strings.dart';

/// «⚙ Настройки»: ключ (заменить или удалить — значение не показывается
/// никогда), языки записей, журнал, «О программе». Сведения об ffmpeg —
/// здесь, в свёрнутых «Технических сведениях», а ещё в «Технических
/// деталях» экрана, где программа сообщает, что компонент обработки видео
/// не найден, неполный или не запускается (`BrokenView`).
class SettingsScreen extends StatelessWidget {
  final AppController controller;

  /// «Открыть журнал»: оболочка закрывает настройки и выдвигает журнал.
  final VoidCallback? onOpenLog;

  const SettingsScreen({super.key, required this.controller, this.onOpenLog});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.settings)),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          children: [
            _KeySection(controller: controller),
            const Divider(height: 40),
            _LanguagesSection(controller: controller),
            const Divider(height: 40),
            _LogSection(controller: controller, onOpenLog: onOpenLog),
            const Divider(height: 40),
            _AboutSection(controller: controller),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _KeySection extends StatelessWidget {
  final AppController controller;
  const _KeySection({required this.controller});

  /// Менять ключ можно, когда программа готова и ничего не делает:
  /// посреди обработки новый ключ всё равно не подхватится.
  bool get _canManage {
    final c = controller;
    return !c.isBusy &&
        const {
          AppStage.needsKey,
          AppStage.home,
          AppStage.review,
          AppStage.cancelled,
          AppStage.failed,
        }.contains(c.stage);
  }

  void _replace(BuildContext context) {
    Navigator.of(context).pop();
    if (controller.stage != AppStage.needsKey) controller.changeKey();
  }

  Future<void> _delete(BuildContext context) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(AppStrings.keyDeleteTitle),
        content: const Text(AppStrings.keyDeleteText),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(AppStrings.keyDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.forgetKey();
    // Без ключа работать нельзя — сразу к экрану ввода ключа.
    if (navigator.mounted && navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final status = !c.hasKey
        ? AppStrings.settingsKeyNone
        : c.keySaved
            ? AppStrings.settingsKeySaved
            : AppStrings.settingsKeySession;
    final canManage = _canManage;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading(AppStrings.keyTitle),
      Text(status),
      if (c.isBusy) ...[
        const SizedBox(height: 4),
        Text(AppStrings.settingsKeyBusy,
            style: Theme.of(context).textTheme.bodySmall),
      ],
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: canManage ? () => _replace(context) : null,
          icon: const Icon(Icons.edit_outlined),
          label: const Text(AppStrings.keyReplace),
        ),
        OutlinedButton.icon(
          onPressed: canManage && c.hasKey
              ? () => unawaited(_delete(context))
              : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text(AppStrings.keyDelete),
        ),
      ]),
    ]);
  }
}

class _LanguagesSection extends StatelessWidget {
  final AppController controller;
  const _LanguagesSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final chosen = c.settings.detectionCandidates;
    final ready = c.stage != AppStage.starting;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading(AppStrings.languagesTitle),
      const Text(AppStrings.languagesHint),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final language in kLanguages)
          FilterChip(
            key: ValueKey('language-${language.sttCode}'),
            label: Text(language.name),
            selected: chosen.contains(language.sttCode),
            onSelected: ready
                ? (_) =>
                    unawaited(c.toggleDetectionCandidate(language.sttCode))
                : null,
          ),
      ]),
      if (chosen.length == 1) ...[
        const SizedBox(height: 8),
        Text(AppStrings.languagesLastOne,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
  }
}

class _LogSection extends StatelessWidget {
  final AppController controller;
  final VoidCallback? onOpenLog;
  const _LogSection({required this.controller, this.onOpenLog});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading(AppStrings.logTitle),
      Wrap(spacing: 12, runSpacing: 8, children: [
        if (onOpenLog != null)
          OutlinedButton.icon(
            onPressed: onOpenLog,
            icon: const Icon(Icons.article_outlined),
            label: const Text(AppStrings.settingsLogOpen),
          ),
        OutlinedButton.icon(
          onPressed: () => unawaited(showLogFile(context, c)),
          icon: const Icon(Icons.folder_open),
          label: Text(logFolderLabel(c)),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(saveLogAndShow(context, c)),
          icon: const Icon(Icons.save_alt),
          label: Text(saveLogLabel(c)),
        ),
      ]),
    ]);
  }
}

class _AboutSection extends StatelessWidget {
  final AppController controller;
  const _AboutSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading(AppStrings.aboutTitle),
      Text(AppStrings.aboutVersion(c.appVersion)),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: const Text(AppStrings.aboutTechnical),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '${c.ffmpegReport}\n${AppStrings.aboutLogFile(c.logFilePath)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    ]);
  }
}
