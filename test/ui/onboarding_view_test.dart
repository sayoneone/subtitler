import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/app/app_controller.dart';
import 'package:subtitler/app/key_check.dart';
import 'package:subtitler/core/cloud/api_errors.dart';

import '../support/fakes.dart';
import 'support.dart';

/// Выдуманный ключ, который человек «вставляет» в поле.
const _typedKey = 'AQVN-vydumannyj-klyuch-onbordinga-0003';

Finder get _keyField => find.byKey(const ValueKey('key-field'));

Future<void> _submit(WidgetTester tester, String key) async {
  await tester.enterText(_keyField, key);
  await tester.tap(find.text('Проверить и сохранить'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('без ключа — что за ключ, какие роли, поле скрыто',
      (tester) async {
    final h = await started(storedKey: null);
    expect(h.controller.stage, AppStage.needsKey);
    await pumpApp(tester, h.controller);

    expect(find.text('Ключ Яндекс Облака'), findsOneWidget);
    expect(find.textContaining('API-ключ сервисного аккаунта'), findsOneWidget);
    expect(find.textContaining('ai.speechkit-stt.user — распознавание речи'),
        findsOneWidget);
    expect(find.textContaining('ai.translate.user — перевод'), findsOneWidget);
    expect(find.text('Проверить и сохранить'), findsOneWidget);
    expect(tester.widget<TextField>(_keyField).obscureText, isTrue);
    // Отмены нет: возвращаться некуда.
    expect(find.text('Отмена'), findsNothing);
    // Плашки о хранилище нет, пока оно работает.
    expect(find.textContaining('Хранилище ключа недоступно'), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('до проверки под кнопкой нет ничего похожего на переключатели',
      (tester) async {
    // Два пустых серых кружка «Перевод» и «Распознавание» без заголовка
    // выглядели как выбор «одно из двух»: человек щёлкал по ним, и ничего
    // не происходило.
    final h = await started(storedKey: null);
    await pumpApp(tester, h.controller);

    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(find.bySubtype<Radio<Object?>>(), findsNothing);
    expect(find.text('Перевод'), findsNothing);
    expect(find.text('Распознавание'), findsNothing);

    // С началом проверки — индикаторы под заголовком.
    h.controller.debugEmulate(
        keyCheck: const KeyCheckResult(
            translate: CheckState.checking, stt: CheckState.checking));
    await tester.pump();
    expect(find.text('Проверка ключа'), findsOneWidget);
    expect(find.text('Перевод'), findsOneWidget);
    expect(find.text('Распознавание'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('обе проверки прошли — обе галочки зелёные', (tester) async {
    final h = await started(storedKey: null);
    await pumpApp(tester, h.controller);

    h.controller.debugEmulate(
        keyCheck: const KeyCheckResult(
            translate: CheckState.ok, stt: CheckState.ok));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.cancel), findsNothing);

    await closeApp(tester, h);
  });

  testWidgets('нет роли распознавания — перевод зелёный, распознавание '
      'красное, названа недостающая роль', (tester) async {
    final h = await started(storedKey: null);
    h.stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = const AuthException(
          statusCode: 403, message: 'У ключа нет роли ai.speechkit-stt.user');
    await pumpApp(tester, h.controller);

    await _submit(tester, _typedKey);

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
    expect(find.text('У ключа нет роли ai.speechkit-stt.user'), findsOneWidget);
    expect(
        find.text('Добавьте эту роль сервисному аккаунту в консоли Яндекс '
            'Облака и повторите.'),
        findsOneWidget);
    expect(h.controller.stage, AppStage.needsKey);
    expect(h.controller.hasKey, isFalse, reason: 'неверный ключ не хранится');
    expect(h.keyStore.value, isNull);
    for (final text in visibleTexts(tester)) {
      expect(text, isNot(contains(_typedKey)));
    }

    await closeApp(tester, h);
  });

  testWidgets('нет роли перевода — названа роль перевода', (tester) async {
    final h = await started(storedKey: null);
    h.translate = FakeTranslate()
      ..failWith = const AuthException(
          statusCode: 403, message: 'У ключа нет роли ai.translate.user');
    await pumpApp(tester, h.controller);

    await _submit(tester, _typedKey);

    expect(find.text('У ключа нет роли ai.translate.user'), findsOneWidget);
    expect(find.text('У ключа нет роли ai.speechkit-stt.user'), findsNothing);
    expect(find.byIcon(Icons.cancel), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('отозванный ключ — одно сообщение на обе проверки',
      (tester) async {
    final h = await started(storedKey: null);
    const revoked =
        AuthException(statusCode: 401, message: 'Ключ неверный или отозван');
    h.translate = FakeTranslate()..failWith = revoked;
    h.stt = FakeStt(const [])
      ..failCalls = 1
      ..failWith = revoked;
    await pumpApp(tester, h.controller);

    await _submit(tester, _typedKey);

    expect(find.byIcon(Icons.cancel), findsNWidgets(2));
    expect(find.text('Ключ неверный или отозван'), findsOneWidget);

    // Сырой текст — только в «Технических деталях», и без ключа.
    expect(find.textContaining('ApiException'), findsNothing);
    await tester.tap(find.text('Технические детали'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ApiException(401)'), findsOneWidget);
    for (final text in visibleTexts(tester)) {
      expect(text, isNot(contains(_typedKey)));
    }

    await closeApp(tester, h);
  });

  testWidgets('ключ принят — главный экран, ключ сохранён', (tester) async {
    final h = await started(storedKey: null);
    await pumpApp(tester, h.controller);

    await _submit(tester, _typedKey);
    await tester.pump();

    expect(h.controller.stage, AppStage.home);
    expect(h.keyStore.value, _typedKey);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('хранилище ключа недоступно — честная плашка', (tester) async {
    final h = await started(storedKey: null, keyStorageWorks: false);
    await pumpApp(tester, h.controller);

    expect(find.textContaining('Хранилище ключа недоступно'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('смена ключа из настроек — можно передумать', (tester) async {
    final h = await started();
    await pumpApp(tester, h.controller);
    h.controller.changeKey();
    await tester.pump();

    expect(find.text('Проверить и сохранить'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    expect(h.controller.stage, AppStage.home);
    expect(h.controller.hasKey, isTrue);
    expect(find.text('Перетащите видео сюда'), findsOneWidget);

    await closeApp(tester, h);
  });

  testWidgets('«Как создать ключ» — инструкция прямо в окне', (tester) async {
    final h = await started(storedKey: null);
    await pumpApp(tester, h.controller);

    expect(find.textContaining('Создать API-ключ'), findsNothing);
    await tester.tap(find.text('Как создать ключ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Создать API-ключ'), findsOneWidget);

    await closeApp(tester, h);
  });
}
