import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/pipeline/language_detector.dart';

/// Все тексты ниже — настоящие ответы SpeechKit из ручного прогона
/// 2026-09-02: одни и те же куски звука, распознанные обеими моделями.
/// Ролики были турецкие, так что правильный ответ везде tr-TR.
void main() {
  group('Оценка отдельного варианта', () {
    test('Турецкий текст со «своими» буквами получает высокую оценку', () {
      const text = 'en güçlü dolu bu niye çok sulu *** deme '
          'makine ***';
      expect(scoreLanguage(text, 'tr-TR'), greaterThan(0.5));
    });

    test('Зацикленный повтор штрафуется', () {
      const looped = '*** *** *** *** ***';
      const plain = '*** bir iki uch tort besh olti yetti';
      expect(scoreLanguage(looped, 'uz-UZ'),
          lessThan(scoreLanguage(plain, 'uz-UZ')));
    });

    test('Пустой текст — заведомо худший вариант', () {
      expect(scoreLanguage('', 'tr-TR'), lessThan(0));
      expect(scoreLanguage('   ', 'uz-UZ'), lessThan(0));
    });

    test('Чужие буквы работают против варианта', () {
      // Узбекские признаки в тексте, размеченном как турецкий.
      const uzbekish = 'qishloq xoʻjaligi sholi choy';
      expect(scoreLanguage(uzbekish, 'uz-UZ'),
          greaterThan(scoreLanguage(uzbekish, 'tr-TR')));
    });
  });

  group('Сравнение двух моделей на реальных ответах', () {
    test('Длинная реплика: турецкий уверенно выигрывает', () {
      final verdict = judgeLanguage({
        'tr-TR': '*** *** gün *** böyle abi *** olsun '
            '*** *** 24 ***',
        'uz-UZ': 'eyabakca sivas ta 1 sonu bu ele abi *** olsun hymatiz '
            'nazarda salibatte saatte *** *** *** '
            '*** *** ***',
      });
      expect(verdict.best.lang, 'tr-TR');
      expect(verdict.confident, isTrue);
    });

    test('Вторая длинная реплика: тоже турецкий', () {
      final verdict = judgeLanguage({
        'tr-TR': 'en güçlü dolu bu niye çok sulu *** deme '
            'makine ***',
        'uz-UZ': 'u niye u niye topsunu gurnuyu deme makina durgunda',
      });
      expect(verdict.best.lang, 'tr-TR');
      expect(verdict.confident, isTrue);
    });

    test('Короткая реплика без опознавательных букв — решает человек', () {
      final verdict = judgeLanguage({
        'tr-TR': 'tam 12 saat var *** ***',
        'uz-UZ': 'tam oniki saat vampirsini',
      });
      expect(verdict.confident, isFalse,
          reason: 'данных мало, угадывать за человека нельзя');
      expect(verdict.candidates.length, 2,
          reason: 'оба варианта показываются равноправно');
    });

    test('Если распозналась только одна модель, она и выигрывает', () {
      final verdict = judgeLanguage({
        'tr-TR': '*** çalışma *** için',
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
