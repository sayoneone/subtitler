import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../app/user_error.dart';
import '../../core/languages.dart';
import '../../core/logging.dart';
import '../../core/models.dart';
import '../log_actions.dart';
import '../player/preview_player.dart';
import '../player/video_preview.dart';
import 'cue_list.dart';
import 'cue_status.dart';
import 'review_header.dart';
import 'review_plate.dart';
import 'save_bar.dart';

/// Шире этого — плеер слева, список справа; уже — плеер сверху.
const double kReviewWideLayout = 900;

/// Ниже этого экран не сжимается, а прокручивается целиком. Окно,
/// приставленное к углу экрана, при масштабе 125–150 % бывает ниже 350
/// точек: сжатые в него видео и список превратились бы в полоски.
const double kReviewMinHeight = 480;

/// Предпросмотр: видео с субтитрами поверх кадра, список реплик с правкой,
/// смена языка и сохранение видео с вшитыми субтитрами.
///
/// Экран владеет плеером: создаёт его фабрикой [playerFactory], открывает
/// исходное видео (без автозапуска) и закрывает при уходе с экрана или
/// смене видео. Всё остальное состояние — в [controller].
class ReviewView extends StatefulWidget {
  const ReviewView({
    super.key,
    required this.controller,
    this.playerFactory = createPreviewPlayer,
  });

  final AppController controller;
  final PreviewPlayer Function({DebugLog? log}) playerFactory;

  @override
  State<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<ReviewView> {
  late PreviewPlayer _player;

  /// Исходное видео, открытое в плеере.
  String? _video;

  /// Плеер показывает готовый `<имя>_ru.mp4` — субтитры уже в кадре.
  bool _showingResult = false;

  /// Реплика, которая звучит сейчас ([Cue.index]).
  final _current = ValueNotifier<int?>(null);

  final _list = GlobalKey<CueListState>();

  /// Языки, варианты которых человек правил на этом экране: при смене
  /// языка правки остаются в резервной копии, меню об этом предупреждает.
  final Set<String> _editedLanguages = {};

  /// Название языка, на который человек попросил переключиться, — для
  /// полосы «Переключаем язык…».
  String? _switchingTo;

  /// «Продолжить распознавание» нажато, видео проверяется.
  bool _continuing = false;

  /// Сохранение попросили, пока ставим плеер на паузу.
  bool _saveRequested = false;

  bool _paused = false;

  AppController get c => widget.controller;

  List<Cue> get _cues => c.session?.cues ?? const [];

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    _openPlayer();
  }

  @override
  void didUpdateWidget(ReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _onController();
    }
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _closePlayer();
    _current.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- плеер

  void _openPlayer() {
    _player = widget.playerFactory(log: c.log);
    _player.position.addListener(_onPosition);
    _video = c.videoPath ?? c.session?.videoPath;
    _showingResult = false;
    _paused = false;
    final video = _video;
    if (video != null) unawaited(_player.open(video));
    _onPosition();
  }

  void _closePlayer() {
    _player.position.removeListener(_onPosition);
    // Не ждём: декодер освобождается в фоне, а экран уже ушёл.
    unawaited(_player.dispose());
  }

  void _onPosition() {
    _current.value = currentCueAt(_cues, _player.position.value);
  }

  void _onController() {
    if (!mounted) return;
    final video = c.videoPath;
    if (video != null && video != _video) {
      // Другое видео — другой плеер: у прежнего могли остаться позиция,
      // пропорции и ошибка чужого файла.
      _closePlayer();
      _openPlayer();
    } else if (_showingResult && c.saveStatus != SaveStatus.saved) {
      // Готового файла больше нет (контроллер сбросил сохранение) — назад
      // к исходнику, иначе в плеере осталось бы устаревшее видео. Но только
      // если остаёмся на экране: при уходе («Другое видео») контроллер
      // тоже сбрасывает сохранение, а плеер вот-вот закроется — открывать
      // в нём исходник значило бы зря запускать декодер.
      _showingResult = false;
      if (_video != null && c.stage == AppStage.review) {
        unawaited(_player.open(_video!));
      }
    }
    // Уходим с экрана (обработка, главный экран): звук не должен играть
    // под другим экраном, пока оболочка нас убирает.
    if (c.stage != AppStage.review && !_paused) {
      _paused = true;
      unawaited(_player.pause());
    } else if (c.stage == AppStage.review) {
      _paused = false;
    }
    _onPosition(); // реплики могли поменяться
    setState(() {});
  }

  void _seekTo(Cue cue) {
    unawaited(
      _player.seek(Duration(milliseconds: (cue.range.start * 1000).round())),
    );
  }

  /// Щелчок в поле перевода: перематываем, только если плеер не на этой
  /// реплике — иначе каждый щелчок для переноса курсора дёргал бы видео.
  void _focusCue(Cue cue) {
    if (_current.value != cue.index) _seekTo(cue);
  }

  void _nextToCheck() {
    final cues = [..._cues]
      ..sort((a, b) => a.range.start.compareTo(b.range.start));
    final flagged = cues
        .where((cue) => cueTone(cue) == CueTone.review)
        .toList();
    if (flagged.isEmpty) return;
    final now = _player.position.value.inMilliseconds / 1000;
    final next = flagged.firstWhere(
      (cue) => cue.range.start > now + 0.001,
      orElse: () => flagged.first,
    );
    _seekTo(next);
    _list.currentState?.reveal(next.index);
  }

  // --------------------------------------------------------------- правки

  void _edit(int cueIndex, String text) {
    final lang = c.language;
    if (lang != null) _editedLanguages.add(lang);
    c.updateTranslation(cueIndex, text);
  }

  Future<void> _switchLanguage(String code) async {
    if (c.isBusy) return;
    setState(() => _switchingTo = languageName(code));
    await _player.pause();
    try {
      await c.switchLanguage(code);
    } finally {
      if (mounted) setState(() => _switchingTo = null);
    }
  }

  void _continueRecognition() {
    final video = c.videoPath;
    if (video == null || !c.canOpenVideo) return;
    unawaited(_player.pause());
    setState(() => _continuing = true);
    // Завершится только с концом обработки — ждать её здесь незачем.
    c.openVideo(video).whenComplete(() {
      if (mounted) setState(() => _continuing = false);
    });
  }

  // ----------------------------------------------------------- сохранение

  Future<void> _save() async {
    if (_saveRequested || c.isBusy) return;
    setState(() => _saveRequested = true);
    try {
      // Кодирование читает тот же файл, а звук поверх полосы прогресса
      // только отвлекает.
      await _player.pause();
      if (!mounted) return;
      final saving = c.save();
      setState(() => _saveRequested = false);
      await saving;
    } finally {
      if (mounted && _saveRequested) setState(() => _saveRequested = false);
    }
  }

  Future<void> _showResult() async {
    final result = c.saveResult;
    if (result == null) return;
    await _player.pause();
    if (!mounted) return;
    setState(() => _showingResult = true);
    await _player.open(result.videoPath);
  }

  Future<void> _backToEditing() async {
    final video = _video;
    setState(() => _showingResult = false);
    if (video != null) await _player.open(video);
  }

  void _onErrorAction(UserErrorAction action) {
    switch (action) {
      case UserErrorAction.retry:
        unawaited(_save());
      case UserErrorAction.changeKey:
        c.changeKey();
      case UserErrorAction.home:
        unawaited(c.goHome());
      case UserErrorAction.none:
        break;
    }
  }

  // ---------------------------------------------------------------- вид

  @override
  Widget build(BuildContext context) {
    final session = c.session;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: session == null
          ? const SizedBox.expand()
          : LayoutBuilder(
              builder: (context, box) {
                final available = box.hasBoundedHeight ? box.maxHeight : 0.0;
                final height = math.max(available, kReviewMinHeight);
                final screen = _layout(session, Size(box.maxWidth, height));
                if (available >= kReviewMinHeight) return screen;
                return SingleChildScrollView(
                  key: const ValueKey('review-scroll'),
                  child: SizedBox(height: height, child: screen),
                );
              },
            ),
    );
  }

  /// Экран высотой [size].height: сверху шапка с плашками, внизу полоса
  /// сохранения, между ними видео и список.
  ///
  /// Шапка и полоса берут столько, сколько им нужно, но не больше своего
  /// потолка — дальше они прокручиваются. Видео и списку всегда остаётся
  /// не меньше `middleMin`: раньше ошибка сохранения с раскрытыми
  /// «Техническими деталями» съедала их целиком, а кнопки уходили за край.
  Widget _layout(Session session, Size size) {
    final wide = size.width >= kReviewWideLayout;
    final top = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: _top(session),
    );
    final bottom = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('review-save-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: _saveBar(),
          ),
        ),
      ],
    );
    final Widget middle;
    final double middleMin;
    if (wide) {
      middle = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: _playerArea(session),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(flex: 4, child: _cueList(session)),
        ],
      );
      middleMin = size.height * 0.45;
    } else {
      // Верхняя граница сначала: в низком окне 42 % высоты бывали меньше
      // 160, и clamp с перевёрнутыми границами ронял весь экран.
      final playerMax = size.height * 0.38;
      final playerHeight = (size.width * 9 / 16 + 56)
          .clamp(math.min(120.0, playerMax), playerMax)
          .toDouble();
      middle = Column(
        children: [
          SizedBox(
            height: playerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _playerArea(session),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _cueList(session)),
        ],
      );
      middleMin = playerHeight + 1 + math.max(72.0, size.height * 0.15);
    }
    return CustomMultiChildLayout(
      delegate: _ReviewLayout(topMax: size.height * 0.3, middleMin: middleMin),
      children: [
        LayoutId(id: _Slot.top, child: top),
        LayoutId(id: _Slot.middle, child: middle),
        LayoutId(id: _Slot.bottom, child: bottom),
      ],
    );
  }

  bool get _locked =>
      c.isBusy ||
      _showingResult ||
      _saveRequested ||
      _switchingTo != null ||
      c.stage != AppStage.review;

  Widget _top(Session session) {
    final title = c.languageTitle ?? languageName(session.lang);
    final choices = c.languageChoices;
    final runnerUp = [
      ...choices,
      ...c.allLanguageChoices,
    ].where((choice) => choice.code == session.langRunnerUp).firstOrNull;
    final canSwitch = !_locked;
    final partial = partialProgress(session);
    // Сообщения контроллера (notice) и вопрос о длинном ролике показывает
    // оболочка над любым экраном — здесь они вышли бы вторым экземпляром.
    final busyNotSaving = c.isBusy && !c.isSaving;
    // Файлы в папке программы: после сохранения показываем само видео,
    // до него — папку с субтитрами.
    final saved = c.saveResult;
    final fallbackPath = (saved?.inFallback ?? false)
        ? saved!.videoPath
        : (c.outputInFallback ? c.outputDir : null);
    final fallbackDir = c.outputDir ?? fallbackPath;
    // Бывает, что в папку программы ушло только видео (например, ffmpeg не
    // пустили писать рядом с исходником), а .srt к тому времени уже
    // записаны рядом с исходником. Тогда про субтитры сказать отдельно:
    // в папке программы их нет.
    final onlyVideoInFallback = saved != null &&
        saved.inFallback &&
        !p.equals(p.dirname(saved.ruSrtPath), saved.dir);

    Widget gap(Widget child) =>
        Padding(padding: const EdgeInsets.only(top: 8), child: child);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Первой: шапка прокручивается, а про режим просмотра и выход из
        // него человек должен видеть сразу.
        if (_showingResult)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _resultStrip(),
          ),
        ReviewHeader(
          total: session.cues.length,
          toCheck: c.reviewCount,
          languageTitle: title,
          choices: choices,
          allChoices: c.allLanguageChoices,
          hasEdits: _editedLanguages.contains(session.lang),
          enabled: canSwitch,
          onSwitch: _switchLanguage,
          onNextToCheck: _nextToCheck,
        ),
        if (busyNotSaving || _switchingTo != null)
          gap(
            Column(
              key: const ValueKey('review-busy'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _switchingTo != null
                      ? 'Переключаем язык на $_switchingTo…'
                      : _continuing
                      ? 'Проверяем видео…'
                      : 'Подождите…',
                ),
                const SizedBox(height: 6),
                const LinearProgressIndicator(),
              ],
            ),
          ),
        if (LanguageDoubtPlate.shows(c.languageConfidence))
          gap(
            LanguageDoubtPlate(
              languageTitle: title,
              confidence: c.languageConfidence!,
              runnerUp: runnerUp,
              enabled: canSwitch,
              onSwitch: _switchLanguage,
            ),
          ),
        if (partial != null)
          gap(
            ReviewPlate(
              key: const ValueKey('review-partial'),
              icon: Icons.pause_circle_outline,
              message:
                  'Обработка была остановлена: распознано '
                  '${partial.recognized} из ${partial.total} реплик',
              actions: [
                FilledButton.tonal(
                  onPressed: c.canOpenVideo && !_locked
                      ? _continueRecognition
                      : null,
                  child: const Text('Продолжить распознавание'),
                ),
                Text(
                  'Уже распознанное повторно не оплачивается',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        if (session.forcedSplit)
          gap(
            const ReviewPlate(
              key: ValueKey('review-forced-split'),
              icon: Icons.content_cut,
              message:
                  'В записи не нашлось пауз, поэтому ролик разрезан на '
                  'равные куски: фраза может оборваться на границе реплик и '
                  'продолжиться в следующей.',
            ),
          ),
        if (fallbackPath != null)
          gap(
            ReviewPlate(
              key: const ValueKey('review-fallback'),
              icon: Icons.folder_outlined,
              message: onlyVideoInFallback
                  ? 'Готовое видео записать рядом с исходным нельзя — оно '
                        'сохранено в папку программы: $fallbackDir. Файлы '
                        '.srt с субтитрами лежат рядом с исходным видео.'
                  : 'Рядом с видео записать нельзя — файлы сохранены в '
                        'папку программы: $fallbackDir',
              actions: [
                // На Android папки не открыть — файлы отдаются «Поделиться».
                if (!c.isMobile)
                  TextButton(
                    onPressed: () => unawaited(c.showInFolder(fallbackPath)),
                    child: const Text('Открыть папку'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _playerArea(Session session) => VideoPreview(
    player: _player,
    // В готовом файле субтитры уже вшиты — второй слой поверх них только
    // мешал бы сравнить.
    cues: _showingResult ? const [] : session.cues,
  );

  /// «Готовое видео: … — Вернуться к правке». В шапке, а не над кадром:
  /// там она отнимала у невысокого плеера половину кадра.
  Widget _resultStrip() {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('review-result-strip'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: kPlateGreen,
        borderRadius: BorderRadius.circular(8),
      ),
      // Wrap, а не Row: на телефоне кнопка уходит под текст, а не
      // сжимает его в столбик по слову.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // Список реплик в этом режиме закрыт для правки — здесь
            // сказано, почему и как её вернуть.
            child: Text(
              'Готовое видео: ${c.saveResult?.fileName ?? ''} — субтитры уже '
              'в кадре. Чтобы исправить текст, нажмите «Вернуться к правке».',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton.icon(
            onPressed: () => unawaited(_backToEditing()),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Вернуться к правке'),
          ),
        ],
      ),
    );
  }

  Widget _cueList(Session session) => CueList(
    key: _list,
    cues: session.cues,
    current: _current,
    follow: _player.playing,
    locked: _locked,
    onSeek: _seekTo,
    onFocusCue: _focusCue,
    onEdit: _edit,
  );

  Widget _saveBar() => SaveBar(
    status: c.saveStatus,
    progress: c.saveProgress,
    result: c.saveResult,
    error: c.saveError,
    errorLog: c.saveStatus == SaveStatus.failed ? c.recentLog() : '',
    onSaveLog: () => unawaited(saveLogAndShow(context, c)),
    isMobile: c.isMobile,
    canSave: !_locked,
    showingResult: _showingResult,
    onSave: () => unawaited(_save()),
    onReveal: () => unawaited(c.revealOutput()),
    onViewResult: () => unawaited(_showResult()),
    onOtherVideo: () => unawaited(c.goHome()),
    onErrorAction: _onErrorAction,
  );
}

enum _Slot { top, middle, bottom }

/// Раскладка экрана по высоте. Column здесь не годится: полосе сохранения
/// без Flexible он даёт сколько угодно места, и видео со списком
/// сжимались до нуля; с Flexible — наоборот, не знает, что ей нужно.
///
/// Поэтому по очереди: шапка — сколько нужно, но не выше [topMax]; полоса
/// сохранения — сколько нужно из того, что осталось сверх [middleMin];
/// видео и список — всё остальное.
class _ReviewLayout extends MultiChildLayoutDelegate {
  _ReviewLayout({required this.topMax, required this.middleMin});

  final double topMax;
  final double middleMin;

  @override
  void performLayout(Size size) {
    BoxConstraints upTo(double height) => BoxConstraints(
      minWidth: size.width,
      maxWidth: size.width,
      maxHeight: math.max(0.0, height),
    );
    final top = layoutChild(_Slot.top, upTo(topMax)).height;
    final bottom = layoutChild(
      _Slot.bottom,
      upTo(size.height - top - middleMin),
    ).height;
    final middle = math.max(0.0, size.height - top - bottom);
    layoutChild(_Slot.middle, BoxConstraints.tight(Size(size.width, middle)));
    positionChild(_Slot.top, Offset.zero);
    positionChild(_Slot.middle, Offset(0, top));
    positionChild(_Slot.bottom, Offset(0, top + middle));
  }

  @override
  bool shouldRelayout(_ReviewLayout oldDelegate) =>
      oldDelegate.topMax != topMax || oldDelegate.middleMin != middleMin;
}
