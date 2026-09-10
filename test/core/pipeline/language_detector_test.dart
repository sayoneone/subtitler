import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/pipeline/language_detector.dart';

/// Тексты ниже вымышленные, но подобраны так, чтобы воспроизводить то, что
/// различает определитель: у «своей» модели в тексте есть буквы её алфавита,
/// а «чужая» выдаёт фонетическую кальку без них и часто зацикливается,
/// повторяя одно слово подряд.
void main() {
  group('Оценка отдельного варианта', () {
    test('Турецкий текст со «своими» буквами получает высокую оценку', () {
      const text = 'makine *** su yüzeye çıkıyor öyle *** şoför';
      expect(scoreLanguage(text, 'tr-TR'), greaterThan(0.5));
    });

    test('Зацикленный повтор штрафуется', () {
      const looped = 'beramiz beramiz beramiz beramiz beramiz';
      const plain = 'beramiz bir ikki uch tort besh olti';
      expect(scoreLanguage(looped, 'uz-UZ'),
          lessThan(scoreLanguage(plain, 'uz-UZ')));
    });

    test('Пустой текст — заведомо худший вариант', () {
      expect(scoreLanguage('', 'tr-TR'), lessThan(0));
      expect(scoreLanguage('   ', 'uz-UZ'), lessThan(0));
    });

    test('Чужие буквы работают против варианта', () {
      const uzbekish = 'qishloq xoʻjaligi sholi choy';
      expect(scoreLanguage(uzbekish, 'uz-UZ'),
          greaterThan(scoreLanguage(uzbekish, 'tr-TR')));
    });
  });

  group('Сравнение двух моделей на одном и том же звуке', () {
    test('Длинная реплика: турецкий уверенно выигрывает', () {
      final verdict = judgeLanguage({
        'tr-TR': 'yarın sabah çıkacağız ağabey işler bitince '
            'haber ederiz şoföre söyle',
        // Калька без узбекских признаков, да ещё и с зацикливанием.
        'uz-UZ': 'yarin sabah chikamiz agabey ishlar bitgach '
            'beramiz beramiz beramiz beramiz beramiz',
      });
      expect(verdict.best.lang, 'tr-TR');
      expect(verdict.confident, isTrue);
    });

    test('Вторая длинная реплика: тоже турецкий', () {
      final verdict = judgeLanguage({
        'tr-TR': 'makine *** su yüzeye çıkıyor öyle ***',
        'uz-UZ': 'makina durganda su yuzeye tikiyor oyle '
            'gorunuyor gorunuyor gorunuyor gorunuyor',
      });
      expect(verdict.best.lang, 'tr-TR');
      expect(verdict.confident, isTrue);
    });

    test('Короткая реплика без опознавательных букв — решает человек', () {
      final verdict = judgeLanguage({
        'tr-TR': 'tam on iki saat var',
        'uz-UZ': 'tam onikki soat bor',
      });
      expect(verdict.confident, isFalse,
          reason: 'данных мало, угадывать за человека нельзя');
      expect(verdict.candidates.length, 2,
          reason: 'оба варианта показываются равноправно');
    });

    test('Если распозналась только одна модель, она и выигрывает', () {
      final verdict = judgeLanguage({
        'tr-TR': 'akşam vardiyası başladı',
        'uz-UZ': '',
      });
      expect(verdict.best.lang, 'tr-TR');
      expect(verdict.confident, isTrue);
    });

    test('Обе модели молчат — уверенности нет', () {
      final verdict = judgeLanguage({'tr-TR': '', 'uz-UZ': ''});
      expect(verdict.confident, isFalse);
    });

    test('Настоящий узбекский текст выигрывает у турецкой кальки', () {
      final verdict = judgeLanguage({
        'uz-UZ': 'bugun qishloqda ishlar yaxshi ketyapti shuning uchun '
            'choyxonaga boramiz',
        'tr-TR': 'bugun kislokda islar yahsi ketyapti sunung ucun '
            'coyhanaya boramiz',
      });
      expect(verdict.best.lang, 'uz-UZ');
      expect(verdict.confident, isTrue);
    });
  });
}
