import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitler/ui/help/guide.dart';
import 'package:subtitler/ui/strings.dart';

void main() {
  group('Разметка руководства', () {
    test('заголовки, абзацы, пункты, картинки и врезки', () {
      final blocks = parseGuide('''
# Руководство

Первая строка
вторая строка.

> Важно:
> два предложения.

## 1. Раздел

1. Откройте [сайт](https://example.org) и нажмите
   «Войти».

![Подпись к картинке](shot.png)

2. **Жирный** и `код`.
- пункт без номера
''');
      expect(blocks, hasLength(8));
      expect((blocks[0] as GuideHeading).level, 1);
      expect((blocks[0] as GuideHeading).text, 'Руководство');
      expect((blocks[1] as GuideParagraph).spans,
          [const GuideSpan('Первая строка вторая строка.')]);
      expect((blocks[2] as GuideNote).spans,
          [const GuideSpan('Важно: два предложения.')]);
      expect((blocks[3] as GuideHeading).level, 2);
      final first = blocks[4] as GuideItem;
      expect(first.number, 1);
      expect(first.spans, [
        const GuideSpan('Откройте '),
        const GuideSpan('сайт', link: 'https://example.org'),
        const GuideSpan(' и нажмите «Войти».'),
      ], reason: 'продолжение пункта с отступом — тот же пункт');
      final image = blocks[5] as GuideImage;
      expect(image.file, 'shot.png');
      expect(image.asset, 'assets/help/shot.png');
      expect(image.caption, 'Подпись к картинке');
      final second = blocks[6] as GuideItem;
      expect(second.number, 2, reason: 'номер после картинки — как написан');
      expect(second.spans, [
        const GuideSpan('Жирный', bold: true),
        const GuideSpan(' и '),
        const GuideSpan('код', code: true),
        const GuideSpan('.'),
      ]);
      expect((blocks[7] as GuideItem).number, isNull);
    });

    test('пункт без номера и строка без отступа после пункта', () {
      final blocks = parseGuide('- первый\nновый абзац\n');
      expect(blocks, hasLength(2));
      expect((blocks[0] as GuideItem).number, isNull);
      expect(blocks[1], isA<GuideParagraph>());
    });

    test('экраны: обложка и по экрану на шаг, раздел подписывает шаги', () {
      final pages = guidePages(parseGuide('''
# Руководство

![Обложка](cover.png)

Вступление.

> Сноска обложки.

## Раздел

### Первый шаг

![Первая](one.png)

Текст шага.

> Сноска шага.

### Второй шаг

![Вторая](two.png)

Текст.

![Лишняя](three.png)
'''));
      expect(pages, hasLength(3));
      expect(pages[0].chapter, isNull);
      expect(pages[0].title, 'Руководство');
      expect(pages[0].image!.file, 'cover.png');
      expect(pages[0].notes.single.spans, [const GuideSpan('Сноска обложки.')]);
      expect(pages[1].chapter, 'Раздел');
      expect(pages[1].title, 'Первый шаг');
      expect((pages[1].body.single as GuideParagraph).spans,
          [const GuideSpan('Текст шага.')]);
      expect(pages[2].image!.file, 'two.png');
      expect(pages[2].body.last, isA<GuideImage>(),
          reason: 'вторая картинка шага — в тексте, а не вместо первой');
    });

    test('переводы строк Windows не мешают', () {
      final blocks = parseGuide('## Раздел\r\n\r\nТекст\r\n');
      expect((blocks[0] as GuideHeading).text, 'Раздел');
      expect((blocks[1] as GuideParagraph).spans, [const GuideSpan('Текст')]);
    });
  });

  // Руководство — отдельный файл, и правка программы легко оставила бы в
  // нём старые названия кнопок и потерянные картинки.
  group('assets/help/guide.md', () {
    final source = File(kGuideAsset).readAsStringSync();
    final blocks = parseGuide(source);
    // Названия переносятся по строкам — сравниваем без переносов.
    final flat = source.replaceAll(RegExp(r'\s+'), ' ');

    test('заголовок — тот же, что у окна руководства', () {
      expect(blocks.first, isA<GuideHeading>());
      expect((blocks.first as GuideHeading).text, AppStrings.helpTitle);
    });

    test('картинки на месте, лишних файлов нет', () {
      final referenced = {
        for (final b in blocks)
          if (b is GuideImage) b.file,
      };
      for (final file in referenced) {
        expect(File(p.join(kGuideDir, file)).existsSync(), isTrue,
            reason: 'нет картинки $file');
      }
      final present = {
        for (final f in Directory(kGuideDir).listSync())
          if (f is File && p.basename(f.path) != 'guide.md')
            p.basename(f.path),
      };
      expect(present, referenced,
          reason: 'картинка, на которую нет ссылки, только утяжеляет архив');
      for (final b in blocks.whereType<GuideImage>()) {
        expect(b.caption, isNotEmpty, reason: '${b.file} без подписи');
      }
    });

    // Как «Советы» macOS: на каждом экране снимок, заголовок и текст.
    test('каждый шаг — снимок, заголовок и текст', () {
      final pages = guidePages(blocks);
      expect(pages.length, greaterThan(10));
      expect(pages.first.chapter, isNull, reason: 'первый экран — обложка');
      for (final page in pages) {
        expect(page.image, isNotNull, reason: '«${page.title}» без снимка');
        expect(page.body, isNotEmpty, reason: '«${page.title}» без текста');
        expect(page.body.whereType<GuideImage>(), isEmpty,
            reason: '«${page.title}»: у шага один снимок');
      }
      expect(pages.map((p) => p.chapter).toSet(), {
        null,
        'Ключ Яндекс Облака',
        'Первый запуск',
        'Субтитры для видео',
        'Если что-то пошло не так',
      });
    });

    // Каждое название — и в руководстве, и в самой программе.
    test('кнопки и надписи названы так же, как в программе', () {
      final lib = [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart')) f.readAsStringSync(),
      ].join('\n');
      for (final name in [
        AppStrings.help,
        AppStrings.settings,
        AppStrings.keyReplace,
        AppStrings.keyField,
        AppStrings.keySubmit,
        AppStrings.keyCheckTranslate,
        AppStrings.keyCheckStt,
        AppStrings.homePick,
        AppStrings.homePickMobile,
        AppStrings.cancel,
        AppStrings.menuLog,
        AppStrings.logSaveToFile,
        'Не тот язык?',
        'Сохранить видео с субтитрами',
        'Открыть папку',
        'Посмотреть результат',
        'Поделиться',
      ]) {
        expect(flat, contains('«$name»'), reason: 'руководство: $name');
        expect(lib, contains("'$name'"), reason: 'программа: $name');
      }
    });
  });
}
