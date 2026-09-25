import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/languages.dart';
import 'package:subtitler/core/pipeline/lexicon.dart';

void main() {
  group('Разбиение на слова', () {
    test('Все разновидности апострофа — одна буква', () {
      final variants = ['oʻzim', 'o‘zim', 'o’zim', 'oʼzim', "o'zim", 'o`zim'];
      final tokens = variants.map((v) => tokenize(v).single).toSet();
      expect(tokens, {'oʻzim'});
    });

    test('Цифры и знаки — разделители, а не слова', () {
      expect(tokenize('Saat 12de, çarşıda!'), ['saat', 'de', 'çarşıda']);
    });

    test('Точка над İ не разрывает слово', () {
      // Dart переводит İ в i + U+0307; без очистки «İşte» распалось бы.
      expect(tokenize('İşte BURADA'), ['işte', 'burada']);
    });

    test('Разложенные буквы собираются обратно', () {
      expect(tokenize('çay'), ['çay']);
    });

    test('Апостроф по краям слова отбрасывается', () {
      expect(tokenize("'bozor'"), ['bozor']);
    });
  });

  group('Ключ словаря', () {
    test('Турецкая i/ı при поиске — одна буква', () {
      // 'IŞIK'.toLowerCase() в Dart даёт 'işik', а не 'ışık'.
      expect(lexKey(tokenize('IŞIK').single, 'tr-TR'),
          lexKey('ışık', 'tr-TR'));
    });

    test('Новый узбекский алфавит читается как действующий', () {
      expect(lexKey('şuning', 'uz-UZ'), 'shuning');
      expect(lexKey('çunki', 'uz-UZ'), 'chunki');
      expect(lexKey('öz', 'uz-UZ'), 'oʻz');
      expect(lexKey('bağ', 'uz-UZ'), 'bagʻ');
    });

    test('В русском и казахском ё = е', () {
      expect(lexKey('всё', 'ru-RU'), 'все');
      expect(lexKey('всё', 'kk-KZ'), 'все');
    });
  });

  group('Скелет слова', () {
    test('Узнаёт турецкое слово в узбекской записи и наоборот', () {
      expect(skeleton('ishte'), skeleton('işte'));
      expect(skeleton('qishloq'), skeleton('kışlok'));
      expect(skeleton('choyxona'), skeleton('çoyhona'));
      expect(skeleton('oʻzim'), skeleton('özim'));
    });

    test('Узнаёт казахское слово в русской записи', () {
      expect(skeleton('жоқ'), skeleton('жок'));
      expect(skeleton('қайда'), skeleton('кайда'));
      expect(skeleton('үйде'), skeleton('уйде'));
    });
  });

  group('Словари', () {
    test('Турецкий и узбекский — по 150–300 слов и примерно поровну', () {
      final tr = lexiconFor('tr-TR')!.words.length;
      final uz = lexiconFor('uz-UZ')!.words.length;
      for (final size in [tr, uz]) {
        expect(size, inInclusiveRange(150, 300));
      }
      // Язык с бо́льшим словарём получал бы завышенную долю «своих» слов.
      expect((tr - uz).abs() / tr, lessThan(0.15));
    });

    test('Русский и казахский тоже есть — на случай, если их включат', () {
      expect(lexiconFor('ru-RU')!.words.length, greaterThanOrEqualTo(100));
      expect(lexiconFor('kk-KZ')!.words.length, greaterThanOrEqualTo(100));
    });

    test('Словарь есть для каждого языка автоопределения по умолчанию', () {
      for (final code in kDefaultDetectionCandidates) {
        expect(lexiconFor(code), isNotNull, reason: code);
      }
    });

    test('Характерные окончания узнаются и в чужой орфографии', () {
      final tr = lexiconFor('tr-TR')!;
      final uz = lexiconFor('uz-UZ')!;
      expect(tr.hasSuffix(skeleton('gidiyorum')), isTrue);
      expect(tr.hasSuffix(skeleton('chiqiyorum')), isTrue,
          reason: 'узбекская модель записала турецкое -iyor своими буквами');
      expect(tr.hasSuffix(skeleton('gideceğiz')), isTrue);
      expect(uz.hasSuffix(skeleton('kelyapti')), isTrue);
      expect(uz.hasSuffix(skeleton('borib')), isTrue);
      expect(uz.hasSuffix(skeleton('qishloqning')), isTrue);
    });

    test('Обиходные турецкие формы не выдаются за узбекские окончания', () {
      final uz = lexiconFor('uz-UZ')!;
      // «yaptı» — турецкое «сделал», а не узбекское -yapti.
      expect(uz.hasSuffix(skeleton('yaptı')), isFalse);
      // Турецкое прошедшее время на -adı/-edi не узбекское -adi.
      expect(uz.hasSuffix(skeleton('başladı')), isFalse);
      expect(uz.hasSuffix(skeleton('parasız')), isFalse);
    });

    test('Казахские окончания не срабатывают на обычных русских словах', () {
      final kk = lexiconFor('kk-KZ')!;
      for (final word in ['один', 'книга', 'машинка', 'доллар']) {
        expect(kk.hasSuffix(skeleton(word)), isFalse, reason: word);
      }
    });
  });
}
