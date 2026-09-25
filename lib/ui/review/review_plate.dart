import 'package:flutter/material.dart';

/// Фон жёлтых плашек.
final Color kPlateYellow = Colors.amber.withValues(alpha: 0.16);

/// Фон зелёных плашек «Готово».
final Color kPlateGreen = Colors.green.withValues(alpha: 0.12);

/// Плашка над списком или под плеером: значок, текст, кнопки.
class ReviewPlate extends StatelessWidget {
  const ReviewPlate({
    super.key,
    required this.message,
    this.title,
    this.icon = Icons.info_outline,
    this.iconColor,
    this.color,
    this.actions = const [],
    this.onClose,
  });

  final String? title;
  final String message;
  final IconData icon;
  final Color? iconColor;
  final Color? color;
  final List<Widget> actions;

  /// Крестик справа; `null` — плашку не закрыть.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Material, а не цветной Container: кнопки на плашке рисуют отклик на
    // ближайшем Material, и цветной фон поверх него этот отклик скрыл бы.
    return Material(
      color: color ?? scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: iconColor ?? scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(message),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
            if (onClose != null)
              IconButton(
                tooltip: 'Закрыть',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClose,
              ),
          ],
        ),
      ),
    );
  }
}
