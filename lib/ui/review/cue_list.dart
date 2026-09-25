import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/models.dart';
import 'cue_status.dart';

/// Список реплик предпросмотра: время, оригинал серым, перевод в поле
/// правки, жёлтые строки с причиной, серые «речи нет».
///
/// Щелчок по строке перематывает плеер на начало реплики ([onSeek]).
/// Текущая реплика ([current]) подсвечена, и пока идёт воспроизведение
/// ([follow]), список сам к ней прокручивается — но не тогда, когда
/// человек печатает: поле правки не должно уезжать из-под курсора.
class CueList extends StatefulWidget {
  const CueList({
    super.key,
    required this.cues,
    required this.current,
    required this.follow,
    required this.locked,
    required this.onSeek,
    required this.onFocusCue,
    required this.onEdit,
  });

  final List<Cue> cues;

  /// [Cue.index] реплики, которая звучит сейчас.
  final ValueListenable<int?> current;

  /// Идёт воспроизведение — список следует за текущей репликой.
  final ValueListenable<bool> follow;

  /// Правка запрещена: идёт сохранение, смена языка или показ готового
  /// видео.
  final bool locked;

  /// Щелчок по строке.
  final ValueChanged<Cue> onSeek;

  /// Щелчок в поле перевода: курсор ставится, а перемотка нужна, только
  /// если плеер сейчас не на этой реплике.
  final ValueChanged<Cue> onFocusCue;

  final void Function(int cueIndex, String text) onEdit;

  @override
  State<CueList> createState() => CueListState();
}

class CueListState extends State<CueList> {
  final _scroll = ScrollController();

  /// Ключи строк по [Cue.index]: по ним находится строка, до которой надо
  /// прокрутить.
  final Map<int, GlobalKey> _keys = {};

  /// Фокус внутри списка — человек печатает.
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    widget.current.addListener(_onCurrent);
  }

  @override
  void didUpdateWidget(CueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current != widget.current) {
      oldWidget.current.removeListener(_onCurrent);
      widget.current.addListener(_onCurrent);
    }
    final alive = {for (final c in widget.cues) c.index};
    _keys.removeWhere((index, _) => !alive.contains(index));
  }

  @override
  void dispose() {
    widget.current.removeListener(_onCurrent);
    _scroll.dispose();
    super.dispose();
  }

  void _onCurrent() {
    final index = widget.current.value;
    if (index == null || !widget.follow.value || _editing) return;
    // Строка подсветится в этом же кадре; прокручивать — после него, когда
    // её положение уже известно.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(index);
    });
  }

  /// Прокручивает список так, чтобы строка реплики [cueIndex] была видна
  /// целиком. Если она уже видна — ничего не делает: список не дёргается
  /// на каждой реплике.
  void reveal(int cueIndex, {int attempts = 3}) {
    if (!_scroll.hasClients) return;
    final context = _keys[cueIndex]?.currentContext;
    if (context != null) {
      _ensureVisible(context);
      return;
    }
    // Строки далеко за краем ListView.builder не строит, и положение их
    // неизвестно. Прыгаем туда, где строка примерно должна быть, и после
    // следующего кадра доводим точно.
    final position = _scroll.position;
    final i = widget.cues.indexWhere((c) => c.index == cueIndex);
    if (i < 0 || attempts <= 0) return;
    final content = position.maxScrollExtent + position.viewportDimension;
    final estimate =
        content * i / math.max(1, widget.cues.length) -
        position.viewportDimension / 4;
    _scroll.jumpTo(
      estimate.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(cueIndex, attempts: attempts - 1);
    });
  }

  void _ensureVisible(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final position = _scroll.position;
    // Смещения прокрутки, при которых строка стоит у верхнего и у нижнего
    // края окна; между ними строка видна целиком.
    final atTop = viewport.getOffsetToReveal(box, 0).offset;
    final atBottom = viewport.getOffsetToReveal(box, 1).offset;
    if (position.pixels <= atTop + 0.5 && position.pixels >= atBottom - 0.5) {
      return;
    }
    // Чуть ниже верха: видно и эту реплику, и несколько следующих.
    final target = viewport
        .getOffsetToReveal(box, 0.2)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => _editing = focused,
      child: ValueListenableBuilder<int?>(
        valueListenable: widget.current,
        builder: (context, current, _) => ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: widget.cues.length,
          itemBuilder: (context, i) {
            final cue = widget.cues[i];
            return CueRow(
              key: _keys.putIfAbsent(cue.index, GlobalKey.new),
              cue: cue,
              current: cue.index == current,
              locked: widget.locked,
              onSeek: widget.onSeek,
              onFocusCue: widget.onFocusCue,
              onEdit: widget.onEdit,
            );
          },
        ),
      ),
    );
  }
}

/// Строка реплики.
///
/// Поле перевода живёт своей жизнью и берёт текст из модели только когда в
/// нём нет курсора: иначе перерисовка после каждого нажатия (правка тут же
/// уходит в контроллер и возвращается новым списком) сбрасывала бы позицию
/// курсора. Так же сделано в `_CueRow` отладочного стенда.
class CueRow extends StatefulWidget {
  const CueRow({
    super.key,
    required this.cue,
    required this.current,
    required this.locked,
    required this.onSeek,
    required this.onFocusCue,
    required this.onEdit,
  });

  final Cue cue;
  final bool current;
  final bool locked;
  final ValueChanged<Cue> onSeek;
  final ValueChanged<Cue> onFocusCue;
  final void Function(int cueIndex, String text) onEdit;

  CueTone get tone => cueTone(cue);

  @override
  State<CueRow> createState() => _CueRowState();
}

class _CueRowState extends State<CueRow> {
  late final TextEditingController _ru = TextEditingController(
    text: widget.cue.ru,
  );
  final _focus = FocusNode();

  @override
  void didUpdateWidget(CueRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.cue.ru != _ru.text) {
      _ru.text = widget.cue.ru;
    }
  }

  @override
  void dispose() {
    _ru.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cue = widget.cue;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = widget.tone;
    final reasons = cueReviewReasons(cue);
    final caption = cueToneCaption(tone);
    final muted = tone == CueTone.empty || tone == CueTone.pending;
    final small = theme.textTheme.bodySmall;

    return Material(
      key: ValueKey('cue-row-${cue.index}'),
      color:
          cueToneColor(tone, scheme) ??
          (widget.current ? scheme.primary.withValues(alpha: 0.06) : null) ??
          Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSeek(cue),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: widget.current ? scheme.primary : Colors.transparent,
                width: 4,
              ),
              bottom: BorderSide(color: theme.dividerColor, width: 0.5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    formatCueTime(cue.range.start),
                    style: small?.copyWith(
                      color: widget.current
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: widget.current ? FontWeight.w600 : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (cue.orig.trim().isNotEmpty)
                      Text(
                        cue.orig,
                        style: small?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    TextField(
                      key: ValueKey('cue-ru-${cue.index}'),
                      controller: _ru,
                      focusNode: _focus,
                      enabled: !widget.locked,
                      maxLines: null,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: muted ? scheme.onSurfaceVariant : null,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                        hintText: switch (tone) {
                          CueTone.empty => 'впишите, если речь есть',
                          _ => 'впишите перевод',
                        },
                      ),
                      onTap: () => widget.onFocusCue(cue),
                      onChanged: (text) => widget.onEdit(cue.index, text),
                    ),
                    for (final reason in reasons)
                      Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 16,
                            color: Colors.amber.shade900,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              reason,
                              style: small?.copyWith(
                                color: Colors.brown.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (caption != null)
                      Text(
                        caption,
                        style: small?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
