import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'strings.dart';

/// Этап [AppStage.processing]: шаги с галочками, текущий — с подробностью
/// («Распознаём речь: 4 из 13»), язык — как только определён. «Отмена»
/// работает на любом шаге.
class ProcessingView extends StatelessWidget {
  final AppController controller;
  const ProcessingView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final steps = c.processingSteps;
    final progress = c.progress;
    // Шаг, которого нет в списке (не должно случаться), — считаем, что
    // идёт первый, без подробностей.
    final at = progress == null ? -1 : steps.indexOf(progress.step);
    final known = at >= 0;
    final current = known ? at : 0;
    final stopping = c.cancelRequested;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (c.videoName != null)
                Text(c.videoName!, style: theme.textTheme.titleLarge),
              if (c.languageTitle != null) ...[
                const SizedBox(height: 4),
                Text(AppStrings.language(c.languageTitle!),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ],
              const SizedBox(height: 20),
              for (final (i, step) in steps.indexed)
                _StepRow(
                  title: i == current && known ? progress!.label : step.title,
                  state: i < current
                      ? _StepState.done
                      : i == current
                          ? _StepState.active
                          : _StepState.pending,
                  fraction: i == current && known ? progress!.fraction : null,
                  hint: i == current && step == ProcessingStep.preparingAudio
                      ? AppStrings.prepareHint
                      : null,
                ),
              const SizedBox(height: 20),
              if (stopping) ...[
                Text(AppStrings.stopping, style: theme.textTheme.titleSmall),
                Text(AppStrings.stoppingHint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
              ],
              OutlinedButton.icon(
                onPressed: stopping ? null : c.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text(AppStrings.cancel),
              ),
              const SizedBox(height: 12),
              Text(AppStrings.processingMayMinimize,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}

enum _StepState { done, active, pending }

class _StepRow extends StatelessWidget {
  final String title;
  final _StepState state;
  final double? fraction;
  final String? hint;

  const _StepRow({
    required this.title,
    required this.state,
    this.fraction,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget icon = switch (state) {
      _StepState.done => const Icon(Icons.check_circle,
          color: Colors.green, semanticLabel: 'готово'),
      _StepState.active => const Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      _StepState.pending => Icon(Icons.radio_button_unchecked,
          color: theme.colorScheme.outlineVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 24, height: 24, child: Center(child: icon)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                title,
                style: state == _StepState.pending
                    ? theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.outline)
                    : theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: state == _StepState.active
                            ? FontWeight.w600
                            : null),
              ),
            ),
            if (hint != null)
              Text(hint!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            if (fraction != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(value: fraction),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Этап [AppStage.cancelled]: обработку остановил человек. Если что-то
/// успели распознать — можно открыть это в предпросмотре.
class CancelledView extends StatelessWidget {
  final AppController controller;
  const CancelledView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final c = controller;
        final partial = c.canOpenPartial;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.pause_circle_outline,
                      size: 48, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  if (c.videoName != null)
                    Text(c.videoName!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  Text(AppStrings.cancelledTitle,
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(partial
                      ? AppStrings.cancelledText
                      : AppStrings.cancelledNothing),
                  const SizedBox(height: 20),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    if (partial)
                      FilledButton(
                        onPressed:
                            c.isBusy ? null : () => unawaited(c.openPartial()),
                        child: const Text(AppStrings.openPartial),
                      ),
                    OutlinedButton(
                      onPressed: c.isBusy ? null : () => unawaited(c.goHome()),
                      child: const Text(AppStrings.goHome),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
