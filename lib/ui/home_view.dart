import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'strings.dart';

/// Какие файлы предлагает диалог выбора. Список широкий: лишнее всё равно
/// отсеет проверка «это видео?», а узкий фильтр спрятал бы от человека
/// ролик в редком формате. `mimeTypes` — для Android, `uniformTypeIdentifiers`
/// — для macOS; Windows смотрит на расширения.
const XTypeGroup kVideoTypeGroup = XTypeGroup(
  label: AppStrings.videoTypeGroup,
  extensions: [
    'mp4', 'mov', 'mkv', 'avi', 'm4v', '3gp', 'webm', 'wmv', 'mts', 'm2ts',
    'ts', 'flv', 'mpg', 'mpeg', 'vob', 'ogv',
  ],
  mimeTypes: ['video/*'],
  uniformTypeIdentifiers: ['public.movie'],
);

/// Диалог выбора видео; `null` — человек передумал.
Future<String?> pickVideoFile() async {
  final file = await openFile(acceptedTypeGroups: const [kVideoTypeGroup]);
  return file?.path;
}

/// Главный экран: перетащить видео или выбрать файл — и обработка
/// начнётся сама. Про язык и компоненты программы здесь нет ни слова:
/// человеку они не нужны.
///
/// Само перетаскивание ловит оболочка (`DropTarget` вокруг всех экранов,
/// выключенный, пока идёт работа); сюда приходит только [dragging] —
/// подсветить зону.
class HomeView extends StatelessWidget {
  final AppController controller;
  final bool dragging;
  final Future<String?> Function() pickVideo;

  const HomeView({
    super.key,
    required this.controller,
    this.dragging = false,
    this.pickVideo = pickVideoFile,
  });

  Future<void> _pick() async {
    final path = await pickVideo();
    if (path == null) return;
    // Не ждём: Future закончится только вместе с обработкой.
    unawaited(controller.openVideo(path));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          controller.isMobile ? _mobile(context) : _desktop(context),
    );
  }

  Widget _checking(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(children: [
          const SizedBox(width: 240, child: LinearProgressIndicator()),
          const SizedBox(height: 8),
          Text(AppStrings.homeChecking,
              style: Theme.of(context).textTheme.bodyMedium),
        ]),
      );

  Widget _desktop(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    final active = dragging && c.canOpenVideo;
    final border = active ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: double.infinity,
            decoration: BoxDecoration(
              color: active
                  ? theme.colorScheme.primary.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: border, width: active ? 3 : 1.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.video_file_outlined,
                      size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(AppStrings.homeDrop,
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(AppStrings.homeOr, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: c.canOpenVideo ? () => unawaited(_pick()) : null,
                    icon: const Icon(Icons.folder_open),
                    label: const Text(AppStrings.homePick),
                  ),
                  if (c.isBusy) _checking(context),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(AppStrings.homeOutputHint,
            style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        Text(AppStrings.homeDropFallback,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center),
      ]),
    );
  }

  /// Android: перетаскивать некуда — одна большая кнопка.
  Widget _mobile(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.video_library_outlined,
              size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(AppStrings.homeMobileIntro,
              style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size(220, 56),
                textStyle: theme.textTheme.titleMedium),
            onPressed: c.canOpenVideo ? () => unawaited(_pick()) : null,
            icon: const Icon(Icons.video_library),
            label: const Text(AppStrings.homePickMobile),
          ),
          if (c.isBusy) _checking(context),
        ]),
      ),
    );
  }
}
