import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/logging.dart';
import 'strings.dart';

/// Журнал работы: записи этого запуска и кнопки, чтобы отдать их
/// разработчику. Ключ в записях уже замаскирован самим [DebugLog].
///
/// Живёт в боковой панели оболочки и в отладочном стенде. Панель
/// создаётся при каждом показе, поэтому подписка на поток журнала
/// обязана сниматься в [State.dispose] — иначе каждое открытие журнала
/// добавляло бы ещё одну вечную подписку.
class LogPanel extends StatefulWidget {
  final DebugLog log;

  /// «Сохранить в файл».
  final VoidCallback? onSave;

  /// «Открыть папку с журналом»; `null` — кнопки нет.
  final VoidCallback? onOpenFolder;

  /// Подпись к [onOpenFolder]: на телефоне папку не открыть, там
  /// «Поделиться журналом».
  final String openFolderLabel;

  /// «Очистить» — только для отладочного стенда: человеку стирать
  /// журнал незачем, а разработчику прислали бы пустой.
  final VoidCallback? onClear;

  /// Кнопка закрытия в заголовке (боковая панель).
  final VoidCallback? onClose;

  /// Показывать ли подробные записи сразу. Человеку они мешают читать
  /// главное, поэтому по умолчанию скрыты; стенд включает их сам.
  final bool showDebugInitially;

  const LogPanel({
    super.key,
    required this.log,
    this.onSave,
    this.onOpenFolder,
    this.openFolderLabel = AppStrings.logOpenFolder,
    this.onClear,
    this.onClose,
    this.showDebugInitially = false,
  });

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  late bool _showDebug = widget.showDebugInitially;
  StreamSubscription<LogEntry>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _scrollToEnd();
  }

  @override
  void didUpdateWidget(covariant LogPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.log, widget.log)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.log.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
      _scrollToEnd();
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _scroll.dispose();
    super.dispose();
  }

  Color _color(LogLevel level) => switch (level) {
        LogLevel.debug => Colors.grey,
        LogLevel.info => Colors.black87,
        LogLevel.warn => Colors.orange.shade800,
        LogLevel.error => Colors.red.shade700,
      };

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.log.asText()));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(AppStrings.copied)));
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.log.entries
        .where((e) => _showDebug || e.level != LogLevel.debug)
        .toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(children: [
          Expanded(
            child: Text(AppStrings.logTitle,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Tooltip(
            message: AppStrings.logShowDebugHint,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text(AppStrings.logShowDebug,
                  style: TextStyle(fontSize: 12)),
              Switch(
                value: _showDebug,
                onChanged: (v) => setState(() => _showDebug = v),
              ),
            ]),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: AppStrings.close,
              icon: const Icon(Icons.close),
              onPressed: widget.onClose,
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(spacing: 4, children: [
          TextButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy, size: 18),
            label: const Text(AppStrings.copy),
          ),
          if (widget.onSave != null)
            TextButton.icon(
              onPressed: widget.onSave,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text(AppStrings.logSaveToFile),
            ),
          if (widget.onOpenFolder != null)
            TextButton.icon(
              onPressed: widget.onOpenFolder,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(widget.openFolderLabel),
            ),
          if (widget.onClear != null)
            TextButton.icon(
              onPressed: () => setState(widget.onClear!),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text(AppStrings.logClear),
            ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: Container(
          color: const Color(0xFFF7F7F7),
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SelectableText(
                  '${e.stamp}  ${e.message}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: _color(e.level),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
