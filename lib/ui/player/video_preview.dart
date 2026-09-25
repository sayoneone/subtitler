import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'preview_player.dart';
import 'subtitle_overlay.dart';

/// Надпись вместо кадра, когда плеер не смог открыть файл. Предпросмотр —
/// удобство, а не условие: субтитры проверяются и сохраняются и без него.
const String kPreviewUnavailableText =
    'Не удалось показать видео — субтитры можно проверить и сохранить';

/// Кадр с субтитрами поверх и простые кнопки под ним.
///
/// Кадр вписывается в доступное место с сохранением пропорций, а
/// [SubtitleOverlay] кладётся ровно на кадр, а не на чёрные поля вокруг:
/// libass считает отступы от краёв кадра.
///
/// Плеер создаёт и закрывает владелец экрана: виджет может пересоздаваться
/// при перестройке раскладки, а декодер от этого перезапускаться не должен.
class VideoPreview extends StatelessWidget {
  const VideoPreview({
    super.key,
    required this.player,
    required this.cues,
  });

  final PreviewPlayer player;

  /// Что рисовать поверх кадра. Для готового `<имя>_ru.mp4`, где субтитры
  /// уже вшиты, — пустой список, иначе в кадре их будет два слоя.
  final List<Cue> cues;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: player.error,
      builder: (context, error, _) {
        if (error != null) return const _Unavailable();
        return LayoutBuilder(builder: (context, box) {
          final frame = _Frame(player: player, cues: cues);
          final controls = PreviewControls(player: player);
          // В колонке без ограничения высоты растягивать кадр некуда — тогда
          // он просто берёт пропорции 16:9 по ширине.
          if (!box.hasBoundedHeight) {
            return Column(mainAxisSize: MainAxisSize.min, children: [
              AspectRatio(aspectRatio: 16 / 9, child: frame),
              controls,
            ]);
          }
          return Column(children: [Expanded(child: frame), controls]);
        });
      },
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.player, required this.cues});

  final PreviewPlayer player;
  final List<Cue> cues;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder<Size?>(
        valueListenable: player.videoSize,
        builder: (context, size, _) {
          // Пока кадр не декодирован, пропорции неизвестны: держим 16:9 и
          // крутилку, а сам вид плеера уже в дереве — первый кадр придёт в
          // него без пересоздания текстуры.
          final aspect = size == null ? 16 / 9 : size.width / size.height;
          return Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: player.toggle,
                child: Stack(fit: StackFit.expand, children: [
                  player.view(),
                  if (size == null)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white70),
                    )
                  else
                    SubtitleOverlay(cues: cues, position: player.position),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Кнопка «воспроизвести/пауза», ползунок и время.
class PreviewControls extends StatefulWidget {
  const PreviewControls({super.key, required this.player});

  final PreviewPlayer player;

  @override
  State<PreviewControls> createState() => _PreviewControlsState();
}

class _PreviewControlsState extends State<PreviewControls> {
  /// Куда тянут ползунок, пока палец или мышь не отпущены. Перематываем
  /// только по отпусканию: без аппаратного декодирования серия перемоток
  /// на каждый пиксель выстраивается в очередь и ползунок «залипает».
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ListenableBuilder(
        listenable: Listenable.merge([p.position, p.duration, p.playing]),
        builder: (context, _) {
          final total = p.duration.value.inMilliseconds.toDouble();
          final ready = total > 0;
          final pos = (_dragMs ?? p.position.value.inMilliseconds.toDouble())
              .clamp(0.0, ready ? total : 0.0);
          final playing = p.playing.value;
          return Row(children: [
            IconButton(
              key: const ValueKey('preview-play'),
              tooltip: playing ? 'Пауза' : 'Воспроизвести',
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: ready ? p.toggle : null,
            ),
            Text(formatPreviewTime(Duration(milliseconds: pos.round())),
                style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()])),
            Expanded(
              child: Slider(
                key: const ValueKey('preview-slider'),
                value: pos,
                max: ready ? total : 1,
                onChanged: ready ? (v) => setState(() => _dragMs = v) : null,
                onChangeEnd: ready
                    ? (v) {
                        setState(() => _dragMs = null);
                        p.seek(Duration(milliseconds: v.round()));
                      }
                    : null,
              ),
            ),
            Text(formatPreviewTime(p.duration.value),
                style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(width: 8),
          ]);
        },
      ),
    );
  }
}

/// «1:05» или «1:02:05» — как в любом плеере.
String formatPreviewTime(Duration d) {
  final s = d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  return h > 0 ? '$h:${two(m)}:${two(s % 60)}' : '$m:${two(s % 60)}';
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.videocam_off_outlined,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              kPreviewUnavailableText,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ),
    );
  }
}
