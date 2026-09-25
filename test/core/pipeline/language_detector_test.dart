import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/pipeline/language_detector.dart';

/// Все тексты ниже вымышленные. «Вывод чужой модели» сочинён по образцу
/// того, что она делает на самом деле: пишет своими буквами фонетическую
/// кальку, в которой узнаются слова соседнего языка, и часто зацикливается.

/// Пробы по репликам: язык → список текстов, реплики нумеруются с 1.
Map<String, Map<int, String>> byCue(Map<String, List<String>> texts) => {
      for (final entry in texts.entries)
        entry.key: {
          for (var i = 0; i < entry.value.length; i++) i + 1: entry.value[i],
        },
    };

void main() {
  group('Признаки по отдельности', () {
    test('Свои слова: доля слов из словаря языка', () {
      final f = languageFeatures('ertaga ertalab bozorga boramiz', 'uz-UZ');
      // ertaga, ertalab, boramiz — в словаре; bozorga — нет.
      expect(f.own, closeTo(0.75, 1e-9));
      expect(f.words, 4);
    });

    test('Короткие слова весят меньше длинных', () {
      final f = languageFeatures('ve kalemler', 'tr-TR');
      // «ve» в словаре, но весит 0.4 против 1.0 у длинного слова.
      expect(f.own, closeTo(0.4 / 1.4, 1e-9));
    });

    test('Своё окончание засчитывается слову вне словаря', () {
      final f = languageFeatures('gidiyorum', 'tr-TR');
      expect(f.own, 0);
      expect(f.ownSuffix, 1);
    });

    test('Чужие слова узнаются по скелету', () {
      // Узбекская модель записала турецкие «yarın» и «sabah» своими буквами.
      final f = languageFeatures('yarin sabah', 'uz-UZ', against: ['tr-TR']);
      expect(f.foreign, 1);
      expect(f.own, 0);
    });

    test('Общие слова соседних языков нейтральны', () {
      // «bir», «bu», «biz» есть в обоих словарях — ничьими они не считаются.
      final f = languageFeatures('bir bu biz', 'uz-UZ', against: ['tr-TR']);
      expect(f.foreign, 0);
      expect(f.own, 1);
    });

    test('Слово своего языка не считается чужим, даже если оно есть у соседа',
        () {
      // Каждое из этих слов — обычное слово и узбекского, и турецкого:
      // ya'ni/yani «то есть», qarshi/karşı «против», ona «мать» / «ему»,
      // qara «смотри» / kara «чёрный», oy «месяц» / «голос на выборах»,
      // qani «где?» / kanı «его кровь; мнение», yetti «семь» / «хватило»…
      // Модель, которая написала его своими буквами, ничего чужого не
      // услышала.
      const uzbek = [
        "ya'ni", 'biri', 'beri', 'qarshi', 'yedi', 'ki', 'ona', 'sana', //
        'bari', 'kimi', "yo'qsa", 'da', 'qani', 'yetti',
      ];
      const turkish = [
        'ana', 'kara', 'ha', 'yo', 'halı', 'şart', 'sarı', 'oy', 'öz', 'yana',
        'kanı', 'yetti',
      ];
      for (final word in uzbek) {
        expect(languageFeatures(word, 'uz-UZ', against: ['tr-TR']).foreign, 0,
            reason: word);
      }
      for (final word in turkish) {
        expect(languageFeatures(word, 'tr-TR', against: ['uz-UZ']).foreign, 0,
            reason: word);
      }
    });

    test('Вводное «значит» — своё слово у обеих моделей', () {
      // Узбекское demak и турецкое demek звучат в речи постоянно. Будь
      // одно из них только окончанием -mak/-mek, калька у соседа получала бы
      // больше, чем слово у своей модели.
      expect(languageFeatures('demak', 'uz-UZ', against: ['tr-TR']).own, 1);
      expect(languageFeatures('demek', 'tr-TR', against: ['uz-UZ']).own, 1);
    });

    test('Слово, редкое у соседа, остаётся признаком своего языка', () {
      // Узбекское sal «немного» — обычное наречие, а турецкое sal «отпусти»
      // (и «плот») редкое: вместо него говорят bırak. Решение записано в
      // lexicon.dart, тест не даёт тихо сделать sal общим словом.
      expect(languageFeatures('sal', 'uz-UZ', against: ['tr-TR']).own, 1);
      expect(languageFeatures('sal', 'tr-TR', against: ['uz-UZ']).foreign, 1);
    });

    test('Чужое окончание работает против варианта', () {
      final f = languageFeatures('chiqiyorum', 'uz-UZ', against: ['tr-TR']);
      expect(f.foreignSuffix, 1);
      expect(f.score, lessThan(languageFeatures('chiqiyorum', 'uz-UZ').score));
    });

    test('Обычные узбекские слова не выдаются за турецкие окончания', () {
      // Вопрос на -misiz, слова на -mish и -ajak, shuncha/buncha, kechagi
      // по скелету похожи на турецкие -mışız, -mış, -acak, -ınca;
      // ko'pincha, tushuncha и chiqquncha — на -ınca, demak, yemak, ichmak
      // и ermak — на -mak, ziyorat — на -iyor.
      const words = [
        'yaxshimisiz', 'tinchmisiz', 'bormisiz', 'tayyormisiz', 'turmush', //
        "o'tmish", 'kumush', 'qilmish', 'kelajak', 'kelajakda', "bo'lajak",
        'kechagi', 'shuncha', 'buncha', "ko'mak", 'ixtiyori',
        "ko'pincha", 'tushuncha', 'chiqquncha', 'tikkuncha', 'demak', 'yemak',
        'ichmak', 'ermak', 'ziyorat', 'kelajagimiz', 'turmushim',
        "o'tmishim",
      ];
      for (final word in words) {
        final f = languageFeatures(word, 'uz-UZ', against: ['tr-TR']);
        expect(f.foreignSuffix, 0, reason: word);
        expect(f.foreign, 0, reason: word);
      }
    });

    test('Обычные турецкие слова не выдаются за узбекские окончания', () {
      // По скелету ğ = g, и sokağa совпадала с узбекским дательным -ga,
      // doğan — с причастием -gan, arka и şaka — с дательным -ka. -mışız
      // не должно совпасть с узбекским вопросом -misiz. kavga, dalga,
      // karga, morga оканчиваются как дательный -ga, kaygan, yorgan и
      // organ — как причастие -gan, aman, anlaman и yapmaman — как -aman
      // «я …-ю», kendimi и adımı — как вопрос -dimi.
      const words = [
        'sokağa', 'çocuğa', 'sağa', 'yatağa', 'ayağa', 'dağa', 'bardağa', //
        'dağı', 'doğan', 'soğan', 'arka', 'şaka', 'halka', 'fabrika', 'yaka',
        'kocaman', 'kahraman', 'gelmişiz',
        'kavga', 'dalga', 'karga', 'morga', 'kaygan', 'yorgan', 'yorganı',
        'yorganda', 'organ', 'organlar', 'aman', 'koskocaman', 'anlaman',
        'başlaman', 'toplaman', 'ağlaman', 'yapmaman', 'olmaman', 'kendimi',
        'adımı', 'derdimi',
      ];
      for (final word in words) {
        final f = languageFeatures(word, 'tr-TR', against: ['uz-UZ']);
        expect(f.foreignSuffix, 0, reason: word);
      }
    });

    test('Калька обычного слова соседа не получает очка за своё окончание',
        () {
      // aman, kavga, kendimi, organ — обычные турецкие слова. Узбекская
      // модель, записав их, слышала турецкую речь, а не узбекские -aman,
      // -ga, -dimi, -gan. Зеркально köpinçe, tuşunça, turmuş, kelacak —
      // турецкая калька узбекских ko'pincha, tushuncha, turmush, kelajak.
      const turkishHeardByUzbek = ['aman', 'kavga', 'kendimi', 'organ'];
      const uzbekHeardByTurkish = [
        'köpinçe', 'tuşunça', 'turmuş', 'ötmiş', 'kelacak', 'kömak', //
        'ihtiyor', 'ziyorat',
      ];
      for (final word in turkishHeardByUzbek) {
        final f = languageFeatures(word, 'uz-UZ', against: ['tr-TR']);
        expect(f.ownSuffix, 0, reason: word);
        expect(f.foreignSuffix, 0, reason: word);
      }
      for (final word in uzbekHeardByTurkish) {
        final f = languageFeatures(word, 'tr-TR', against: ['uz-UZ']);
        expect(f.ownSuffix, 0, reason: word);
        expect(f.foreignSuffix, 0, reason: word);
      }
    });

    test('Окончание соседа не отнимает очка у своих форм', () {
      // Узбекские turmush и kumush похожи окончанием на турецкое -mış, но
      // турецкие gelmiş, yapmışlar, görmüşler от этого не перестают быть
      // турецкими: очко снимает только калька целого слова.
      for (final word in ['gelmiş', 'yapmışlar', 'görmüşler']) {
        final f = languageFeatures(word, 'tr-TR', against: ['uz-UZ']);
        expect(f.ownSuffix, 1, reason: word);
      }
      // И наоборот: узбекские boraman и ishlaman — свои -aman, хотя
      // турецкие anlaman и yapmaman тоже оканчиваются на -man.
      for (final word in ['boraman', 'kelaman', 'ishlaman']) {
        final f = languageFeatures(word, 'uz-UZ', against: ['tr-TR']);
        expect(f.ownSuffix, 1, reason: word);
      }
    });

    test('Без соседей по письменности чужих слов не бывает', () {
      // Русская модель пишет кириллицей — латинская калька с ней несравнима.
      final f = languageFeatures('yarin sabah', 'uz-UZ', against: ['ru-RU']);
      expect(f.foreign, 0);
    });

    test('Зацикленный повтор штрафуется', () {
      const looped = 'beramiz beramiz beramiz beramiz beramiz';
      const plain = 'beramiz bir ikki uch besh olti';
      expect(scoreLanguage(looped, 'uz-UZ'),
          lessThan(scoreLanguage(plain, 'uz-UZ')));
      expect(languageFeatures(looped, 'uz-UZ').repeatLoop, isTrue);
    });

    test('Однообразный текст штрафуется и без подряд идущих повторов', () {
      const monotonous = 'bozor non bozor non bozor non';
      const varied = 'bozor non choy suv guruch piyoz';
      final a = languageFeatures(monotonous, 'uz-UZ');
      final b = languageFeatures(varied, 'uz-UZ');
      expect(a.repeatLoop, isFalse);
      expect(a.distinctRatio, lessThan(kMonotonyThreshold));
      expect(a.score, lessThan(b.score));
    });

    test('Пустой текст — заведомо худший вариант', () {
      expect(scoreLanguage('', 'tr-TR'), kSilentScore);
      expect(scoreLanguage('   ', 'uz-UZ'), lessThan(0));
    });

    test('Узбекский текст выше у узбекской модели, чем у турецкой', () {
      const uzbekish = 'qishloq xoʻjaligi haqida gaplashdik shuning uchun keldik';
      expect(scoreLanguage(uzbekish, 'uz-UZ', against: ['tr-TR']),
          greaterThan(scoreLanguage(uzbekish, 'tr-TR', against: ['uz-UZ'])));
    });

    test('Турецкий текст со своими словами и окончаниями оценивается высоко',
        () {
      const text = 'biz eve dönerken yağmur yağıyor ama şemsiye yok';
      expect(scoreLanguage(text, 'tr-TR'), greaterThan(0.5));
    });
  });

  group('Выбор языка', () {
    test('Турецкая речь, узбекская калька: турецкий, уверенно', () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'yarın sabah erkenden çarşıya gideceğiz çünkü evde ekmek yok',
          'akşam eve geç geleceğim sen beni bekleme tamam mı',
        ],
        'uz-UZ': [
          'yarin sabah erkandan charshiga gidajakmiz chunki evda ekmak yoq',
          'aqsham eve gech gelajagim sen beni beklama tamom mi',
        ],
      }));
      expect(verdict.lang, 'tr-TR');
      expect(verdict.confidence, LanguageConfidence.high);
      expect(verdict.runnerUp, 'uz-UZ');
      expect(verdict.comparedCues, [1, 2]);
    });

    test('Узбекская речь, турецкая калька: узбекский, уверенно', () {
      final verdict = judgeLanguage(byCue({
        'uz-UZ': [
          'bugun ertalab bozorga borib non va sabzi oldim',
          'akam kechqurun uyga kech keladi shuning uchun ovqatni kutmaymiz',
        ],
        'tr-TR': [
          'bugün ertalap bazarga barıp nan ve sabzi aldım',
          'akam keçkurun uyga keç keladi şunung uçun ofkatnı kutmaymız',
        ],
      }));
      expect(verdict.lang, 'uz-UZ');
      expect(verdict.confidence, LanguageConfidence.high);
      expect(verdict.runnerUp, 'tr-TR');
    });

    test('Узбекская речь со словами, общими с турецким: турецкий не выбирается',
        () {
      // Говорящий через слово вставляет «ya'ni», в речи — beri, biri, qarshi.
      // Турецкая модель пишет их как свои yani, beri, biri, karşı — и это
      // правда турецкие слова, но и узбекские тоже: перевешивать они не
      // должны.
      final verdict = judgeLanguage(byCue({
        'uz-UZ': [
          "ya'ni biz kecha bozorga bordik ya'ni u yerda qo'shnilardan biri "
              'bor edi',
          "o'shandan beri ya'ni u bizga qarshi ya'ni hech narsa demadi",
        ],
        'tr-TR': [
          'yani biz keçe bazarga bardık yani u yerde koşnilardan biri bar edi',
          'oşandan beri yani u bizge karşı yani hiç narsa demedi',
        ],
      }));
      expect(verdict.lang, 'uz-UZ', reason: verdict.describe());
    });

    test('Турецкая речь со словами, общими с узбекским: узбекский не выбирается',
        () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'ha tamam öz kardeşim yarın sarı halıyı ana yoldaki dükkana '
              'götürecek',
          'yo şart değil yıllardan bu yana oy vermeye kara arabayla gideriz',
        ],
        'uz-UZ': [
          "ha tamom o'z qardoshim yarin sari xaliyi ana yo'ldagi dukkona "
              'goturajak',
          'yo shart degil yillardan bu yana oy bermaga qara arabayla gidariz',
        ],
      }));
      expect(verdict.lang, 'tr-TR', reason: verdict.describe());
    });

    test('Турецкая речь с «kanı»: реплики не расходятся, выбор уверенный',
        () {
      // Узбекская модель пишет услышанное «kanı» своим словом qani «где?».
      // Если kanı — «чужое» слово у турецкой модели, первая реплика уходит
      // к узбекскому, и появляется жёлтая плашка «возможно, два языка».
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'oğlumun burnu kanadı kanı mendille sildim sonra doktora götürdüm',
          'doktor bir şey yok dedi akşam yemeğinden sonra uyudu',
        ],
        'uz-UZ': [
          "o'g'lumun burnu qanadi qani mendille sildim sonra doktora goturdum",
          'doktor bir shey yoq dedi aqsham yemeginden sonra uyudu',
        ],
      }));
      expect(verdict.lang, 'tr-TR', reason: verdict.describe());
      expect(verdict.mixed, isFalse, reason: verdict.describe());
      expect(verdict.confidence, LanguageConfidence.high,
          reason: verdict.describe());
    });

    test('Турецкая бытовая речь с aman, kavga, yetti: выбор уверенный', () {
      // Обычные турецкие слова, похожие на узбекские окончания или слова,
      // не должны делать выбор неуверенным.
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'aman dikkat et yollar çok kaygan dün kendimi zor tuttum',
          'çocuklar yine kavga etti yetti artık yorganı toplaman lazım dedim',
        ],
        'uz-UZ': [
          'aman dikkat et yollar chok kaygan dun kendimi zor tuttum',
          "cho'juqlar yine kavga etti yetti artiq yorgani toplaman lazim dedim",
        ],
      }));
      expect(verdict.lang, 'tr-TR', reason: verdict.describe());
      expect(verdict.mixed, isFalse, reason: verdict.describe());
      expect(verdict.confidence, LanguageConfidence.high,
          reason: verdict.describe());
    });

    test('Турецкая речь с короткой репликой «aman kavga etmeyin»: '
        'реплики не расходятся', () {
      // Узбекская модель пишет aman и kavga так же, как турецкая. Очко за
      // узбекские -aman и -ga отдало бы ей короткую реплику.
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'dün akşam markette sıra beklerken iki adam birbirine bağırmaya '
              'başladı',
          'kasiyer polisi aradı ben de dışarı çıkıp arabada bekledim',
          'aman kavga etmeyin',
        ],
        'uz-UZ': [
          "dun aqsham marketta sira beklarken iki adam birbirina bog'irmaya "
              'boshladi',
          'kasiyer polisi aradi ben de dishari chiqip arabada bekladim',
          'aman kavga etmayin',
        ],
      }));
      expect(verdict.lang, 'tr-TR', reason: verdict.describe());
      expect(verdict.mixed, isFalse, reason: verdict.describe());
    });

    test("Узбекская бытовая речь с demak, ko'pincha, tushuncha: выбор уверенный",
        () {
      final verdict = judgeLanguage(byCue({
        'uz-UZ': [
          'demak ertaga bozorga borib yemak ichmak olib kelamiz',
          "akam ko'pincha ishdan chiqquncha telefonni olmaydi demak band",
          "bu masalada hech qanday tushuncha yo'q edi demak qaytadan so'raymiz",
        ],
        'tr-TR': [
          'demek ertağa bazarga barıp yemek içmek alıp kelamız',
          'akam köpinçe işten çıkkunça telefonnu almaydı demek band',
          'bu masalada hiç kanday tuşunça yok edi demek kaytadan soraymız',
        ],
      }));
      expect(verdict.lang, 'uz-UZ', reason: verdict.describe());
      expect(verdict.mixed, isFalse, reason: verdict.describe());
      expect(verdict.confidence, LanguageConfidence.high,
          reason: verdict.describe());
    });

    test('Узбекская речь с короткой репликой «pul qani»: выбор уверенный',
        () {
      // qani «где?» — общее слово с турецким kanı, «pul» нет ни в одном
      // словаре. На такой реплике у обеих моделей ровно равный счёт, и
      // голос за неё не должен доставаться языку, который первым стоит в
      // настройках: иначе узбекский ролик выглядит как два языка.
      final verdict = judgeLanguage(
        byCue({
          'uz-UZ': [
            "kecha kechqurun qo'shnimiz eshikni taqillatdi va akamni so'radi",
            'men unga akam hali ishdan kelmadi dedim keyin u ketdi',
            'pul qani',
          ],
          'tr-TR': [
            'keçe keçkurun koşnimiz eşikni takıllattı ve akamnı soradı',
            'men unga akam hali işten kelmedi dedim keyin u ketti',
            'pul kanı',
          ],
        }),
        // Порядок по умолчанию: при ничьей первым идёт турецкий.
        candidates: const ['tr-TR', 'uz-UZ'],
      );
      expect(verdict.lang, 'uz-UZ', reason: verdict.describe());
      expect(verdict.mixed, isFalse, reason: verdict.describe());
      expect(verdict.confidence, LanguageConfidence.high,
          reason: verdict.describe());
    });

    test('Узбекские приветствия на -misiz: турецкий не выбирается', () {
      final verdict = judgeLanguage(byCue({
        'uz-UZ': [
          'yaxshimisiz tinchmisiz ishlaringiz yaxshimi charchamadingizmi',
          'uydagilar tinchmi bolalar yaxshimi tayyormisiz shuncha kutdik',
        ],
        'tr-TR': [
          'yahşimisiz tinçmisiz işlaringiz yahşimi çarçamadingizmi',
          'uydagilar tinçmi balalar yahşimi tayyormısız şunça kuttuk',
        ],
      }));
      expect(verdict.lang, 'uz-UZ', reason: verdict.describe());
    });

    test('Турецкая речь с дательным на -ğa: узбекский не выбирается', () {
      // ğ в турецком не звучит: «sokağa» слышится как «сокаа», и узбекская
      // модель пишет кальку без «г».
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'çocuğa söyledim sokağa çıkmasın arka kapıyı kilitledim',
          'şaka değil kocaman bir köpek bahçede yatağa girdi',
        ],
        'uz-UZ': [
          'chojua soyladim soqaa chiqmasin arqa qapini kilitladim',
          "shaqa degil qo'jaman bir ko'pak bog'chada yataa girdi",
        ],
      }));
      expect(verdict.lang, 'tr-TR', reason: verdict.describe());
    });

    test('Одинаковый текст у обеих моделей: уверенного выбора нет', () {
      // Обе модели услышали одно и то же и записали одинаково — по такому
      // тексту язык не определить, в какой бы словарь ни попали слова.
      final texts = [
        ['kim yedi biri yedi biri beri yedi', 'bu kim ki siz mi biz mi'],
        ['ha ana bu oy hali yo bu oy', 'ha ana biz mi siz mi bari'],
      ];
      for (final cues in texts) {
        final verdict = judgeLanguage(byCue({'uz-UZ': cues, 'tr-TR': cues}));
        expect(verdict.confidence, LanguageConfidence.low,
            reason: verdict.describe());
        expect(verdict.gap, lessThan(kHighConfidenceGap),
            reason: verdict.describe());
      }
    });

    test('Узбекский в новом алфавите (ş ç ö ğ) не принимается за турецкий',
        () {
      final verdict = judgeLanguage(byCue({
        'uz-UZ': [
          'bugun ertalab bozorga borib non oldim şuning uçun keç qoldim',
          'çoyxonaga borib öz akam bilan gaplaşdim yöq dedi',
        ],
        'tr-TR': [
          'bugün ertalap bazarga barıp nan aldım şunung üçün keç kaldım',
          'çayhanaga barıp öz akam bilen gaplaştım yok dedi',
        ],
      }));
      expect(verdict.lang, 'uz-UZ');
    });

    // Раньше этот случай останавливал обработку вопросом «Это турецкий /
    // Это узбекский». Теперь выбор делается всегда, а неуверенность
    // передаётся дальше — в сессию и в жёлтую плашку редактора.
    test('Короткая реплика без зацепок: выбран лидер, уверенность низкая', () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': ['masada on beş kalem var'],
        'uz-UZ': ['masada onbesh qalam bor'],
      }));
      expect(verdict.lang, 'tr-TR');
      expect(verdict.confidence, LanguageConfidence.low,
          reason: 'слов меньше порога — уверенным быть нельзя');
      expect(verdict.runnerUp, 'uz-UZ',
          reason: 'второй язык нужен для кнопки «Распознать как …»');
      expect(verdict.candidates.map((c) => c.lang), ['tr-TR', 'uz-UZ']);
    });

    test('Распозналась только одна модель: она и выбрана, но неуверенно', () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': ['akşam vardiyası başladı'],
        'uz-UZ': [''],
      }));
      expect(verdict.lang, 'tr-TR');
      expect(verdict.confidence, LanguageConfidence.low,
          reason: 'три слова — мало для уверенного выбора');
    });

    test('Все модели молчат: первый язык из настроек', () {
      final verdict = judgeLanguage(
        byCue({'tr-TR': ['', ''], 'uz-UZ': ['', '']}),
        candidates: const ['tr-TR', 'uz-UZ'],
      );
      expect(verdict.confidence, LanguageConfidence.none);
      expect(verdict.lang, 'tr-TR');
      expect(verdict.runnerUp, 'uz-UZ');
      expect(verdict.comparedCues, isEmpty);
    });

    test('Все модели молчат: язык прошлой обработки', () {
      final verdict = judgeLanguage(
        byCue({'tr-TR': [''], 'uz-UZ': ['']}),
        candidates: const ['tr-TR', 'uz-UZ'],
        previousLang: 'uz-UZ',
      );
      expect(verdict.confidence, LanguageConfidence.none);
      expect(verdict.lang, 'uz-UZ');
      expect(verdict.runnerUp, 'tr-TR');
    });

    test('Язык прошлой обработки годится и не из проверяемых', () {
      final verdict = judgeLanguage(
        byCue({'tr-TR': [''], 'uz-UZ': ['']}),
        previousLang: 'kk-KZ',
      );
      expect(verdict.lang, 'kk-KZ');
      expect(verdict.runnerUp, 'tr-TR');
    });

    test('Смешанный ролик: выбран язык большинства, уверенность низкая', () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': [
          'sluşay zavtra utrom nado zabrat maşinu',
          'akşam yemeğinde çorba var mı diye annem soruyor',
          'otobüs biraz geç geldi ama işe zamanında yetiştim',
        ],
        'ru-RU': [
          'слушай завтра утром надо забрать машину',
          'акшам емейинде чорба вар мы дие анам сорует',
          'а тобус бираз гечь гельди а мы же заманында етиштим',
        ],
      }));
      expect(verdict.lang, 'tr-TR');
      expect(verdict.mixed, isTrue);
      expect(verdict.confidence, LanguageConfidence.low);
      expect(verdict.candidateFor('ru-RU')!.votes, 1);
    });

    test('Реплика, на которой одна модель получила ошибку, не сравнивается',
        () {
      // Реплика 1 у узбекской модели не распознана (ошибка сервиса).
      // Турецкий текст на ней не должен «перевешивать» — иначе сравнивались
      // бы тексты разных реплик.
      final verdict = judgeLanguage({
        'tr-TR': {
          1: 'kışta çarçap kaldım şunun için işe barolmadım',
          2: 'bugün keçkurun uyga keç kaytaman şunung uçun kutmang',
        },
        'uz-UZ': {
          2: 'bugun kechqurun uyga kech qaytaman shuning uchun kutmang',
        },
      });
      expect(verdict.comparedCues, [2]);
      expect(verdict.lang, 'uz-UZ');
      expect(verdict.candidateFor('tr-TR')!.text, isNot(contains('kışta')));
    });

    test('Модель, не ответившая ни на одну пробу, не сравнивается', () {
      final verdict = judgeLanguage(
        byCue({
          'tr-TR': ['yarın sabah erkenden çarşıya gideceğiz çünkü evde '
              'ekmek yok akşam eve geç geleceğim sen beni bekleme tamam mı'],
        }),
        candidates: const ['tr-TR', 'uz-UZ'],
      );
      expect(verdict.lang, 'tr-TR');
      expect(verdict.confidence, LanguageConfidence.low,
          reason: 'с узбекской моделью никто не сравнил');
      expect(verdict.candidateFor('uz-UZ')!.compared, isFalse);
      expect(verdict.runnerUp, 'uz-UZ');
    });

    test('Модели спотыкались на разных репликах: выбывает худшая', () {
      final verdict = judgeLanguage({
        'tr-TR': {1: 'yarın sabah erkenden çarşıya gideceğiz'},
        'uz-UZ': {
          2: 'ertaga ertalab bozorga boramiz',
          3: 'bugun kechqurun uyga kech qaytaman shuning uchun kutmang',
        },
      });
      expect(verdict.lang, 'uz-UZ');
      expect(verdict.candidateFor('tr-TR')!.compared, isFalse);
      expect(verdict.confidence, LanguageConfidence.low);
    });

    test('Результат не зависит от порядка языков', () {
      final texts = byCue({
        'tr-TR': ['yarın sabah erkenden çarşıya gideceğiz'],
        'uz-UZ': ['yarin sabah erkandan charshiga gidajakmiz'],
      });
      final a = judgeLanguage(texts, candidates: const ['tr-TR', 'uz-UZ']);
      final b = judgeLanguage(texts, candidates: const ['uz-UZ', 'tr-TR']);
      expect(a.lang, b.lang);
      expect(a.candidateFor('tr-TR')!.score, b.candidateFor('tr-TR')!.score);
      expect(a.confidence, b.confidence);
    });

    test('Ничью решает порядок из настроек', () {
      final texts = byCue({
        'tr-TR': ['kalem defter'],
        'uz-UZ': ['kalem defter'],
      });
      expect(judgeLanguage(texts, candidates: const ['tr-TR', 'uz-UZ']).lang,
          'tr-TR');
      expect(judgeLanguage(texts, candidates: const ['uz-UZ', 'tr-TR']).lang,
          'uz-UZ');
    });

    test('Один язык в настройках — не выбор, а данность', () {
      final verdict = judgeLanguage(byCue({
        'uz-UZ': ['ertaga ertalab bozorga boramiz'],
      }));
      expect(verdict.lang, 'uz-UZ');
      expect(verdict.confidence, LanguageConfidence.high);
      expect(verdict.runnerUp, isNull);
    });

    test('Строка для журнала содержит числа, а не только язык', () {
      final verdict = judgeLanguage(byCue({
        'tr-TR': ['masada on beş kalem var'],
        'uz-UZ': ['masada onbesh qalam bor'],
      }));
      expect(verdict.describe(), allOf(contains('tr-TR'), contains('uz-UZ'),
          contains('отрыв'), contains('неуверенно')));
    });
  });
}
