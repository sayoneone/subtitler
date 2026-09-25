import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/player/video_preview.dart';
import 'package:subtitler/ui/review/cue_list.dart';
import 'package:subtitler/ui/review/cue_status.dart';

import '../../support/app_harness.dart';
import '../../support/fake_preview_player.dart';
import '../support.dart';
import 'review_test_support.dart';

const _video = '/видео/дело 1/clip.mp4';
const _burned = '/видео/дело 1/clip_ru.mp4';

SaveResult _saved({String video = _burned, bool inFallback = false}) =>
    SaveResult(
      videoPath: video,
      origSrtPath: video.replaceFirst('_ru.mp4', '_orig.srt'),
      ruSrtPath: video.replaceFirst('.mp4', '.srt'),
      inFallback: inFallback,
    );

/// Сессия, в которой ни у одной реплики нет перевода: сохранять нечего, и
/// контроллер отказывает сразу — без ffmpeg и без диска.
Session _untranslated() {
  final s = sampleSession();
  return s.copyWith(cues: [for (final c in s.cues) c.copyWith(ru: '')]);
}

/// Остановленная обработка: реплики 4 и 5 ещё не распознаны.
Session _partial() {
  final s = sampleSession();
  return s.copyWith(
    cues: [
      for (final c in s.cues)
        c.index >= 4
            ? c.copyWith(
                orig: '',
                ru: '',
                status: CueStatus.pending,
                flags: const {},
              )
            : c,
    ],
  );
}

/// Длинный ролик: 60 выдуманных реплик по 2 секунды.
Session _long() => sampleSession().copyWith(
  cues: [
    for (var i = 1; i <= 60; i++)
      Cue(
        index: i,
        range: TimeRange((i - 1) * 2.0, (i - 1) * 2.0 + 1.8),
        orig: 'satır $i',
        ru: 'реплика номер $i',
        status: CueStatus.ok,
        flags: const {},
      ),
  ],
);

bool _visibleIn(WidgetTester tester, Finder item, Finder area) {
  if (item.evaluate().isEmpty) return false;
  final r = tester.getRect(item);
  final a = tester.getRect(area);
  return r.top >= a.top - 0.5 && r.bottom <= a.bottom + 0.5;
}

void main() {
  group('Плеер', () {
    testWidgets('открывается на исходном видео и сам не запускается', (
      tester,
    ) async {
      final rig = await pumpReview(tester);

      expect(rig.players, hasLength(1));
      expect(rig.player.opened, [_video]);
      expect(rig.player.playCalls + rig.player.toggleCalls, 0);
      expect(find.byKey(FakePreviewPlayer.frameKey), findsOneWidget);

      await finishReview(tester, rig);
    });

    testWidgets('закрывается, когда экран убирают', (tester) async {
      final rig = await pumpReview(tester);
      final player = rig.player;
      expect(player.disposed, isFalse);

      await tester.pumpWidget(const SizedBox());
      expect(player.disposed, isTrue);

      await rig.h.dispose();
    });

    testWidgets('уход с этапа предпросмотра ставит видео на паузу', (
      tester,
    ) async {
      final rig = await pumpReview(tester);
      rig.player.playingValue.value = true;

      rig.controller.debugEmulate(stage: AppStage.processing);
      await tester.pump();

      expect(rig.player.pauseCalls, 1);
      expect(rig.player.playingValue.value, isFalse);
      await finishReview(tester, rig);
    });

    testWidgets('другое видео — прежний плеер закрыт, новый на новом файле', (
      tester,
    ) async {
      final rig = await pumpReview(tester);

      rig.controller.debugEmulate(videoPath: '/видео/дело 2/другое.mp4');
      await tester.pump();

      expect(rig.players, hasLength(2));
      expect(rig.players.first.disposed, isTrue);
      expect(rig.players.last.opened, ['/видео/дело 2/другое.mp4']);
      expect(rig.players.last.disposed, isFalse);
      await finishReview(tester, rig);
    });
  });

  group('Список реплик', () {
    testWidgets('щелчок по строке — перемотка на начало реплики', (
      tester,
    ) async {
      final rig = await pumpReview(tester);

      await tester.tap(find.text('tamam tamam tamam tamam'));
      await tester.pump();
      expect(rig.player.seeks, [const Duration(seconds: 4)]);
      expect(
        cueRow(tester, 2).current,
        isTrue,
        reason: 'строка, на которую перемотали, подсвечена',
      );

      await tester.tap(find.text('akşam eve geç geleceğim'));
      await tester.pump();
      expect(rig.player.seeks.last, const Duration(seconds: 10));
      expect(cueRow(tester, 2).current, isFalse);
      expect(cueRow(tester, 4).current, isTrue);

      await finishReview(tester, rig);
    });

    testWidgets('щелчок в поле перевода перематывает, только если плеер не '
        'на этой реплике', (tester) async {
      final rig = await pumpReview(tester);

      await tester.tap(translationField(4));
      await tester.pump();
      expect(rig.player.seeks, [const Duration(seconds: 10)]);

      // Второй щелчок — переставить курсор: видео не дёргается. Пауза
      // длиннее двойного щелчка: иначе TextField второй щелчок не считает
      // отдельным (onTap не зовётся), и тест прошёл бы при любом коде.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(translationField(4));
      await tester.pump();
      expect(rig.player.seeks, hasLength(1));

      // Щелчок в поле другой реплики — перемотка к ней.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(translationField(2));
      await tester.pump();
      expect(rig.player.seeks, [
        const Duration(seconds: 10),
        const Duration(seconds: 4),
      ]);

      await finishReview(tester, rig);
    });

    testWidgets('правка перевода сразу видна в кадре', (tester) async {
      final rig = await pumpReview(tester);
      await moveTo(tester, rig.player, const Duration(milliseconds: 1500));
      expect(shownSubtitle(tester), 'завтра рано утром пойдём на рынок');

      await tester.enterText(translationField(1), 'завтра идём на базар');
      await tester.pump();

      expect(shownSubtitle(tester), 'завтра идём на базар');
      expect(rig.controller.session!.cues.first.ru, 'завтра идём на базар');
      await finishReview(tester, rig);
    });

    testWidgets('перерисовка не сбрасывает курсор в поле перевода', (
      tester,
    ) async {
      final rig = await pumpReview(tester);
      await tester.showKeyboard(translationField(1));
      // Человек дописал слово в середину: курсор после «завтра».
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'завтра очень рано утром пойдём на рынок',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await tester.pump();
      // Любое оповещение контроллера перестраивает экран.
      rig.controller.debugEmulate(saveProgress: 0);
      await tester.pump();

      final editable = tester.widget<EditableText>(
        find.descendant(
          of: translationField(1),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        editable.controller.text,
        'завтра очень рано утром пойдём на рынок',
      );
      expect(
        editable.controller.selection,
        const TextSelection.collapsed(offset: 12),
      );
      await finishReview(tester, rig);
    });

    testWidgets('строки на проверку жёлтые, с причиной; обычная — без', (
      tester,
    ) async {
      final rig = await pumpReview(tester);
      final scheme = Theme.of(tester.element(cueRowFinder(1))).colorScheme;

      expect(find.text('Реплик 5 · проверить 3'), findsOneWidget);
      expect(cueRow(tester, 1).tone, CueTone.normal);
      for (final i in [2, 3, 4]) {
        expect(cueRow(tester, i).tone, CueTone.review, reason: 'реплика $i');
        expect(
          tester.widget<Material>(find.byKey(ValueKey('cue-row-$i'))).color,
          cueToneColor(CueTone.review, scheme),
        );
      }
      expect(
        find.descendant(
          of: cueRowFinder(2),
          matching: find.text('возможен сбой распознавания — повтор слова'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cueRowFinder(3),
          matching: find.text('не распознано — впишите сами'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cueRowFinder(4),
          matching: find.text('перевод не получен'),
        ),
        findsOneWidget,
      );
      // Нераспознанной реплике «перевод не получен» не пишется: её надо
      // вписать, а не перевести.
      expect(find.text('перевод не получен'), findsOneWidget);

      await finishReview(tester, rig);
    });

    testWidgets('статусы по-русски, имён перечислений на экране нет', (
      tester,
    ) async {
      final rig = await pumpReview(tester, session: _partial());
      for (final name in [
        ...CueStatus.values.map((s) => s.name),
        ...CueFlag.values.map((f) => f.name),
      ]) {
        expect(find.text(name), findsNothing, reason: name);
        expect(
          find.textContaining(RegExp('\\b$name\\b')),
          findsNothing,
          reason: name,
        );
      }
      await finishReview(tester, rig);
    });

    testWidgets('«речи нет» — серая строка; вписанный текст делает её '
        'обычной и виден в кадре', (tester) async {
      final rig = await pumpReview(tester);
      final scheme = Theme.of(tester.element(cueRowFinder(5))).colorScheme;

      expect(cueRow(tester, 5).tone, CueTone.empty);
      expect(
        tester.widget<Material>(find.byKey(const ValueKey('cue-row-5'))).color,
        scheme.surfaceContainerHighest,
      );
      expect(
        find.descendant(of: cueRowFinder(5), matching: find.text('речи нет')),
        findsOneWidget,
      );
      await moveTo(tester, rig.player, const Duration(milliseconds: 13500));
      expect(shownSubtitle(tester), isNull);

      await tester.enterText(translationField(5), 'кто-то тихо смеётся');
      await tester.pump();

      expect(cueRow(tester, 5).tone, CueTone.normal);
      expect(find.text('речи нет'), findsNothing);
      expect(shownSubtitle(tester), 'кто-то тихо смеётся');
      expect(rig.controller.session!.cues.last.status, CueStatus.ok);
      await finishReview(tester, rig);
    });

    testWidgets('принудительная нарезка — одна плашка, строки не жёлтые', (
      tester,
    ) async {
      final rig = await pumpReview(
        tester,
        session: sampleSession(forcedSplit: true),
      );

      expect(find.byKey(const ValueKey('review-forced-split')), findsOneWidget);
      expect(cueRow(tester, 1).tone, CueTone.normal);
      expect(cueRow(tester, 5).tone, CueTone.empty);
      final yellow = tester
          .widgetList<CueRow>(find.byType(CueRow))
          .where((row) => row.tone == CueTone.review)
          .length;
      expect(yellow, 3, reason: 'жёлтые — только настоящие причины');
      expect(find.text('Реплик 5 · проверить 3'), findsOneWidget);
      await finishReview(tester, rig);
    });

    testWidgets('обычная сессия — плашки о нарезке нет', (tester) async {
      final rig = await pumpReview(tester);
      expect(find.byKey(const ValueKey('review-forced-split')), findsNothing);
      await finishReview(tester, rig);
    });

    testWidgets('при воспроизведении список прокручивается к текущей реплике', (
      tester,
    ) async {
      final rig = await pumpReview(tester, session: _long());
      final list = find.byType(CueList);
      expect(
        _visibleIn(tester, find.byKey(const ValueKey('cue-row-56')), list),
        isFalse,
      );

      rig.player.playingValue.value = true;
      await moveTo(tester, rig.player, const Duration(seconds: 111));
      await tester.pumpAndSettle();

      expect(cueRow(tester, 56).current, isTrue);
      expect(
        _visibleIn(tester, find.byKey(const ValueKey('cue-row-56')), list),
        isTrue,
      );

      // Следующая реплика рядом — список следует за ней.
      await moveTo(tester, rig.player, const Duration(seconds: 113));
      await tester.pumpAndSettle();
      expect(
        _visibleIn(tester, find.byKey(const ValueKey('cue-row-57')), list),
        isTrue,
      );
      await finishReview(tester, rig);
    });

    testWidgets('на паузе и во время набора текста список не уезжает', (
      tester,
    ) async {
      final rig = await pumpReview(tester, session: _long());
      final list = find.byType(CueList);

      // Пауза: перемотка ползунком далеко вперёд список не трогает.
      await moveTo(tester, rig.player, const Duration(seconds: 111));
      await tester.pumpAndSettle();
      expect(
        _visibleIn(tester, find.byKey(const ValueKey('cue-row-1')), list),
        isTrue,
      );

      // Человек печатает, видео играет — поле остаётся на месте.
      await tester.showKeyboard(translationField(1));
      rig.player.playingValue.value = true;
      await moveTo(tester, rig.player, const Duration(seconds: 81));
      await tester.pumpAndSettle();
      expect(
        _visibleIn(tester, find.byKey(const ValueKey('cue-row-1')), list),
        isTrue,
      );
      await finishReview(tester, rig);
    });

    testWidgets('«Следующая на проверку» перематывает к жёлтой строке', (
      tester,
    ) async {
      final rig = await pumpReview(tester);

      await tester.tap(find.byTooltip('Следующая на проверку'));
      await tester.pump();
      expect(rig.player.seeks.last, const Duration(seconds: 4));

      await tester.tap(find.byTooltip('Следующая на проверку'));
      await tester.pump();
      expect(rig.player.seeks.last, const Duration(seconds: 7));
      await finishReview(tester, rig);
    });
  });

  group('Язык', () {
    testWidgets('в шапке язык и «Не тот язык?»', (tester) async {
      final rig = await pumpReview(tester);
      expect(find.text('Язык: турецкий'), findsOneWidget);
      expect(find.text('Не тот язык?'), findsOneWidget);
      await finishReview(tester, rig);
    });

    testWidgets('низкая уверенность — плашка с кнопкой второго языка', (
      tester,
    ) async {
      final rig = await pumpReview(
        tester,
        session: sampleSession(confidence: LanguageConfidence.low),
      );

      expect(
        find.text(
          'Скорее всего турецкий. Если перевод выглядит '
          'бессмысленным —',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Распознать как узбекский'),
        findsOneWidget,
      );
      expect(find.text('оплачивается'), findsOneWidget);
      await finishReview(tester, rig);
    });

    testWidgets('уверенный выбор и язык, выбранный человеком, — без плашки', (
      tester,
    ) async {
      for (final confidence in [LanguageConfidence.high, null]) {
        final rig = await pumpReview(
          tester,
          session: sampleSession(confidence: confidence),
        );
        expect(
          find.byKey(const ValueKey('review-language-doubt')),
          findsNothing,
          reason: '$confidence',
        );
        await finishReview(tester, rig);
      }
    });

    testWidgets('меню «Не тот язык?»: второй язык первым, затем языки из '
        'настроек, в конце «Другой язык…»', (tester) async {
      final rig = await pumpReview(
        tester,
        settings: const AppSettings(
          detectionCandidates: ['kk-KZ', 'tr-TR', 'uz-UZ', 'ru-RU'],
        ),
        setup: (c) => c.debugEmulate(backupLanguages: {'uz-UZ'}),
      );

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();

      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('узбекский'), lessThan(y('казахский')));
      expect(y('казахский'), lessThan(y('русский')));
      expect(y('русский'), lessThan(y('Другой язык…')));
      expect(find.text('турецкий'), findsNothing, reason: 'текущий язык');

      Finder mark(String language, String text) => find.descendant(
        of: find.widgetWithText(PopupMenuItem<String>, language),
        matching: find.text(text),
      );
      expect(mark('узбекский', 'готово — переключить'), findsOneWidget);
      expect(
        mark('казахский', 'распознать заново — оплачивается'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Ваши правки'),
        findsNothing,
        reason: 'правок ещё не было',
      );

      await tester.tap(find.text('Другой язык…'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialogOption), findsNWidgets(15));
      expect(find.byKey(const ValueKey('other-language-tr-TR')), findsNothing);
      expect(
        find.byKey(const ValueKey('other-language-he-IL')),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(4, 4)); // мимо диалога — передумал
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      await finishReview(tester, rig);
    });

    testWidgets('есть правки — меню предупреждает, что они останутся', (
      tester,
    ) async {
      final rig = await pumpReview(tester);
      await tester.enterText(translationField(1), 'своя правка');
      await tester.pump();

      await tester.tap(find.text('Не тот язык?'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Ваши правки останутся в варианте «турецкий» — к нему '
          'можно вернуться через это же меню',
        ),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await finishReview(tester, rig);
    });
  });

  group('Сохранение', () {
    testWidgets('проценты, правка заблокирована; затем баннер и «Открыть '
        'папку»', (tester) async {
      final rig = await pumpReview(tester);
      expect(find.text('Сохранить видео с субтитрами'), findsOneWidget);

      rig.controller.debugEmulate(
        saveStatus: SaveStatus.burning,
        saveProgress: 0.47,
      );
      await tester.pump();
      expect(find.text('Сохраняем видео с субтитрами… 47 %'), findsOneWidget);
      expect(find.text('Сохранить видео с субтитрами'), findsNothing);
      expect(tester.widget<TextField>(translationField(1)).enabled, isFalse);
      expect(cueRow(tester, 1).locked, isTrue);

      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(),
      );
      await tester.pump();
      expect(find.text('Готово: clip_ru.mp4'), findsOneWidget);
      expect(find.text('Поделиться'), findsNothing);

      await tester.tap(find.text('Открыть папку'));
      await tester.pump();
      expect(rig.h.revealed, [_burned]);
      await finishReview(tester, rig);
    });

    testWidgets('Android: «Поделиться» отдаёт видео и оба .srt', (
      tester,
    ) async {
      final rig = await pumpReview(tester, isMobile: true);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(),
      );
      await tester.pump();

      expect(find.text('Открыть папку'), findsNothing);
      await tester.tap(find.text('Поделиться'));
      await tester.pump();
      expect(rig.h.shared, [
        [_burned, '/видео/дело 1/clip_orig.srt', '/видео/дело 1/clip_ru.srt'],
      ]);
      await finishReview(tester, rig);
    });

    testWidgets('«Посмотреть результат» открывает готовый файл в том же '
        'плеере без второго слоя субтитров', (tester) async {
      final rig = await pumpReview(tester);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(),
      );
      await tester.pump();
      await moveTo(tester, rig.player, const Duration(milliseconds: 1500));
      expect(shownSubtitle(tester), isNotNull);

      await tester.tap(find.text('Посмотреть результат'));
      await tester.pump();

      expect(rig.players, hasLength(1), reason: 'тот же плеер');
      expect(rig.player.opened, [_video, _burned]);
      expect(
        tester.widget<VideoPreview>(find.byType(VideoPreview)).cues,
        isEmpty,
      );
      expect(shownSubtitle(tester), isNull, reason: 'субтитры уже в кадре');
      expect(
        tester.widget<TextField>(translationField(1)).enabled,
        isFalse,
        reason: 'правка готового файла не меняет',
      );

      await tester.tap(find.text('Вернуться к правке'));
      await tester.pump();
      expect(rig.player.opened, [_video, _burned, _video]);
      expect(
        tester.widget<VideoPreview>(find.byType(VideoPreview)).cues,
        hasLength(5),
      );
      expect(tester.widget<TextField>(translationField(1)).enabled, isTrue);
      await finishReview(tester, rig);
    });

    testWidgets('в режиме «Посмотреть результат» поля перевода выглядят '
        'только для чтения, и сказано, как вернуться к правке', (tester) async {
      // Раньше поле было отключено, но текст в нём оставался чёрным, как в
      // обычном: человек щёлкал по опечатке, курсор не ставился, и
      // объяснения не было.
      final rig = await pumpReview(tester);
      final scheme = Theme.of(tester.element(cueRowFinder(1))).colorScheme;
      Color? textColor(int i) => tester
          .widget<EditableText>(find.descendant(
              of: translationField(i), matching: find.byType(EditableText)))
          .style
          .color;
      final editableColor = textColor(1);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(),
      );
      await tester.pump();
      await tester.tap(find.text('Посмотреть результат'));
      await tester.pump();

      expect(tester.widget<TextField>(translationField(1)).enabled, isFalse);
      expect(textColor(1), isNot(editableColor),
          reason: 'отключённое поле не должно выглядеть обычным');
      expect(textColor(1), scheme.onSurfaceVariant);
      expect(find.text('впишите перевод'), findsNothing,
          reason: 'подсказка зовёт печатать, а ввод не принимается');
      expect(
          find.textContaining(
              'Чтобы исправить текст, нажмите «Вернуться к правке»'),
          findsOneWidget);

      await tester.tap(find.text('Вернуться к правке'));
      await tester.pump();
      expect(textColor(1), editableColor);
      expect(find.text('впишите перевод'), findsWidgets);
      await finishReview(tester, rig);
    });

    testWidgets('уход с экрана во время просмотра результата не открывает '
        'исходник заново', (tester) async {
      final rig = await pumpReview(tester);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(),
      );
      await tester.pump();
      await tester.tap(find.text('Посмотреть результат'));
      await tester.pump();
      expect(rig.player.opened, [_video, _burned]);

      // «Другое видео»: контроллер сбрасывает сохранение и уходит на
      // главный экран. Плеер вот-вот закроется — декодер заново не нужен.
      rig.controller.debugEmulate(
        stage: AppStage.home,
        saveStatus: SaveStatus.idle,
      );
      await tester.pump();
      expect(rig.player.opened, [_video, _burned]);
      await finishReview(tester, rig);
    });

    testWidgets('перед сохранением плеер на паузе; отказ — панель ошибки', (
      tester,
    ) async {
      final rig = await pumpReview(tester, session: _untranslated());
      rig.player.playingValue.value = true;

      await tester.tap(find.text('Сохранить видео с субтитрами'));
      await tester.pump();
      await tester.pump();

      expect(rig.player.pauseCalls, 1);
      expect(rig.controller.saveStatus, SaveStatus.failed);
      expect(find.text('Нет ни одной реплики с переводом'), findsOneWidget);
      expect(
        find.text(
          'Впишите перевод хотя бы одной реплики — тогда будет '
          'что вшить.',
        ),
        findsOneWidget,
      );
      // Сырой текст — только в «Технических деталях».
      expect(find.text('Технические детали'), findsOneWidget);
      expect(find.textContaining('вшивать нечего'), findsNothing);
      await tester.tap(find.text('Технические детали'));
      await tester.pumpAndSettle();
      expect(find.textContaining('вшивать нечего'), findsOneWidget);
      await finishReview(tester, rig);
    });

    testWidgets('ошибка сохранения: «Сохранить журнал» в «Технических '
        'деталях» сохраняет журнал без ключа и показывает файл', (
      tester,
    ) async {
      // Подсказки ошибок сохранения просят прислать журнал, а кнопка есть
      // только здесь. Её цепочка — экран → полоса сохранения → панель
      // ошибки → детали; потеряй колбэк любое звено — кнопка молча
      // пропала бы. Приложение целиком: уведомление «Журнал сохранён»
      // показывает Scaffold оболочки.
      final h = await started();
      h.log.warn('Запрос с ключом $kTestApiKey не прошёл');
      h.controller.debugEmulate(
        stage: AppStage.review,
        session: sampleSession(),
        saveStatus: SaveStatus.failed,
        saveError: describeError(
          StateError('Не удалось вшить субтитры: выдуманный вывод ffmpeg'),
          mask: h.log.mask,
        ),
      );
      await pumpApp(tester, h.controller);
      // Не pumpAndSettle: плеер-подделка оболочки видео не «загружает», и в
      // кадре всё время крутится индикатор.
      Future<void> settle() => tester.pump(const Duration(milliseconds: 500));

      final details = find.text('Технические детали');
      await tester.ensureVisible(details);
      await settle();
      await tester.tap(details);
      await settle();
      final saveLog = find.text('Сохранить журнал');
      expect(saveLog, findsOneWidget);
      await tester.ensureVisible(saveLog);
      await settle();
      await tester.tap(saveLog);
      // Запись файла — настоящий ввод-вывод: ему нужно настоящее время.
      for (var i = 0; i < 50 && h.revealed.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      expect(h.revealed, hasLength(1));
      final saved = File(h.revealed.single);
      expect(p.isWithin(h.runtime.supportDir, saved.path), isTrue);
      final text = saved.readAsStringSync();
      expect(text, contains('Запуск приложения'));
      expect(text, contains('***КЛЮЧ***'));
      expect(text, isNot(contains(kTestApiKey)));
      await tester.pump();
      expect(find.textContaining('Журнал сохранён:'), findsOneWidget);
      await closeApp(tester, h);
    });

    testWidgets('ошибка с «Повторить» — одна кнопка, а не две', (tester) async {
      final rig = await pumpReview(tester);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.failed,
        saveError: const UserError(
          title:
              'Файл clip_ru.mp4 открыт в другой программе, закройте его и '
              'повторите',
          hint: 'Чаще всего это видеоплеер.',
          action: UserErrorAction.retry,
        ),
      );
      await tester.pump();

      expect(find.textContaining('открыт в другой программе'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Повторить'), findsOneWidget);
      expect(find.text('Сохранить видео с субтитрами'), findsNothing);
      await finishReview(tester, rig);
    });

    testWidgets('файлы в папке программы — плашка с путём и «Открыть папку»', (
      tester,
    ) async {
      const fallback = '/программа/output/clip_ru.mp4';
      final rig = await pumpReview(tester);
      rig.controller.debugEmulate(
        saveStatus: SaveStatus.saved,
        saveResult: _saved(video: fallback, inFallback: true),
      );
      await tester.pump();

      final plate = find.byKey(const ValueKey('review-fallback'));
      expect(plate, findsOneWidget);
      expect(
        find.descendant(
          of: plate,
          matching: find.textContaining('/программа/output'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: plate, matching: find.text('Открыть папку')),
      );
      await tester.pump();
      expect(rig.h.revealed, [fallback]);
      await finishReview(tester, rig);
    });
  });

  group('Остановленная обработка и сообщения', () {
    testWidgets('частичный результат — «распознано N из M» и «Продолжить '
        'распознавание»', (tester) async {
      final rig = await pumpReview(tester, session: _partial());

      expect(
        find.text('Обработка была остановлена: распознано 3 из 5 реплик'),
        findsOneWidget,
      );
      final button = find.widgetWithText(
        FilledButton,
        'Продолжить распознавание',
      );
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(cueRow(tester, 4).tone, CueTone.pending);
      expect(
        find.descendant(
          of: cueRowFinder(5),
          matching: find.text('ещё не распознано'),
        ),
        findsOneWidget,
      );
      await finishReview(tester, rig);
    });

    testWidgets('полная сессия — плашки об остановке нет', (tester) async {
      final rig = await pumpReview(tester);
      expect(find.byKey(const ValueKey('review-partial')), findsNothing);
      await finishReview(tester, rig);
    });

    // Сообщения контроллера и вопрос о длинном ролике на этом экране не
    // рисуются: их показывает оболочка над любым экраном (см.
    // app_shell_test «…показываются по одному разу»).
  });

  testWidgets('узкое окно: плеер сверху, список под ним, без переполнения', (
    tester,
  ) async {
    final rig = await pumpReview(tester, window: const Size(420, 800));
    final frame = tester.getRect(find.byKey(FakePreviewPlayer.frameKey));
    final firstRow = tester.getRect(cueRowFinder(1));
    expect(frame.bottom, lessThanOrEqualTo(firstRow.top));
    expect(tester.takeException(), isNull);
    await finishReview(tester, rig);
  });
}
