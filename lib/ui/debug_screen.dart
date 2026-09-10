import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/debug_controller.dart';
import '../core/logging.dart';
import '../core/models.dart';
import '../core/pipeline/pipeline.dart';

const _videoTypes = XTypeGroup(
  label: 'Видео',
  extensions: ['mp4', 'mov', 'mkv', 'avi', 'm4v'],
);

class DebugScreen extends StatefulWidget {
  final DebugController controller;
  const DebugScreen({super.key, required this.controller});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _keyField = TextEditingController();
  final _ffmpegField = TextEditingController();
  bool _dragging = false;

  DebugController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_sync);
    c.init();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_sync);
    _keyField.dispose();
    _ffmpegField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Subtitler — отладочный стенд'),
        actions: [
          if (c.busy)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: _left()),
          const VerticalDivider(width: 1),
          Expanded(flex: 2, child: _LogPanel(log: c.log, onSave: c.saveLog)),
        ],
      ),
    );
  }

  Widget _left() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ffmpegCard(),
        const SizedBox(height: 12),
        _keyCard(),
        const SizedBox(height: 12),
        _videoCard(),
        const SizedBox(height: 12),
        if (c.lastError != null) _errorCard(c.lastError!),
        if (c.session != null) _resultCard(c.session!),
      ],
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _ffmpegCard() {
    final info = c.ffmpeg;
    return _card(title: '1. ffmpeg', children: [
      if (info == null)
        const Text('Не найден. Укажите путь вручную и нажмите «Найти».',
            style: TextStyle(color: Colors.red))
      else ...[
        SelectableText(info.ffmpegPath,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        Text(info.version, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        Row(children: [
          Icon(info.hasLibass ? Icons.check_circle : Icons.error,
              size: 18, color: info.hasLibass ? Colors.green : Colors.orange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(info.hasLibass
                ? 'libass есть — вшивание доступно'
                : 'libass нет — субтитры получатся, но вшить их нельзя. '
                    'Поставьте: brew install ffmpeg-full'),
          ),
        ]),
      ],
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _ffmpegField,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Свой путь к ffmpeg (необязательно)',
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(
          onPressed: () {
            c.ffmpegOverride = _ffmpegField.text;
            c.detectFfmpeg();
          },
          child: const Text('Найти'),
        ),
      ]),
    ]);
  }

  Widget _check(CheckState state, String label) {
    final (icon, color) = switch (state) {
      CheckState.ok => (Icons.check_circle, Colors.green),
      CheckState.failed => (Icons.cancel, Colors.red),
      CheckState.checking => (Icons.hourglass_top, Colors.blue),
      CheckState.unknown => (Icons.help_outline, Colors.grey),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 4),
      Text(label),
    ]);
  }

  Widget _keyCard() {
    return _card(title: '2. Ключ Яндекс Облака', children: [
      TextField(
        controller: _keyField,
        obscureText: true,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: c.apiKey.isEmpty
              ? 'Вставьте ключ сервисного аккаунта'
              : 'Ключ сохранён (${c.apiKey.length} символов) — можно заменить',
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton(
          onPressed: c.busy ? null : () => c.saveKey(_keyField.text),
          child: const Text('Проверить и сохранить'),
        ),
        const SizedBox(width: 16),
        _check(c.translateCheck, 'перевод'),
        const SizedBox(width: 12),
        _check(c.sttCheck, 'распознавание'),
      ]),
      if (c.keyError != null) ...[
        const SizedBox(height: 6),
        Text(c.keyError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
      ],
    ]);
  }

  Widget _videoCard() {
    return _card(title: '3. Видео', children: [
      DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          if (details.files.isNotEmpty) c.setVideo(details.files.first.path);
        },
        child: Container(
          height: 96,
          decoration: BoxDecoration(
            border: Border.all(
                color: _dragging ? Colors.blue : Colors.grey,
                width: _dragging ? 2 : 1),
            borderRadius: BorderRadius.circular(8),
            color: _dragging ? Colors.blue.withValues(alpha: 0.06) : null,
          ),
          child: Center(
            child: c.videoPath == null
                ? const Text('Перетащите сюда видео или выберите файл')
                : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SelectableText(c.videoPath!,
                        style: const TextStyle(fontSize: 12)),
                    if (c.videoSummary != null)
                      Text(c.videoSummary!,
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        OutlinedButton(
          onPressed: c.busy
              ? null
              : () async {
                  final file = await openFile(acceptedTypeGroups: [_videoTypes]);
                  if (file != null) c.setVideo(file.path);
                },
          child: const Text('Выбрать файл'),
        ),
        const SizedBox(width: 16),
        const Text('Язык:'),
        const SizedBox(width: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'tr-TR', label: Text('турецкий')),
            ButtonSegment(value: 'uz-UZ', label: Text('узбекский')),
          ],
          selected: {c.lang},
          onSelectionChanged:
              c.busy ? null : (s) => c.setLang(s.first),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(
          onPressed: c.canRun ? c.run : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Обработать'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: c.busy ? c.cancel : null,
          child: const Text('Отмена'),
        ),
        const SizedBox(width: 16),
        if (c.progress != null) Expanded(child: Text(_progressText(c.progress!))),
      ]),
    ]);
  }

  String _progressText(PipelineProgress p) {
    final name = switch (p.stage) {
      PipelineStage.extractingAudio => 'Извлекаем звук…',
      PipelineStage.detectingSilence => 'Ищем паузы в речи…',
      PipelineStage.recognizing => 'Распознаём',
      PipelineStage.translating => 'Переводим',
      PipelineStage.done => 'Готово',
    };
    return p.total > 0 ? '$name ${p.done}/${p.total}' : name;
  }

  Widget _errorCard(String message) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.red.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(message, style: const TextStyle(color: Colors.red)),
      ),
    );
  }

  Widget _resultCard(Session session) {
    final flagged = session.cues.where((c) => c.flags.isNotEmpty).length;
    return _card(title: '4. Результат', children: [
      Text('Реплик: ${session.cues.length}, на проверку: $flagged, '
          'порог тишины: ${session.silenceThreshold}'
          '${session.forcedSplit ? ' (принудительная нарезка)' : ''}'),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.icon(
          onPressed: c.canBurn ? c.burn : null,
          icon: const Icon(Icons.subtitles),
          label: const Text('Вшить субтитры'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: c.busy ? null : c.revealOutput,
          child: const Text('Показать в Finder'),
        ),
      ]),
      if (c.burnedPath != null) ...[
        const SizedBox(height: 6),
        SelectableText('Готово: ${c.burnedPath}',
            style: const TextStyle(color: Colors.green, fontSize: 12)),
      ],
      const SizedBox(height: 12),
      _CueTable(cues: session.cues),
    ]);
  }
}

class _CueTable extends StatelessWidget {
  final List<Cue> cues;
  const _CueTable({required this.cues});

  String _time(double v) {
    final m = (v ~/ 60).toString().padLeft(2, '0');
    final s = (v % 60).toStringAsFixed(2).padLeft(5, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: ListView.separated(
        itemCount: cues.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final cue = cues[i];
          final flagged = cue.flags.isNotEmpty;
          return Container(
            color: flagged ? Colors.amber.withValues(alpha: 0.18) : null,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 96,
                child: Text(
                  '${cue.index}. ${_time(cue.range.start)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(
                    cue.orig.isEmpty ? '— речи нет —' : cue.orig,
                    style: TextStyle(
                      fontSize: 12,
                      color: cue.orig.isEmpty ? Colors.grey : null,
                    ),
                  ),
                  if (cue.ru.isNotEmpty)
                    SelectableText(cue.ru,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500)),
                ]),
              ),
              SizedBox(
                width: 70,
                child: Text(cue.status.name,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _LogPanel extends StatefulWidget {
  final DebugLog log;
  final VoidCallback onSave;
  const _LogPanel({required this.log, required this.onSave});

  @override
  State<_LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<_LogPanel> {
  final _scroll = ScrollController();
  bool _showDebug = true;

  @override
  void initState() {
    super.initState();
    widget.log.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Color _color(LogLevel level) => switch (level) {
        LogLevel.debug => Colors.grey,
        LogLevel.info => Colors.black87,
        LogLevel.warn => Colors.orange.shade800,
        LogLevel.error => Colors.red.shade700,
      };

  @override
  Widget build(BuildContext context) {
    final entries = widget.log.entries
        .where((e) => _showDebug || e.level != LogLevel.debug)
        .toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          const Text('Журнал'),
          const Spacer(),
          Tooltip(
            message: 'Показывать подробные записи',
            child: Row(children: [
              const Text('debug', style: TextStyle(fontSize: 12)),
              Switch(
                value: _showDebug,
                onChanged: (v) => setState(() => _showDebug = v),
              ),
            ]),
          ),
          IconButton(
            tooltip: 'Скопировать',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: widget.log.asText())),
          ),
          IconButton(
            tooltip: 'Сохранить в файл',
            icon: const Icon(Icons.save_alt, size: 18),
            onPressed: widget.onSave,
          ),
          IconButton(
            tooltip: 'Очистить',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => setState(widget.log.clear),
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
