import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../strings.dart';
import 'guide.dart';
import 'help_window.dart';

/// Руководство «Как пользоваться» (`assets/help/guide.md`), по шагам —
/// как «Советы» в macOS: на экране один шаг — снимок, заголовок, текст и
/// сноска под чертой. Листается стрелками по бокам, клавишами ← → или
/// жестом; в заголовке — раздел и «3 из 14», меню разделов — справа.
///
/// Один и тот же экран — и отдельное окно (`HelpApp` в lib/main.dart), и
/// экран поверх программы там, где отдельного окна нет (Android): там у
/// него ещё кнопка «Назад».
class HelpScreen extends StatefulWidget {
  final Future<bool> Function(String url) openLink;

  const HelpScreen({super.key, this.openLink = openLinkInBrowser});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  Future<List<GuidePage>>? _guide;
  final _pager = PageController();
  int _page = 0;

  /// По распознавателю на адрес: ссылок в руководстве немного, а экраны
  /// шагов строятся и перестраиваются, пока их листают.
  final Map<String, TapGestureRecognizer> _links = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Без кеша: файл маленький, а закешированный Future живёт дольше
    // экрана — в виджет-тестах он принадлежит поддельному времени
    // прошлого теста и в следующем не завершается.
    _guide ??= DefaultAssetBundle.of(context)
        .loadString(kGuideAsset, cache: false)
        .then((text) => guidePages(parseGuide(text)));
  }

  @override
  void dispose() {
    _pager.dispose();
    for (final r in _links.values) {
      r.dispose();
    }
    super.dispose();
  }

  void _go(int page, int count) {
    if (page < 0 || page >= count || !_pager.hasClients) return;
    unawaited(_pager.animateToPage(page,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic));
  }

  Future<void> _openLink(String url) async {
    if (await widget.openLink(url)) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(AppStrings.linkCopied(url))));
  }

  TapGestureRecognizer _link(String url) => _links.putIfAbsent(
      url, () => TapGestureRecognizer()..onTap = () => unawaited(_openLink(url)));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<GuidePage>>(
      future: _guide,
      builder: (context, snapshot) {
        final pages = snapshot.data;
        final Widget body;
        if (snapshot.hasError) {
          body = Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${AppStrings.helpLoadFailed}: ${snapshot.error}'),
            ),
          );
        } else if (pages == null || pages.isEmpty) {
          body = const Center(child: CircularProgressIndicator());
        } else {
          body = _steps(context, pages);
        }
        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: _title(context, pages),
            actions: [if (pages != null && pages.isNotEmpty) _chapters(pages)],
          ),
          body: body,
        );
      },
    );
  }

  Widget _title(BuildContext context, List<GuidePage>? pages) {
    final theme = Theme.of(context);
    final page = pages == null || pages.isEmpty
        ? null
        : pages[_page.clamp(0, pages.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(AppStrings.help),
        if (page != null)
          Text(
            '${page.chapter ?? AppStrings.helpCover} · '
            '${AppStrings.helpPageOf(_page + 1, pages!.length)}',
            key: const ValueKey('help-counter'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
      ],
    );
  }

  Widget _chapters(List<GuidePage> pages) {
    final starts = <(String, int)>[];
    for (final (i, page) in pages.indexed) {
      final name = page.chapter ?? AppStrings.helpCover;
      if (starts.isEmpty || starts.last.$1 != name) starts.add((name, i));
    }
    return PopupMenuButton<int>(
      key: const ValueKey('help-chapters'),
      tooltip: AppStrings.helpChapters,
      icon: const Icon(Icons.format_list_bulleted),
      onSelected: (page) => _go(page, pages.length),
      itemBuilder: (context) => [
        for (final (name, page) in starts)
          PopupMenuItem(value: page, child: Text(name)),
      ],
    );
  }

  Widget _steps(BuildContext context, List<GuidePage> pages) {
    final count = pages.length;
    void previous() => _go(_page - 1, count);
    void next() => _go(_page + 1, count);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): previous,
        const SingleActivator(LogicalKeyboardKey.arrowRight): next,
        const SingleActivator(LogicalKeyboardKey.pageUp): previous,
        const SingleActivator(LogicalKeyboardKey.pageDown): next,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 600;
          // Поля по бокам — под стрелки; текст — нижняя треть экрана.
          final side = narrow ? 48.0 : 84.0;
          final textHeight = (box.maxHeight * 0.36).clamp(170.0, 300.0);
          return Stack(
            children: [
              PageView.builder(
                controller: _pager,
                itemCount: count,
                onPageChanged: (page) => setState(() => _page = page),
                itemBuilder: (context, i) => _StepView(
                  page: pages[i],
                  side: side,
                  textHeight: textHeight,
                  link: _link,
                ),
              ),
              for (final forward in [false, true])
                Positioned(
                  left: forward ? null : (narrow ? 4 : 16),
                  right: forward ? (narrow ? 4 : 16) : null,
                  bottom: 0,
                  height: textHeight,
                  child: Center(
                    child: _Arrow(
                      forward: forward,
                      compact: narrow,
                      onPressed: forward
                          ? (_page < count - 1 ? next : null)
                          : (_page > 0 ? previous : null),
                    ),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

/// Стрелка «назад» или «дальше» у края экрана, как в «Советах» macOS.
/// На первом и последнем шаге — бледная и не нажимается.
class _Arrow extends StatelessWidget {
  final bool forward;
  final bool compact;
  final VoidCallback? onPressed;

  const _Arrow({required this.forward, required this.compact, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: forward ? AppStrings.helpNext : AppStrings.helpPrevious,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : 0.3,
        child: Material(
          key: ValueKey(forward ? 'help-next' : 'help-previous'),
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            mouseCursor:
                enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: SizedBox(
              width: compact ? 36 : 48,
              height: compact ? 56 : 72,
              child: Icon(
                forward
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                size: compact ? 30 : 40,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Один шаг: снимок сверху, под ним заголовок, текст и сноски.
class _StepView extends StatelessWidget {
  final GuidePage page;
  final double side;
  final double textHeight;
  final TapGestureRecognizer Function(String url) link;

  const _StepView({
    required this.page,
    required this.side,
    required this.textHeight,
    required this.link,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 24, side, 16),
            child: Center(
              child: page.image == null
                  ? Icon(Icons.subtitles_outlined,
                      size: 96, color: theme.colorScheme.primary)
                  : _Screenshot(image: page.image!),
            ),
          ),
        ),
        SizedBox(
          height: textHeight,
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 0, side, 12),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(page.title,
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        for (final block in page.body)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _rich(context, _spansOf(block),
                                theme.textTheme.bodyLarge),
                          ),
                        if (page.notes.isNotEmpty) ...[
                          const Divider(height: 20),
                          for (final note in page.notes)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _rich(
                                  context,
                                  note.spans,
                                  theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.outline)),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static List<GuideSpan> _spansOf(GuideBlock block) => switch (block) {
        GuideParagraph(:final spans) => spans,
        GuideItem(:final number, :final spans) => [
            GuideSpan(number == null ? '•  ' : '$number.  ', bold: true),
            ...spans,
          ],
        GuideHeading(:final text) => [GuideSpan(text, bold: true)],
        GuideNote(:final spans) => spans,
        GuideImage(:final caption) => [GuideSpan(caption)],
      };

  Widget _rich(BuildContext context, List<GuideSpan> spans, TextStyle? base) {
    final theme = Theme.of(context);
    return Text.rich(TextSpan(
      style: base,
      children: [
        for (final s in spans)
          if (s.link case final url?)
            TextSpan(
              text: s.text,
              style: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: theme.colorScheme.primary,
              ),
              mouseCursor: SystemMouseCursors.click,
              recognizer: link(url),
            )
          else if (s.code)
            TextSpan(
              text: s.text,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontFamilyFallback: const ['Menlo', 'Roboto Mono', 'monospace'],
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            )
          else
            TextSpan(
              text: s.text,
              style:
                  s.bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
            ),
      ],
    ));
  }
}

/// Снимок экрана в рамке с тенью. По щелчку открывается крупно, с
/// приближением колесом мыши или жестом. Подпись к снимку не рисуется —
/// её читает экранный диктор.
class _Screenshot extends StatelessWidget {
  final GuideImage image;
  const _Screenshot({required this.image});

  void _zoom(BuildContext context) {
    unawaited(showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InteractiveViewer(
              maxScale: 4,
              child: Center(child: Image.asset(image.asset)),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton.filledTonal(
                tooltip: AppStrings.close,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      image: true,
      button: true,
      label: image.caption,
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => _zoom(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                image.asset,
                excludeFromSemantics: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(image.caption),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
