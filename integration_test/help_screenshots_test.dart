// Снимки экранов программы для руководства «Как пользоваться»
// (assets/help/app-*.png).
//
// Экраны — настоящие виджеты программы на поддельном контроллере, как в
// виджет-тестах, но в собранном приложении: со шрифтами и отрисовкой той
// системы, где идёт прогон. Руководство читают на Windows, поэтому
// картинки для него снимаются там — это делает CI при ручном запуске
// сборки (артефакт help-screenshots), а сюда их кладут руками:
//
//   $env:SUBTITLER_SCREENSHOTS = "$PWD\build\help-screenshots"
//   flutter test integration_test/help_screenshots_test.dart -d windows
//
// Без SUBTITLER_SCREENSHOTS тест пропускается. Нужен и SUBTITLER_FFMPEG:
// подделки контроллера — те же, что у тестов (test/support).
//
// Стрелки на снимках рисует сам тест поверх экрана — к кнопкам, которые
// называет шаг руководства, по их настоящему положению.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/app/settings.dart';
import 'package:subtitler/core/models.dart';
import 'package:subtitler/main.dart';

import '../test/support/fake_preview_player.dart';
import '../test/ui/support.dart';

/// Размер окна на снимке, в логических точках. Уже окна по умолчанию
/// (1280): в руководстве снимок ужимается до ширины текста, и мелкие
/// надписи на нём перестали бы читаться.
const Size _window = Size(1040, 660);

/// Плотность снимка: чёткий и на экране с масштабом 150 %.
const double _pixelRatio = 1.5;

const _shot = ValueKey('shot');

/// Выдуманная запись и её «материалы»: никаких настоящих дел.
final String _video = Platform.isWindows
    ? r'C:\Users\User\Desktop\Видео\VID_20260902_195725.mp4'
    : '/Users/user/Desktop/Видео/VID_20260902_195725.mp4';

Session _session() => Session(
      videoPath: _video,
      fingerprint: const SourceFingerprint(sizeBytes: 9797225, durationSec: 52),
      lang: 'tr-TR',
      langConfidence: LanguageConfidence.high,
      langRunnerUp: 'uz-UZ',
      silenceThreshold: '-30dB',
      forcedSplit: false,
      cues: [
        _cue(1, 0.4, 3.1, 'Merhaba, beni duyabiliyor musun?',
            'Привет, ты меня слышишь?'),
        _cue(2, 3.8, 7.2, 'Evet, seni çok iyi duyuyorum.',
            'Да, я тебя очень хорошо слышу.'),
        _cue(3, 8.0, 12.4, 'Yarın sabah saat dokuzda buluşalım mı?',
            'Давай встретимся завтра в девять утра?'),
        const Cue(
            index: 4,
            range: TimeRange(13.0, 15.1),
            orig: '',
            ru: '',
            status: CueStatus.empty,
            flags: {}),
        _cue(5, 15.9, 20.3, 'tamam tamam tamam tamam',
            'хорошо хорошо хорошо хорошо',
            flags: {CueFlag.repeatLoop}),
        _cue(6, 21.0, 25.6, 'Arabayı evin önüne park ettim.',
            'Я поставил машину перед домом.'),
        _cue(7, 26.2, 29.5, 'Sonra seni ararım.', 'Потом я тебе позвоню.'),
        _cue(8, 30.4, 34.0, 'Annene selam söyle.', 'Передай привет маме.'),
      ],
    );

Cue _cue(int index, double start, double end, String orig, String ru,
        {Set<CueFlag> flags = const {}}) =>
    Cue(
      index: index,
      range: TimeRange(start, end),
      orig: orig,
      ru: ru,
      status: CueStatus.ok,
      flags: flags,
    );

/// «Кадр видео» для предпросмотра: нарисованная сцена вместо ролика.
class _FramePlayer extends FakePreviewPlayer {
  @override
  Widget view() => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF5B7DA6), Color(0xFF9DB4C9), Color(0xFF4A5A48)],
            stops: [0, 0.55, 0.56],
          ),
        ),
        child: CustomPaint(painter: _ScenePainter()),
      );
}

class _ScenePainter extends CustomPainter {
  const _ScenePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final house = Paint()..color = const Color(0xFFD9C7A7);
    final roof = Paint()..color = const Color(0xFF8C4B3A);
    final window = Paint()..color = const Color(0xFF3B4A5C);
    canvas.drawRect(Rect.fromLTWH(w * 0.12, h * 0.30, w * 0.30, h * 0.26), house);
    canvas.drawPath(
        Path()
          ..moveTo(w * 0.09, h * 0.31)
          ..lineTo(w * 0.27, h * 0.16)
          ..lineTo(w * 0.45, h * 0.31)
          ..close(),
        roof);
    for (final x in [0.16, 0.30]) {
      canvas.drawRect(
          Rect.fromLTWH(w * x, h * 0.36, w * 0.07, h * 0.08), window);
    }
    final tree = Paint()..color = const Color(0xFF3F6B3A);
    canvas.drawCircle(Offset(w * 0.72, h * 0.38), h * 0.13, tree);
    canvas.drawRect(Rect.fromLTWH(w * 0.715, h * 0.45, w * 0.012, h * 0.11),
        Paint()..color = const Color(0xFF5A4030));
    final car = Paint()..color = const Color(0xFFB8BFC6);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.50, h * 0.50, w * 0.16, h * 0.08),
            Radius.circular(h * 0.02)),
        car);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Стрелка к [target] от точки [from] — как красные стрелки на снимках
/// Яндекс Облака в руководстве, только ровные: изогнутая линия с белой
/// окантовкой (видна на любом фоне) и рамка вокруг цели.
class _Callout {
  final Rect target;
  final Offset from;

  /// Насколько рамка шире цели с каждой стороны.
  final EdgeInsets pad;
  const _Callout(this.target, this.from, this.pad);
}

/// К чему стрелка: цель — [finder] (с [also] — рамка вокруг всех), [shift]
/// — откуда идёт стрелка (сдвиг от середины цели), [pad] — запас рамки.
class _Aim {
  final Finder finder;
  final List<Finder> also;
  final Offset shift;
  final EdgeInsets pad;
  const _Aim(this.finder, this.shift,
      {this.also = const [], this.pad = const EdgeInsets.all(6)});
}

/// Кнопка целиком, а не только её надпись.
Finder _button(String label) => find
    .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
    .first;

class _CalloutPainter extends CustomPainter {
  final List<_Callout> callouts;
  const _CalloutPainter(this.callouts);

  static const _red = Color(0xFFE5392F);

  @override
  void paint(Canvas canvas, Size size) {
    for (final c in callouts) {
      final frame = RRect.fromRectAndRadius(
          c.pad.inflateRect(c.target), const Radius.circular(10));
      // Направление от цели к началу стрелки и точка на краю рамки.
      final center = frame.center;
      final away = c.from - center;
      final dir = away / away.distance;
      final half = frame.outerRect.size / 2;
      final t = [
        if (dir.dx != 0) half.width / dir.dx.abs(),
        if (dir.dy != 0) half.height / dir.dy.abs(),
      ].reduce((a, b) => a < b ? a : b);
      final end = center + dir * (t + 8);
      // Изгиб — в сторону от прямой, на пятую часть длины.
      final mid = Offset.lerp(c.from, end, 0.5)!;
      final normal = Offset(-(end - c.from).dy, (end - c.from).dx) /
          (end - c.from).distance;
      final control = mid + normal * ((end - c.from).distance * 0.2);
      final line = Path()
        ..moveTo(c.from.dx, c.from.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);

      // Наконечник: вдоль касательной в конце кривой.
      final tip = (end - control) / (end - control).distance;
      final side = Offset(-tip.dy, tip.dx);
      final head = Path()
        ..moveTo(end.dx + tip.dx * 4, end.dy + tip.dy * 4)
        ..lineTo(end.dx - tip.dx * 18 + side.dx * 10,
            end.dy - tip.dy * 18 + side.dy * 10)
        ..lineTo(end.dx - tip.dx * 18 - side.dx * 10,
            end.dy - tip.dy * 18 - side.dy * 10)
        ..close();

      final shadow = Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      final halo = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final ink = Paint()
        ..color = _red
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      canvas.drawRRect(frame, shadow..style = PaintingStyle.stroke..strokeWidth = 6);
      canvas.drawPath(line, shadow..strokeWidth = 8);
      canvas.drawRRect(frame, halo..strokeWidth = 7);
      canvas.drawRRect(frame, ink..strokeWidth = 3.5);
      canvas.drawPath(line, halo..strokeWidth = 9);
      canvas.drawPath(head, halo..strokeWidth = 5);
      canvas.drawPath(line, ink..strokeWidth = 5);
      canvas.drawPath(head, Paint()..color = _red);
    }
  }

  @override
  bool shouldRepaint(covariant _CalloutPainter old) => old.callouts != callouts;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['SUBTITLER_SCREENSHOTS'];

  final callouts = ValueNotifier<List<_Callout>>(const []);

  /// Снимок со стрелками [arrows] к виджетам экрана.
  Future<void> shoot(WidgetTester tester, String name,
      {List<_Aim> arrows = const []}) async {
    // Анимации появления и индикаторы — до устойчивого кадра.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    Rect target(_Aim aim) => [
          for (final f in [aim.finder, ...aim.also]) tester.getRect(f.first),
        ].reduce((a, b) => a.expandToInclude(b));
    callouts.value = [
      for (final aim in arrows)
        _Callout(target(aim), target(aim).center + aim.shift, aim.pad),
    ];
    await tester.pump();
    final boundary =
        tester.firstRenderObject<RenderRepaintBoundary>(find.byKey(_shot));
    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(p.join(out!, name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
    debugPrint('Снимок: ${file.path}');
  }

  testWidgets('экраны для руководства', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _window;
    addTearDown(tester.view.reset);

    final h = await started(
        storedKey: null, settings: const AppSettings(helpShown: true));
    final c = h.controller;
    late _FramePlayer player;
    await tester.pumpWidget(RepaintBoundary(
      key: _shot,
      child: Stack(
        textDirection: TextDirection.ltr,
        fit: StackFit.expand,
        children: [
          SubtitlerApp(
            controller: c,
            playerFactory: ({log}) => player = _FramePlayer(),
            openHelpWindow: () async => true,
          ),
          IgnorePointer(
            child: ValueListenableBuilder(
              valueListenable: callouts,
              builder: (context, list, _) =>
                  CustomPaint(painter: _CalloutPainter(list)),
            ),
          ),
        ],
      ),
    ));

    // 1. Ключ: вставлен и проверен.
    expect(c.stage, AppStage.needsKey);
    await tester.enterText(
        find.byKey(const ValueKey('key-field')), 'AQVN' * 10);
    c.debugEmulate(
        keyCheck: const KeyCheckResult(
            translate: CheckState.ok, stt: CheckState.ok));
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await shoot(tester, 'app-key.png', arrows: [
      // Поле и кнопка — одна рамка: вставить ключ и нажать. Подпись поля
      // лежит на его рамке — сверху рамка стрелки отступает больше.
      _Aim(find.byKey(const ValueKey('key-field')), const Offset(-440, -40),
          also: [_button('Проверить и сохранить')],
          pad: const EdgeInsets.fromLTRB(8, 14, 8, 6)),
      _Aim(find.text('Перевод'), const Offset(-190, 60),
          also: [find.text('Распознавание'), find.byIcon(Icons.check_circle)]),
    ]);

    // 2. Главный экран.
    c.debugEmulate(stage: AppStage.home, hasKey: true);
    await shoot(tester, 'app-home.png', arrows: [
      _Aim(_button('Выбрать файл'), const Offset(240, 110)),
    ]);

    // 3. Обработка: язык определён, идёт распознавание.
    final session = _session();
    c.debugEmulate(
      stage: AppStage.processing,
      videoPath: _video,
      session: session,
      processingSteps: ProcessingStep.values,
      progress: const ProcessingProgress(ProcessingStep.recognizing,
          done: 5, total: 8),
    );
    await shoot(tester, 'app-processing.png', arrows: [
      _Aim(find.text('Распознаём речь: 5 из 8'), const Offset(330, -90)),
    ]);

    // 4. Проверка перевода: кадр с субтитрами третьей реплики.
    c.debugEmulate(stage: AppStage.review, session: session);
    await tester.pump();
    player.loaded(
        duration: const Duration(seconds: 52), size: const Size(1280, 720));
    await player.seek(const Duration(seconds: 9));
    await shoot(tester, 'app-overview.png');
    // Стрелки идут по пустым местам: от неба в кадре к правке реплики и
    // от пустого края первой строки списка к «Не тот язык?».
    await shoot(tester, 'app-review.png', arrows: [
      _Aim(find.text('0:08'), const Offset(-370, 10), also: [
        find.text('Давай встретимся завтра в девять утра?').last,
        find.text('Yarın sabah saat dokuzda buluşalım mı?').last,
      ]),
      _Aim(find.text('Не тот язык?'), const Offset(-120, 70)),
    ]);

    // 5. Видео сохранено.
    c.debugEmulate(
      saveStatus: SaveStatus.saved,
      saveResult: SaveResult(
        videoPath: p.join(
            p.dirname(_video), '${p.basenameWithoutExtension(_video)}_ru.mp4'),
        inFallback: false,
      ),
    );
    // Плашка результата целиком: над кнопками — имя файла и папка, и
    // стрелка к одной кнопке перечеркнула бы их.
    await shoot(tester, 'app-saved.png', arrows: [
      _Aim(find.byKey(const ValueKey('review-saved')), const Offset(-100, -205),
          pad: const EdgeInsets.all(3)),
    ]);

    // 6. Журнал работы: «⋮» → «Журнал работы». Записи — как у настоящей
    // обработки, но выдуманные: в журнале тестов пути временных папок.
    final log = h.log
      ..clear()
      ..info('Запуск приложения')
      ..info('ffmpeg найден (с libass)')
      ..info('Ключ загружен из хранилища (40 символов)')
      ..info('Выбрано видео: …${p.separator}VID_20260902_195725.mp4')
      ..info('Длительность 52,00 с')
      ..info('Похоже на tr-TR (отрыв 0.50)')
      ..info('Переведено реплик: 7')
      ..info('Готово. Реплик 8, на проверку 1')
      ..info('Субтитры в кадре видны')
      ..info('Готово: …${p.separator}VID_20260902_195725_ru.mp4');
    expect(log.entries, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Журнал работы').last);
    await tester.pumpAndSettle();
    await shoot(tester, 'app-log.png', arrows: [
      _Aim(_button('Сохранить в файл'), const Offset(190, 170)),
    ]);
    callouts.value = const [];

    await tester.pumpWidget(const SizedBox());
    await h.dispose();
  }, skip: out == null);
}
