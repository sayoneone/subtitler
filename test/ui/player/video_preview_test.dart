import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/ui/player/subtitle_overlay.dart';
import 'package:subtitler/ui/player/video_preview.dart';

import '../../support/fake_preview_player.dart';

Cue cue(
  int index,
  double start,
  double end,
  String ru, {
  CueStatus status = CueStatus.ok,
}) =>
    Cue(
      index: index,
      range: TimeRange(start, end),
      orig: 'orig $index',
      ru: ru,
      status: status,
      flags: const {},
    );

final _cues = [
  cue(1, 1.0, 3.0, 'Первая реплика'),
  cue(2, 3.0, 5.0, 'Вторая реплика'),
  cue(3, 5.0, 7.0, 'Остаток', status: CueStatus.empty),
  cue(4, 7.0, 9.0, '   '),
  cue(5, 9.0, 11.0, 'Пятая'),
];

/// Текст, который сейчас нарисован поверх кадра, или `null`.
String? shownText(WidgetTester tester) {
  final found = find.byType(OutlinedSubtitleText);
  if (found.evaluate().isEmpty) return null;
  return tester.widget<OutlinedSubtitleText>(found).text;
}

Future<void> pumpPreview(
  WidgetTester tester,
  FakePreviewPlayer player,
  List<Cue> cues, {
  Size surface = const Size(1000, 700),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: VideoPreview(player: player, cues: cues)),
  ));
}

Future<void> at(WidgetTester tester, FakePreviewPlayer player, int ms) async {
  player.positionValue.value = Duration(milliseconds: ms);
  await tester.pump();
}

void main() {
  testWidgets('поверх кадра — реплика, звучащая в текущий момент',
      (tester) async {
    final player = FakePreviewPlayer()..loaded();
    await pumpPreview(tester, player, _cues);

    expect(find.byKey(FakePreviewPlayer.frameKey), findsOneWidget);
    expect(shownText(tester), isNull);

    await at(tester, player, 1000);
    expect(shownText(tester), 'Первая реплика');
    await at(tester, player, 2999);
    expect(shownText(tester), 'Первая реплика');
    await at(tester, player, 3000);
    expect(shownText(tester), 'Вторая реплика');
    await at(tester, player, 9500);
    expect(shownText(tester), 'Пятая');
    await at(tester, player, 11000);
    expect(shownText(tester), isNull);
  });

  testWidgets('«речи нет» и пустой перевод в кадр не попадают',
      (tester) async {
    final player = FakePreviewPlayer()..loaded();
    await pumpPreview(tester, player, _cues);

    await at(tester, player, 6000); // empty с остатком текста
    expect(shownText(tester), isNull);
    await at(tester, player, 8000); // перевод из одних пробелов
    expect(shownText(tester), isNull);
  });

  testWidgets('правка перевода сразу видна в кадре, без движения позиции',
      (tester) async {
    final player = FakePreviewPlayer()..loaded();
    var cues = List.of(_cues);
    late StateSetter rebuild;
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return VideoPreview(player: player, cues: cues);
        }),
      ),
    ));
    await at(tester, player, 1500);
    expect(shownText(tester), 'Первая реплика');

    rebuild(() {
      cues = [cues[0].copyWith(ru: 'Исправленная реплика'), ...cues.skip(1)];
    });
    await tester.pump();
    expect(shownText(tester), 'Исправленная реплика');

    // Правка в том же списке (без нового объекта) тоже не теряется.
    rebuild(() => cues[0] = cues[0].copyWith(ru: 'Ещё раз исправлена'));
    await tester.pump();
    expect(shownText(tester), 'Ещё раз исправлена');

    // Стёртый перевод пропадает из кадра так же сразу.
    rebuild(() => cues[0] = cues[0].copyWith(ru: ''));
    await tester.pump();
    expect(shownText(tester), isNull);
  });

  testWidgets('плеер не открыл файл — надпись вместо кадра', (tester) async {
    final player = FakePreviewPlayer();
    await pumpPreview(tester, player, _cues);
    expect(find.text(kPreviewUnavailableText), findsNothing);

    player.errorValue.value = '[cplayer] Failed to recognize file format.';
    await tester.pump();

    expect(find.text(kPreviewUnavailableText), findsOneWidget);
    expect(find.byKey(FakePreviewPlayer.frameKey), findsNothing);
    // Технический текст ошибки человеку не показывается.
    expect(find.textContaining('cplayer'), findsNothing);
  });

  testWidgets('кнопка воспроизведения вызывает toggle и меняет значок',
      (tester) async {
    final player = FakePreviewPlayer()..loaded();
    await pumpPreview(tester, player, _cues);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-play')));
    await tester.pump();

    expect(player.toggleCalls, 1);
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('пока файл не разобран, кнопка неактивна', (tester) async {
    final player = FakePreviewPlayer();
    await pumpPreview(tester, player, _cues);

    await tester.tap(find.byKey(const ValueKey('preview-play')));
    await tester.pump();
    expect(player.toggleCalls, 0);
  });

  testWidgets('щелчок по ползунку перематывает', (tester) async {
    final player = FakePreviewPlayer()
      ..loaded(duration: const Duration(seconds: 100));
    await pumpPreview(tester, player, _cues);

    await tester.tap(find.byKey(const ValueKey('preview-slider')));
    await tester.pump();

    expect(player.seeks, hasLength(1));
    // Щелчок по центру ползунка — середина ролика.
    expect(player.seeks.single.inSeconds, closeTo(50, 2));
  });

  testWidgets('время показывается как в плеере', (tester) async {
    expect(formatPreviewTime(Duration.zero), '0:00');
    expect(formatPreviewTime(const Duration(seconds: 65)), '1:05');
    expect(formatPreviewTime(const Duration(hours: 1, seconds: 125)),
        '1:02:05');
  });

  testWidgets('кадр сохраняет пропорции видео, субтитры лежат на кадре',
      (tester) async {
    final player = FakePreviewPlayer()..loaded(size: const Size(848, 480));
    await pumpPreview(tester, player, _cues);

    final frame = tester.getSize(find.byType(SubtitleOverlay));
    expect(frame.width / frame.height, closeTo(848 / 480, 0.01));
  });

  testWidgets('кегль, обводка и отступы — в масштабе PlayResY 288',
      (tester) async {
    final player = FakePreviewPlayer()..positionValue.value = Duration.zero;
    // Кадр вдвое выше сценария: всё должно стать вдвое крупнее.
    const frame = Size(768, 576);
    await tester.binding.setSurfaceSize(frame);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: frame,
          child: SubtitleOverlay(
            cues: [cue(1, 0, 2, 'Проверка')],
            position: player.position,
          ),
        ),
      ),
    ));

    final text = tester.widget<OutlinedSubtitleText>(
        find.byType(OutlinedSubtitleText));
    // FontSize 16 — высота строки по метрикам шрифта, кегль в 1.362 раза
    // меньше.
    expect(text.fontSize, closeTo(16 * 2 / 1.362, 1e-9));
    expect(text.outline, 4);

    // Меряем сами строки текста (обводку и заливку), а не рамку вокруг:
    // короткая реплика уже рамки, и рамка по центру ещё не значит, что
    // текст в ней по центру.
    final layers = find.descendant(
        of: find.byType(OutlinedSubtitleText), matching: find.byType(Text));
    expect(layers, findsNWidgets(2));
    for (final layer in layers.evaluate()) {
      final box = tester.getRect(find.byWidget(layer.widget));
      // MarginV 10 точек сценария = 20 пикселей от низа кадра.
      expect(box.bottom, closeTo(frame.height - 20, 0.5));
      // По центру кадра, с боковыми полями MarginL/R 10 из 384 по ширине.
      expect(box.center.dx, closeTo(frame.width / 2, 0.5));
      expect(box.left, greaterThanOrEqualTo(20 - 0.5));
      expect(box.right, lessThanOrEqualTo(frame.width - 20 + 0.5));
    }
  });

  test('длинная реплика делится на ровные строки, как у libass', () {
    const style = TextStyle(fontSize: 10);
    const text = 'aaaa aaaa aaaa aaaa aaaa';
    int lines(double width) {
      final p = TextPainter(
        text: const TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final n = p.computeLineMetrics().length;
      p.dispose();
      return n;
    }

    const max = 200.0;
    expect(lines(max), 2, reason: 'жадный перенос: четыре слова и одно');
    final w = balancedWrapWidth(text, style, max);
    expect(lines(w), 2, reason: 'строк столько же');
    expect(lines(w - 2), 3, reason: 'уже нельзя — это самая узкая ширина');
    expect(w, lessThan(max * 0.8), reason: 'строки стали ровнее');

    expect(balancedWrapWidth('aaaa', style, max), max,
        reason: 'одну строку не трогаем');
  });
}
