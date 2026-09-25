import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/user_error.dart';
import '../error_panel.dart';
import 'cue_status.dart';
import 'review_plate.dart';

/// Низ экрана предпросмотра: «Сохранить видео с субтитрами» → полоса
/// «Сохраняем… 47 %» → зелёный баннер «Готово» (или ошибка).
class SaveBar extends StatelessWidget {
  const SaveBar({
    super.key,
    required this.status,
    required this.progress,
    required this.result,
    required this.error,
    required this.errorLog,
    required this.isMobile,
    required this.canSave,
    required this.showingResult,
    required this.onSave,
    required this.onReveal,
    required this.onViewResult,
    required this.onOtherVideo,
    required this.onErrorAction,
    this.onSaveLog,
  });

  final SaveStatus status;

  /// 0..1 — доля длительности ролика.
  final double progress;
  final SaveResult? result;
  final UserError? error;

  /// Последние строки журнала для «Технических деталей» ошибки.
  final String errorLog;

  /// Android: «Поделиться» вместо «Открыть папку».
  final bool isMobile;

  /// Кнопку сохранения можно нажать (ничего не идёт).
  final bool canSave;

  /// Плеер уже показывает готовый файл.
  final bool showingResult;

  final VoidCallback onSave;
  final VoidCallback onReveal;
  final VoidCallback onViewResult;
  final VoidCallback onOtherVideo;
  final ValueChanged<UserErrorAction> onErrorAction;

  /// «Сохранить журнал» в технических деталях ошибки; null — кнопки нет.
  final VoidCallback? onSaveLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (status) {
      case SaveStatus.burning:
      case SaveStatus.verifying:
        final burning = status == SaveStatus.burning;
        return Column(
          key: const ValueKey('review-saving'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              burning
                  ? savingLabel(progress)
                  : 'Проверяем, что субтитры видны в кадре…',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: burning ? progress : null),
            const SizedBox(height: 4),
            Text(
              'Правка текста на это время отключена',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      case SaveStatus.saved when result != null:
        final saved = result!;
        return ReviewPlate(
          key: const ValueKey('review-saved'),
          color: kPlateGreen,
          icon: Icons.check_circle,
          iconColor: Colors.green.shade700,
          title: 'Готово: ${saved.fileName}',
          message: saved.dir,
          actions: [
            FilledButton.icon(
              onPressed: onReveal,
              icon: Icon(isMobile ? Icons.share : Icons.folder_open),
              label: Text(isMobile ? 'Поделиться' : 'Открыть папку'),
            ),
            OutlinedButton.icon(
              onPressed: showingResult ? null : onViewResult,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Посмотреть результат'),
            ),
            TextButton(
              onPressed: onOtherVideo,
              child: const Text('Другое видео'),
            ),
          ],
        );
      case SaveStatus.idle:
      case SaveStatus.failed:
      case SaveStatus.saved:
        final failure = status == SaveStatus.failed ? error : null;
        // «Повторить» в панели ошибки и так сохраняет заново — вторая
        // кнопка с тем же действием только путала бы.
        final retryInPanel = failure?.action == UserErrorAction.retry;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failure != null) ...[
              ReviewErrorPanel(
                error: failure,
                log: errorLog,
                onAction: failure.action == UserErrorAction.none
                    ? null
                    : () => onErrorAction(failure.action),
                actionEnabled:
                    canSave || failure.action != UserErrorAction.retry,
                onSaveLog: onSaveLog,
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!retryInPanel)
                  FilledButton.icon(
                    key: const ValueKey('review-save'),
                    onPressed: canSave ? onSave : null,
                    icon: const Icon(Icons.movie_creation_outlined),
                    label: const Text('Сохранить видео с субтитрами'),
                  ),
                TextButton(
                  onPressed: onOtherVideo,
                  child: const Text('Другое видео'),
                ),
              ],
            ),
          ],
        );
    }
  }
}

/// Ошибка сохранения человеческим языком: заголовок, что делать, кнопка по
/// смыслу и свёрнутые «Технические детали» с сырым текстом.
///
/// Компактная, в полосе сохранения: общая [ErrorPanel] рассчитана на весь
/// экран. «Технические детали» — общие ([TechnicalDetails]), чтобы на всех
/// экранах они выглядели и работали одинаково, со «Сохранить журнал».
class ReviewErrorPanel extends StatelessWidget {
  const ReviewErrorPanel({
    super.key,
    required this.error,
    this.log = '',
    this.onAction,
    this.actionEnabled = true,
    this.onSaveLog,
  });

  final UserError error;

  /// Последние строки журнала — ключ в них уже замаскирован.
  final String log;
  final VoidCallback? onAction;
  final bool actionEnabled;
  final VoidCallback? onSaveLog;

  String get _technical => [
    if (error.details.isNotEmpty) error.details,
    if (log.isNotEmpty) 'Журнал:\n$log',
  ].join('\n\n');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final technical = _technical;
    // Свой Material, а не цветной Container: «Технические детали» — это
    // ListTile, он рисует отклик на нажатие на ближайшем Material, и
    // цветной фон между ними его бы закрыл (Flutter на это ругается).
    return Material(
      key: const ValueKey('review-error'),
      color: scheme.errorContainer.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error.title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 4),
              child: Text(error.hint),
            ),
            if (onAction != null && error.action != UserErrorAction.none)
              Padding(
                padding: const EdgeInsets.only(left: 34, top: 8),
                child: FilledButton(
                  onPressed: actionEnabled ? onAction : null,
                  child: Text(error.action.label),
                ),
              ),
            if (technical.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 34, top: 8, bottom: 8),
                // Без окошка со своей прокруткой: полоса сохранения
                // прокручивается сама, а окошко внутри неё забирало свайп
                // по середине полосы — на телефоне кнопки под ним было не
                // достать. Кнопки поэтому над текстом.
                child: TechnicalDetails(
                  text: technical,
                  onSaveLog: onSaveLog,
                  maxHeight: null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
