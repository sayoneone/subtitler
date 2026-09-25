import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/user_error.dart';
import 'package:subtitler/app/video_probe.dart';
import 'package:subtitler/core/cloud/api_errors.dart';

import '../support/app_harness.dart';
import 'support.dart';

const _video = '/видео/дело 9/звонок.mp4';

void main() {
  testWidgets('нет сети: человеческий текст виден, сырой — только в '
      '«Технических деталях»', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(
        const TransientException(
            message: 'SocketException: Failed host lookup: '
                'stt.api.cloud.yandex.net'),
        mask: h.log.mask,
      ),
    );
    await tester.pump();

    expect(find.text('звонок.mp4'), findsOneWidget);
    expect(find.text('Нет доступа к интернету'), findsOneWidget);
    expect(find.textContaining('Обработка возможна только онлайн'),
        findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('На главный экран'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);

    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SocketException: Failed host lookup'),
        findsOneWidget);
    // И последние записи журнала — с ними разработчику есть что читать.
    expect(find.textContaining('Запуск приложения'), findsOneWidget);
    expect(find.text('Скопировать'), findsOneWidget);
    expect(find.text('Сохранить журнал'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('ключ отозван — «Изменить ключ» ведёт на экран ключа',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(
        const AuthException(
            statusCode: 401, message: 'Ключ неверный или отозван'),
        mask: h.log.mask,
      ),
    );
    await tester.pump();

    expect(find.text('Ключ неверный или отозван'), findsOneWidget);
    await tester.tap(find.text('Изменить ключ'));
    await tester.pump();
    expect(h.controller.stage, AppStage.needsKey);
    expect(find.text('Проверить и сохранить'), findsOneWidget);
    expect(find.text('Отмена'), findsOneWidget,
        reason: 'передумал — назад к ошибке');

    await closeApp(tester, h);
  });

  testWidgets('в технических деталях ключ замаскирован', (tester) async {
    final h = await started(); // ключ загружен — журнал его уже прячет
    await pumpApp(tester, h.controller);
    h.log.warn('Запрос с ключом $kTestApiKey не прошёл');
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(
          StateError('ffmpeg упал; Api-Key $kTestApiKey'),
          mask: h.log.mask),
    );
    await tester.pump();

    expect(find.text('Не удалось обработать видео'), findsOneWidget);
    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('***КЛЮЧ***'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text, isNot(contains(kTestApiKey)));
    }

    await closeApp(tester, h);
  });

  testWidgets('«Сохранить журнал» — файл с журналом без ключа, показан в '
      'Проводнике', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.log.warn('Запрос с ключом $kTestApiKey не прошёл');
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(StateError('Выдуманный сбой ffmpeg: код 1'),
          mask: h.log.mask),
    );
    await tester.pump();

    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить журнал'));
    // Запись файла — настоящий ввод-вывод: ему нужно настоящее время.
    for (var i = 0; i < 50 && h.revealed.isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
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
    // Скрыты только папки с видео: пути профиля в журнале остаются, и
    // обещать «нет названий папок» вообще было бы неправдой.
    expect(
        find.textContaining(
            'В нём нет текста записей и названий папок с видео.'),
        findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«Скопировать» отдаёт сырой текст в буфер обмена',
      (tester) async {
    final h = await started();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(StateError('Выдуманный сбой ffmpeg: код 1'),
          mask: h.log.mask),
    );
    await tester.pump();

    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скопировать'));
    await tester.pump();
    expect(copied, contains('Выдуманный сбой ffmpeg: код 1'));

    await closeApp(tester, h);
  });

  testWidgets('с этим файлом делать нечего — только «На главный экран»',
      (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.debugEmulate(
      stage: AppStage.failed,
      videoPath: _video,
      error: describeError(
          const NotAVideoException(_video, 'нет видеодорожки'),
          mask: h.log.mask),
    );
    await tester.pump();

    expect(find.text('Это не видео или файл повреждён'), findsOneWidget);
    expect(find.text('Повторить'), findsNothing);
    expect(find.text('На главный экран'), findsOneWidget);
    await tester.tap(find.text('На главный экран'));
    await tester.pump();
    await tester.pump();
    expect(h.controller.stage, AppStage.home);

    await closeApp(tester, h);
  });

  testWidgets('нет ffmpeg — сообщение, пути поиска только в деталях',
      (tester) async {
    final h = await started(noFfmpeg: true);
    expect(h.controller.stage, AppStage.broken);
    await pumpApp(tester, h.controller);

    expect(find.text('Не найден компонент обработки видео'), findsOneWidget);
    expect(find.textContaining('Распакуйте архив заново целиком'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Сохранить журнал'),
        findsOneWidget);
    expect(find.textContaining('Где искали'), findsNothing);
    expect(find.textContaining('ffmpeg.exe'), findsNothing);

    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Где искали'), findsOneWidget);
    expect(find.textContaining('ffmpeg.exe'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('папки программы не создались — своё сообщение',
      (tester) async {
    final h = await started(
        runtimeError: const _PrepareFailure('Нет доступа к профилю'));
    expect(h.controller.stage, AppStage.broken);
    await pumpApp(tester, h.controller);

    expect(find.text('Не удалось подготовить папки программы'),
        findsOneWidget);
    expect(find.textContaining('Нет доступа к профилю'), findsNothing);
    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Нет доступа к профилю'), findsOneWidget);

    await closeApp(tester, h);
  });
}

/// Любое исключение подготовки папок.
class _PrepareFailure implements Exception {
  final String message;
  const _PrepareFailure(this.message);

  @override
  String toString() => message;
}
