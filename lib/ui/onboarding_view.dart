import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/key_check.dart';
import '../app/user_error.dart';
import 'error_panel.dart';
import 'strings.dart';

/// Этап [AppStage.needsKey] (§4 спецификации): какой ключ нужен и с какими
/// ролями, поле с маскировкой, «Проверить и сохранить» и по индикатору на
/// каждую роль — перевод и распознавание.
///
/// Значение ключа нигде не показывается. После того как ключ принят, поле
/// очищается: в памяти экрана ключ не задерживается. Отвергнутый ключ
/// остаётся в поле — чтобы можно было исправить опечатку, — но
/// контроллер его не запоминает.
class OnboardingView extends StatefulWidget {
  final AppController controller;
  const OnboardingView({super.key, required this.controller});

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  final _field = TextEditingController();

  AppController get c => widget.controller;

  Future<void> _submit() async {
    if (c.isCheckingKey) return;
    final accepted = await c.submitKey(_field.text);
    if (accepted && mounted) _field.clear();
  }

  @override
  void dispose() {
    _field.clear();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final check = c.keyCheck;
    final checking = c.isCheckingKey;
    final checked = check.translate != CheckState.unknown ||
        check.stt != CheckState.unknown;
    final translateError = check.translateError;
    final sttError = check.sttError;
    // Одна причина на обе проверки (пустой или отозванный ключ, нет сети)
    // — одно сообщение, а не два одинаковых.
    final sameError = translateError != null &&
        sttError != null &&
        translateError.title == sttError.title;
    final details = [
      if (translateError != null && translateError.details.isNotEmpty)
        '${AppStrings.keyCheckTranslate}: ${translateError.details}',
      if (sttError != null && sttError.details.isNotEmpty)
        '${AppStrings.keyCheckStt}: ${sttError.details}',
    ].join('\n');

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.vpn_key_outlined,
                  size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(AppStrings.keyTitle, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(AppStrings.keyIntro),
              const SizedBox(height: 8),
              const _Role(
                  AppStrings.keyRoleStt, AppStrings.keyRoleSttWhat),
              const _Role(AppStrings.keyRoleTranslate,
                  AppStrings.keyRoleTranslateWhat),
              const SizedBox(height: 8),
              Text(AppStrings.keyPrivacy,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 8),
              const _HowTo(),
              const SizedBox(height: 16),
              if (c.keyStorageWorks == false) ...[
                const _Warning(AppStrings.keyStorageBroken),
                const SizedBox(height: 16),
              ],
              TextField(
                key: const ValueKey('key-field'),
                controller: _field,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !checking,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: AppStrings.keyField,
                  hintText: AppStrings.keyFieldHint,
                ),
                onSubmitted: (_) => unawaited(_submit()),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 8, children: [
                FilledButton(
                  onPressed: checking ? null : () => unawaited(_submit()),
                  child: Text(
                      checking ? AppStrings.keyChecking : AppStrings.keySubmit),
                ),
                if (c.canCancelKeyChange)
                  TextButton(
                    onPressed: checking ? null : c.cancelKeyChange,
                    child: const Text(AppStrings.cancel),
                  ),
              ]),
              // До первой проверки индикаторов нет: два пустых кружка без
              // заголовка выглядели как выбор «одно из двух».
              if (checked) ...[
                const SizedBox(height: 16),
                Text(AppStrings.keyCheckTitle,
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                _CheckRow(
                  label: AppStrings.keyCheckTranslate,
                  state: check.translate,
                  error: sameError ? null : translateError,
                ),
                const SizedBox(height: 6),
                _CheckRow(
                  label: AppStrings.keyCheckStt,
                  state: check.stt,
                  error: sameError ? null : sttError,
                ),
              ],
              if (sameError) ...[
                const SizedBox(height: 8),
                _ErrorText(translateError),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 16),
                TechnicalDetails(text: details),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Role extends StatelessWidget {
  final String role;
  final String what;
  const _Role(this.role, this.what);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 8, top: 2),
        child: Text('•  $role — $what'),
      );
}

class _HowTo extends StatelessWidget {
  const _HowTo();

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text(AppStrings.keyHowTo),
      children: [
        for (final (i, step) in AppStrings.keyHowToSteps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SelectableText('${i + 1}. $step'),
          ),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;
  const _Warning(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ]),
    );
  }
}

/// Индикатор одной проверки и, если она не прошла, — почему.
class _CheckRow extends StatelessWidget {
  final String label;
  final CheckState state;
  final UserError? error;

  const _CheckRow({required this.label, required this.state, this.error});

  @override
  Widget build(BuildContext context) {
    final Widget icon = switch (state) {
      CheckState.ok => const Icon(Icons.check_circle,
          color: Colors.green, semanticLabel: 'прошла'),
      CheckState.failed => const Icon(Icons.cancel,
          color: Colors.red, semanticLabel: 'не прошла'),
      CheckState.checking => const SizedBox(
          width: 24,
          height: 24,
          child: Padding(
            padding: EdgeInsets.all(3),
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      // Прочерк, а не пустой кружок: кружок — это переключатель.
      CheckState.unknown => const Icon(Icons.remove,
          color: Colors.grey, semanticLabel: 'ещё не проверялась'),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 24, height: 24, child: Center(child: icon)),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(label),
          ),
          if (error != null) _ErrorText(error!),
        ]),
      ),
    ]);
  }
}

class _ErrorText extends StatelessWidget {
  final UserError error;
  const _ErrorText(this.error);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(error.title,
            style: TextStyle(
                color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
        Text(error.hint, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}
