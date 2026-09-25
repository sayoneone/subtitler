import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/cue_timeline.dart';
import '../../core/models.dart';

/// Стиль, которым ffmpeg вшивает наши SRT, — чтобы предпросмотр выглядел
/// как готовое видео.
///
/// Откуда числа. SRT своего стиля не несёт; ffmpeg подставляет стиль по
/// умолчанию (libavcodec/ass.h и ass.c, ветка release/9.0 — наш ffmpeg
/// 9.0.1): PlayResX 384, PlayResY 288, FontSize 16, белый текст, чёрная
/// обводка, BorderStyle 1, Shadow 0, выравнивание 2 (низ по центру),
/// MarginL = MarginR = MarginV = 10, ScaledBorderAndShadow: yes.
/// Поверх — наш force_style из `FfmpegCommands.burnSubtitles`:
/// FontName=Noto Sans, Outline=2.
///
/// Всё это — в «точках сценария». Кадр высотой H пикселей — это 288 точек по
/// вертикали: размер шрифта, обводка и нижний отступ умножаются на H/288.
/// По горизонтали libass растягивает координаты на W/384, но буквы не
/// искажает (поправка на пропорции пикселя), поэтому ширина букв тоже
/// следует H/288, а боковые отступы — W/384.
abstract final class BurnedSubtitleStyle {
  static const double playResX = 384;
  static const double playResY = 288;
  static const double fontSize = 16;
  static const double outline = 2;
  static const double marginV = 10;
  static const double marginH = 10;

  /// Семейство из pubspec.yaml: тот же NotoSans-Regular.ttf, что получает
  /// libass.
  static const String fontFamily = 'NotoSans';

  /// Во сколько раз строка NotoSans выше кегля: (usWinAscent + usWinDescent)
  /// / unitsPerEm = (1069 + 293) / 1000 из таблиц OS/2 и head самого файла.
  ///
  /// libass, как и VSFilter, понимает FontSize как высоту всей строки
  /// (FT_SIZE_REQUEST_TYPE_REAL_DIM по win-метрикам, libass/ass_font.c), а
  /// Flutter — как кегль (em). Без этой поправки текст в предпросмотре был
  /// бы на треть крупнее вшитого и переносился бы в других местах.
  static const double lineHeightPerEm = 1.362;
}

/// Рисует поверх кадра реплику, звучащую в момент [position], — так же, как
/// её нарисует libass при вшивании.
///
/// Ставится ровно поверх кадра (не окна плеера): отступы и кегль считаются
/// от размеров, которые виджет получил. Правка текста видна сразу: новый
/// список [cues] перестраивает выборку при следующей же сборке.
class SubtitleOverlay extends StatefulWidget {
  const SubtitleOverlay({
    super.key,
    required this.cues,
    required this.position,
  });

  final List<Cue> cues;
  final ValueListenable<Duration> position;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  late CueTimeline _timeline;
  String? _shown;

  @override
  void initState() {
    super.initState();
    _timeline = CueTimeline(widget.cues);
    _shown = _textAt(widget.position.value);
    widget.position.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(SubtitleOverlay old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    // Сравнивать списки незачем: перестроение — это отбор и сортировка
    // сотни реплик, а родитель пересобирается только при правке, не на
    // каждый кадр. Зато правка в том же списке не потеряется.
    _timeline = CueTimeline(widget.cues);
    _shown = _textAt(widget.position.value);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    super.dispose();
  }

  String? _textAt(Duration t) => _timeline.at(t)?.ru.trim();

  /// Позиция приходит до 30 раз в секунду, а реплика меняется раз в
  /// несколько секунд, поэтому перерисовка — только при смене текста.
  void _onPosition() {
    final text = _textAt(widget.position.value);
    if (text != _shown) setState(() => _shown = text);
  }

  @override
  Widget build(BuildContext context) {
    final text = _shown;
    if (text == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final ky = box.maxHeight / BurnedSubtitleStyle.playResY;
      final kx = box.maxWidth / BurnedSubtitleStyle.playResX;
      return Stack(children: [
        Positioned(
          left: BurnedSubtitleStyle.marginH * kx,
          right: BurnedSubtitleStyle.marginH * kx,
          bottom: BurnedSubtitleStyle.marginV * ky,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: OutlinedSubtitleText(
              text,
              fontSize: BurnedSubtitleStyle.fontSize *
                  ky /
                  BurnedSubtitleStyle.lineHeightPerEm,
              outline: BurnedSubtitleStyle.outline * ky,
            ),
          ),
        ),
      ]);
    });
  }
}

/// Белый текст с чёрной обводкой по центру, строки выровнены по ширине
/// так же, как у libass.
class OutlinedSubtitleText extends StatelessWidget {
  const OutlinedSubtitleText(
    this.text, {
    super.key,
    required this.fontSize,
    required this.outline,
  });

  final String text;

  /// Кегль во Flutter-смысле (em), уже пересчитанный из FontSize libass.
  final double fontSize;

  /// Толщина обводки в пикселях — насколько она выходит за контур буквы.
  final double outline;

  TextStyle get _style => TextStyle(
        fontFamily: BurnedSubtitleStyle.fontFamily,
        fontSize: fontSize,
        // Высота строки как у libass: ровно FontSize сценария.
        height: BurnedSubtitleStyle.lineHeightPerEm,
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.normal,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final style = _style;
      final width = balancedWrapWidth(text, style, box.maxWidth);
      Widget layer(TextStyle s) => Text(
            text,
            textAlign: TextAlign.center,
            // Субтитры вшиваются в кадр и от системного масштаба шрифта не
            // зависят — значит, и в предпросмотре не должны.
            textScaler: TextScaler.noScaling,
            softWrap: true,
            style: s,
          );
      return SizedBox(
        width: width,
        // Строка короче рамки сжимается до своей ширины, и textAlign её уже
        // не двигает — центрировать надо сам слой. Без этого «Да.» стояло
        // у левого края кадра, а libass рисует его по центру.
        child: Stack(alignment: Alignment.bottomCenter, children: [
          // Обводка: штрих ложится поровну внутрь и наружу контура, поэтому
          // толщина кисти — две обводки. Скруглённые стыки — как у libass.
          ExcludeSemantics(
            child: layer(_style.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2 * outline
                ..strokeJoin = StrokeJoin.round
                ..color = const Color(0xFF000000),
            )),
          ),
          layer(style.copyWith(color: const Color(0xFFFFFFFF))),
        ]),
      );
    });
  }
}

/// Ширина, при которой [text] займёт столько же строк, сколько при
/// [maxWidth], но строки выйдут ровнее.
///
/// libass по умолчанию (WrapStyle 0) переносит «умно»: строки примерно
/// равной длины, верхняя не короче нижней. Жадный перенос Flutter оставил бы
/// на второй строке одно слово там, где в готовом видео будут две ровные
/// половины. Самая узкая ширина с тем же числом строк даёт ту же картину.
@visibleForTesting
double balancedWrapWidth(String text, TextStyle style, double maxWidth) {
  if (!maxWidth.isFinite) return maxWidth;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  );
  try {
    painter.layout(maxWidth: maxWidth);
    final lines = painter.computeLineMetrics().length;
    if (lines <= 1) return maxWidth;
    var lo = 0.0;
    var hi = maxWidth;
    // До пикселя: 2^12 делений покрывают любую ширину экрана.
    for (var i = 0; i < 12 && hi - lo > 1; i++) {
      final mid = (lo + hi) / 2;
      painter.layout(maxWidth: mid);
      if (painter.computeLineMetrics().length > lines) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  } finally {
    painter.dispose();
  }
}
