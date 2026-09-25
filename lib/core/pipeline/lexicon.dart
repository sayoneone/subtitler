/// Словари для определения языка по словам.
///
/// Модель распознавания пишет только своими буквами, даже когда речь чужая:
/// турецкая всегда ставит ç ş ğ ı, узбекская всегда пишет sh ch q x oʻ.
/// Поэтому считать буквы бесполезно — они показывают, какая модель писала
/// текст, а не на каком языке говорили. Считать надо слова: у «своей»
/// модели в тексте настоящие слова языка, у «чужой» — фонетическая калька,
/// в которой узнаются слова соседнего языка, записанные чужими буквами.
///
/// Списки ниже составлены вручную: местоимения с падежными формами,
/// указательные и вопросительные слова, послелоги, союзы, частицы, связки,
/// числительные, слова времени и обращения — плюс несколько самых
/// обиходных глагольных форм. Это грамматические факты языка, а не выборка
/// из чужого частотного списка. Турецкий и узбекский списки держатся одного
/// размера: язык с бо́льшим словарём получал бы завышенную долю «своих»
/// слов. Чисел здесь нет нарочно — они устаревают с каждым новым словом;
/// расхождение меньше 10 % проверяет lexicon_test, и слово, добавленное
/// только в один список, стоит уравновесить словом в другом.
library;

import '../languages.dart';

/// Единый апостроф, к которому приводятся все его разновидности.
/// Узбекская латиница пишет oʻ и gʻ со знаком U+02BB, но в текстах
/// встречаются и ‘ ’ ʼ ' ` ´ — для словаря это одна и та же буква.
const String kApostrophe = 'ʻ';

final RegExp _apostrophes = RegExp("[ʻʼ‘’'`´ʿ]");

/// Разложенные буквы (основа + надстрочный знак) собираются обратно:
/// иначе «ç», набранная как c + U+0327, развалилась бы на два слова.
const Map<String, String> _composed = {
  'ç': 'ç',
  'ş': 'ş',
  'ğ': 'ğ',
  'ö': 'ö',
  'ü': 'ü',
  'й': 'й', // и + бреве = й
  'ё': 'ё', // е + диерезис = ё
};

final RegExp _separators = RegExp(r'[^\p{L}ʻ]+', unicode: true);
final RegExp _edgeApostrophes = RegExp('^ʻ+|ʻ+\$');

/// Разбивает текст на слова в нижнем регистре.
///
/// Цифры и знаки — разделители: SpeechKit по умолчанию пишет числа
/// цифрами, и языка они не выдают. Точка над İ, которую Dart оставляет
/// после `toLowerCase()` отдельным знаком U+0307, отбрасывается.
List<String> tokenize(String text) {
  var lowered = text.toLowerCase();
  _composed.forEach((from, to) => lowered = lowered.replaceAll(from, to));
  lowered = lowered.replaceAll('̇', '').replaceAll(_apostrophes, kApostrophe);
  return lowered
      .split(_separators)
      .map((t) => t.replaceAll(_edgeApostrophes, ''))
      .where((t) => t.isNotEmpty)
      .toList();
}

/// Ключ, по которому слово ищется в словаре языка [lang].
///
/// - Турецкий: `'IŞIK'.toLowerCase()` в Dart даёт `'işik'`, а не `'ışık'`,
///   поэтому i и ı при поиске — одна буква. Крышечки (â î û) снимаются.
/// - Узбекский: 10.09.2026 Сенат одобрил реформу алфавита (oʻ→ö, gʻ→ğ,
///   sh→ş, ch→ç). Как будет писать SpeechKit, неизвестно, поэтому новая
///   запись переводится в действующую и словарь работает при любой.
/// - Русский и казахский: ё = е.
String lexKey(String word, String lang) {
  switch (lang) {
    case 'tr-TR':
      return word
          .replaceAll('ı', 'i')
          .replaceAll('â', 'a')
          .replaceAll('î', 'i')
          .replaceAll('û', 'u');
    case 'uz-UZ':
      return word
          .replaceAll('ş', 'sh')
          .replaceAll('ç', 'ch')
          .replaceAll('ö', 'oʻ')
          .replaceAll('ğ', 'gʻ');
    case 'ru-RU':
    case 'kk-KZ':
      return word.replaceAll('ё', 'е');
  }
  return word;
}

const Map<String, String> _skeletonLetters = {
  // Латиница: турецкая и узбекская запись одних и тех же звуков.
  'ş': 's', 'ç': 'c', 'ğ': 'g', 'ı': 'i', 'ö': 'o', 'ü': 'u',
  'q': 'k', 'x': 'h', 'j': 'c', 'â': 'a', 'î': 'i', 'û': 'u',
  // Кириллица: казахские буквы — к ближайшим русским.
  'ғ': 'г', 'қ': 'к', 'ң': 'н', 'ө': 'о', 'ұ': 'у', 'ү': 'у', 'і': 'и',
  'ә': 'а', 'һ': 'х', 'ё': 'е',
};

/// «Скелет» слова — общая запись для орфографий соседних языков.
///
/// Нужен, чтобы узнать турецкое слово в узбекской записи и наоборот:
/// «ishte» у узбекской модели и «işte» у турецкой дают один скелет «iste».
/// То же для казахского слова, записанного русской моделью.
String skeleton(String word) => _skeleton(word, softG: 'g', hush: 's');

/// Скелет для поиска окончаний: то же, но мягкое ğ (узбекское gʻ, в новом
/// алфавите тоже ğ) и шипящее ş (узбекское sh) остаются отдельными буквами.
///
/// - В турецком ğ не звучит как «г» — «sokağa» произносится «сокаа», а
///   узбекский дательный -ga, причастие -gan и -dagi всегда с твёрдым «г».
///   Слитые в одну букву, они узнавались в турецких sokağa, doğan, dağı.
/// - Турецкое -mış всегда с «ш», а узбекский вопрос -misiz — с «с»:
///   yaxshimisiz «как поживаете?» совпадал с турецким -mışız.
String _suffixSkeleton(String word) =>
    _skeleton(word, softG: 'ğ', hush: 'ş');

String _skeleton(String word, {required String softG, required String hush}) {
  final s = word
      .replaceAll('oʻ', 'o')
      .replaceAll('gʻ', softG)
      .replaceAll(kApostrophe, '')
      .replaceAll('sh', hush)
      .replaceAll('ch', 'c');
  final out = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    out.write(switch (ch) {
      'ğ' => softG,
      'ş' => hush,
      _ => _skeletonLetters[ch] ?? ch,
    });
  }
  return out.toString();
}

/// Словарь одного языка.
class Lexicon {
  final String lang;

  /// Слова в виде [lexKey].
  final Set<String> words;

  /// Скелеты тех же слов — для поиска «чужих» слов.
  final Set<String> skeletons;

  /// Характерные окончания. Проверяются по скелету слова, чтобы узнавать
  /// их и в чужой орфографии: «gidiyorum» у узбекской модели — это
  /// турецкое -iyor.
  final List<RegExp> suffixes;

  /// Обычные слова этого языка, которые оканчиваются как слова соседа:
  /// узбекские turmush и kelajak — как турецкие -mış и -acak. У модели
  /// этого языка такое слово не признак чужой речи.
  final List<RegExp> lookalikes;

  Lexicon._(this.lang, this.words, this.suffixes, this.lookalikes)
      : skeletons = words.map(skeleton).toSet();

  factory Lexicon._build(
    String lang,
    String raw,
    List<String> suffixes, [
    List<String> lookalikes = const [],
  ]) {
    final words = tokenize(raw).map((w) => lexKey(w, lang)).toSet();
    return Lexicon._(
      lang,
      words,
      [for (final s in suffixes) RegExp(s, unicode: true)],
      [for (final s in lookalikes) RegExp(s, unicode: true)],
    );
  }

  /// Есть ли у слова [word] (в записи любой модели) окончание этого языка.
  /// Окончания ищутся только у слов от четырёх букв: у коротких
  /// совпадение почти всегда случайно.
  bool hasSuffix(String word) {
    final s = _suffixSkeleton(word);
    return s.runes.length >= 4 && suffixes.any((r) => r.hasMatch(s));
  }

  /// Слово этого языка, похожее окончанием на соседа (см. [lookalikes]).
  bool isLookalike(String word) {
    final s = _suffixSkeleton(word);
    return lookalikes.any((r) => r.hasMatch(s));
  }
}

/// Словарь для [lang] или `null`, если его нет. Без словаря язык
/// получает только общие признаки (длина, зацикливание) и на
/// автоопределении почти не выигрывает — такие языки выбираются
/// вручную через «Не тот язык?».
Lexicon? lexiconFor(String lang) => _lexicons[lang];

/// Языки, для которых есть словарь.
Iterable<String> get kLexiconLanguages => _lexicons.keys;

final Map<String, Lexicon> _lexicons = {
  'tr-TR': Lexicon._build(
    'tr-TR',
    '$_turkish ${_sharedTurkishUzbek.map((pair) => pair.$1).join(' ')}',
    _turkishSuffixes,
    _turkishLookalikes,
  ),
  'uz-UZ': Lexicon._build(
    'uz-UZ',
    '$_uzbek ${_sharedTurkishUzbek.map((pair) => pair.$2).join(' ')}',
    _uzbekSuffixes,
    _uzbekLookalikes,
  ),
  'ru-RU': Lexicon._build('ru-RU', _russian, _russianSuffixes),
  'kk-KZ': Lexicon._build('kk-KZ', _kazakh, _kazakhSuffixes),
};

/// Письменность языка: «чужие» слова ищутся только среди языков той же
/// письменности — латинская калька кириллическому словарю не сравнима.
Script? scriptOf(String lang) => languageByCode(lang)?.script;

// ---------------------------------------------------------------------------
// Турецкий
// ---------------------------------------------------------------------------

const String _turkish = '''
ben beni bana bende benden benim benimle
sen seni sana sende senden senin seninle
o onu ona onda ondan onun onunla
biz bizi bize bizde bizden bizim bizimle
siz sizi size sizde sizden sizin sizinle
onlar onları onlara onlarda onlardan onların
kendi kendim kendin kendisi kendine
bu bunu buna bunda bundan bunun bunlar bunları bunlara
şu şunu şuna şunda şundan şunun şunlar
burası burada buradan buraya orası orada oradan oraya şurada şuraya
böyle şöyle öyle onca
ne neyi neye neden nerede nereye nereden nerde nasıl niye niçin
kim kimi kime kimin kimse hangi hangisi kaç kaçta
mı mi mu mü mısın misin musun müsün mıyım miyim
ve veya ya yahut ama fakat ancak lakin çünkü eğer ki de da hem yoksa madem
oysa sanki halbuki gerçi
için gibi kadar göre karşı doğru beri sonra önce rağmen dolayı ile birlikte
başka
bile daha en çok az pek hiç hep her hemen şimdi artık zaten yine gene sadece
yalnız belki tabii tabi galiba herhalde acaba bari işte yani hani sakın hâlâ
var yok değil değilim değilsin değiliz idi imiş ise vardı yoktu değildi
olur oldu olmaz olsun olan olarak oluyor olacak olmuş
evet hayır tamam peki hadi haydi lütfen teşekkürler teşekkür sağol merhaba
selam efendim
abi abla ağabey kardeşim hocam amca teyze
bugün yarın dün akşam sabah öğlen gece erken geç hafta yıl saat dakika gün
zaman
bir iki üç dört beş altı yedi sekiz dokuz on yirmi otuz kırk elli yüz bin
milyon
hepsi herkes herşey hiçbir biri birisi bazı birkaç biraz
ev eve evde evden
geldi gitti dedi diye bak bakın gel git geliyor gidiyor biliyorum bilmiyorum
istiyorum istemiyorum lazım gerek yapıyor yaptı söyle söyledi
''';

/// Окончания в «скелетной» записи (ı→i, ü→u, ç→c; ğ и ş остаются).
const List<String> _turkishSuffixes = [
  r'[iu]yor', // настоящее время: gidiyorum, geliyor
  r'm[iu]ş(t[iu]m|t[iu]n|t[iu]k|t[iu]|[iu]m|s[iu]n|[iu]z|l[ae]r)?$', // -mış
  // Будущее время: gideceğiz, alacak. Гласные по сингармонизму одинаковые —
  // это отсекает узбекское kechagi «вчерашний».
  r'(aca|ece)[kgğ]',
  r'[^aeiou][iu]p$', // деепричастие -ıp/-ip: gidip, alıp
  r'd[iu]kt[ae]n$', // -dıktan sonra: geldikten
  r'[^g][iu]nc[ae]$', // -ınca/-ince: bitince, gelince
  r'rken$', // -irken: çalışırken, giderken
  r'm[ae]k$', // неопределённая форма: gitmek, almak
  r's[iu]n[iu]z$', // 2-е лицо мн. ч.: gelsiniz
];

/// Турецкие слова, похожие на узбекское -aman «я …-ю»: kocaman «огромный»,
/// kahraman «герой», yaman «ловкий». Отглагольное -man после основы на -a
/// (anlaman «чтобы ты понял») от узбекского -aman (olaman «возьму») по
/// буквам не отличить — оно оставлено.
const List<String> _turkishLookalikes = [
  r'^(koc|kahr|y)aman$',
];

// ---------------------------------------------------------------------------
// Узбекский (действующая латиница; oʻ и gʻ записаны с ASCII-апострофом —
// tokenize приводит его к единому знаку)
// ---------------------------------------------------------------------------

const String _uzbek = '''
men meni menga menda mendan mening
sen seni senga senda sendan sening
u uni unga unda undan uning
biz bizni bizga bizda bizdan bizning
siz sizni sizga sizda sizdan sizning
ular ularni ularga ularda ulardan ularning
o'zi o'zim o'zing o'zimiz o'zingiz o'z
bu buni bunga bunda bundan buning bular
shu shuni shunga shunda shundan shuning shular
o'sha o'shani o'shanga o'shanda ana mana ushbu
bunday shunday unday qanday shunaqa bunaqa qanaqa
nima nimani nimaga nimada nimadan nega nechta necha qancha uncha
qayer qayerda qayerga qayerdan qachon qani
kim kimni kimga kimning kimdan qaysi mi
va yoki ammo lekin biroq chunki agar ham hamda yo go'yo balki holbuki
uchun bilan kabi qadar sari keyin oldin so'ng orqali haqida tomon birga boshqa
bo'yicha ko'ra tufayli ichida oldida
faqat yana hali hozir endi hech hamma har juda ko'p oz sal eng albatta
shekilli axir hatto ancha doim hamisha menimcha biroz avval
bor yo'q emas edi ekan emish edim eding edik
bo'ladi bo'ldi bo'lsa bo'lgan bo'lib bo'lmaydi kerak mumkin shart lozim
ha xo'p mayli rahmat assalomu alaykum xayr salom iltimos marhamat
kechirasiz to'g'ri
aka opa uka singil akam ukam opajon domla xola amaki ota
bugun ertaga kecha indinga ertalab kechqurun tushda tunda erta kech
hafta oy yil soat daqiqa kun vaqt payt
bir ikki uch to'rt besh olti yetti sakkiz to'qqiz o'n yigirma o'ttiz qirq
ellik yuz ming million
hammasi biror birov ba'zi
uy uyga uyda uydan
keldi ketdi dedi deb degan qara qarang kel ket keling boring bilaman
bilmayman xohlayman qilib qildi qiladi boradi keladi qilyapti ketyapti
kelyapti boramiz
''';

/// Окончания в «скелетной» записи (ch→c, q→k, x→h, oʻ→o; gʻ → ğ, sh → ş).
const List<String> _uzbekSuffixes = [
  r'..yap(ti|man|san|miz|siz|tilar)$', // настоящее: kelyapti, ketyapman
  r'mokda$', // -moqda: bormoqda
  r'ning$', // родительный падеж: shuning, uyning
  r'[^n]ga$', // дательный падеж: bozorga, ishga (но не турецкое sokağa)
  // Дательный -ka/-qa бывает только после k и q: ko'kka, qishloqqa. Иначе
  // под него попадали турецкие arka, şaka, halka, fabrika.
  r'kka$',
  r'gan(i|ni|da|dan|ga|lar|imiz|ingiz|mi)?$', // причастие: kelgan, qilgan
  r'[ae]man$', // 1-е лицо ед. ч.: boraman, kelaman
  r'[iu]b$', // деепричастие -ib: borib, kelib, olib
  r'mokci', // намерение -moqchi: bormoqchi
  r'mok$', // неопределённая форма -moq: bormoq
  r'dagi$', // -dagi: uydagi
  r'(iz|an|di|ng)mi$', // слитная частица -mi: keldingizmi
  r'mi(siz|san)$', // вопрос: yaxshimisiz, tinchmisan
];

/// Узбекские слова, похожие на турецкие окончания: на -mish (turmush
/// «жизнь», o'tmish «прошлое», kumush «серебро») — как турецкое -mış; на
/// -ajak (kelajak «будущее», bo'lajak «будущий») — как -acak; ko'mak
/// «помощь» — как -mak; ixtiyor «воля» — как -iyor. Узбекское diyor
/// «край» сюда нарочно не внесено: турецкое diyor «говорит» — одно из
/// самых частых слов.
const List<String> _uzbekLookalikes = [
  r'm[iu]ş(l[ae]r)?$',
  r'^(kel|bol)acak',
  r'^komak',
  r'^ihtiyor',
];

// ---------------------------------------------------------------------------
// Общие слова турецкого и узбекского
// ---------------------------------------------------------------------------

/// Слова, обычные в обоих языках, с одним и тем же скелетом: пара
/// (турецкая запись, узбекская запись). Каждое попадает в ОБА словаря.
///
/// «Чужим» слово считается, когда его скелет есть только в словаре соседа.
/// Словари короткие, и «нет в своём списке» ещё не значит «не слово своего
/// языка»: ya'ni, beri, qarshi — обычные узбекские слова, но жили только в
/// турецком списке (yani, beri, karşı). Узбекская модель за каждое такое
/// слово получала штраф, а турецкая калька — очко, и узбекская речь с
/// частым ya'ni уверенно уходила в турецкий. Зеркально — турецкие ana,
/// kara, oy, şart из узбекского списка. Внесённое в оба словаря слово
/// считается своим у обеих моделей и выбор не сдвигает.
///
/// Нарочно НЕ внесены слова, которые в одном из языков редкие: узбекские
/// ham «тоже», kel «иди», uy «дом», mana «вот», xoʻp «ладно», axir «ведь»,
/// qani «где же» (по-турецки ham — «сырой», kel — «лысый», mana — «смысл»,
/// ahır — «хлев», kanı — «его кровь») и узбекское de «скажи» против самого
/// частого турецкого de. В речи на своём языке они звучат несравнимо чаще,
/// чем у соседа, и остаются признаком языка.
const List<(String, String)> _sharedTurkishUzbek = [
  ('yani', "ya'ni"), // то есть
  ('biri', 'biri'), // один из
  ('beri', 'beri'), // с тех пор
  ('karşı', 'qarshi'), // против, напротив
  ('yedi', 'yedi'), // съел (тур. ещё «семь»)
  ('ki', 'ki'), // союз «что»
  ('da', 'da'), // частица, союз
  ('ona', 'ona'), // тур. «ему», узб. «мать»
  ('sana', 'sana'), // тур. «тебе», узб. «дата; считай»
  ('bari', 'bari'), // тур. «хотя бы», узб. «все»
  ('kimi', 'kimi'), // тур. «кого; некоторые», узб. «кем (приходится)»
  ('yoksa', "yo'qsa"), // иначе
  ('ana', 'ana'), // тур. «мать, главный», узб. «вон»
  ('kara', 'qara'), // тур. «чёрный», узб. «смотри»
  ('ha', 'ha'), // да, ага
  ('yo', 'yo'), // тур. «нет», узб. «или»
  ('halı', 'hali'), // тур. «ковёр», узб. «ещё»
  ('şart', 'shart'), // условие, обязательно
  ('sarı', 'sari'), // тур. «жёлтый», узб. «в сторону»
  ('oy', 'oy'), // тур. «голос», узб. «месяц»
  ('öz', "o'z"), // свой, сам
  ('yana', 'yana'), // тур. «в сторону», узб. «ещё»
  ('bunca', 'buncha'), // столько (иначе — как турецкое -ınca)
  ('şunca', 'shuncha'), // столько
];

// ---------------------------------------------------------------------------
// Русский и казахский: списки короче, их включают в настройках не по
// умолчанию. Нужны, чтобы при включении эти языки хоть как-то работали.
// ---------------------------------------------------------------------------

const String _russian = '''
и в во не на я что он она оно они мы вы ты с со это а как по но к ко у же так
да нет все всё был была было были за от из мне меня мной тебе тебя тобой его
её их им ему ей нам нас вам вас то бы о об только уже вот ну есть когда если
может где ещё здесь там тут сейчас потом надо нужно можно этот эта эти этого
этой тот та те того той очень хорошо ладно давай сегодня завтра вчера кто чем
чего куда откуда почему зачем мой моя моё мои твой твоя наш наша ваш ваша
свой сам сама тоже даже просто вообще короче слушай смотри будет буду будем
сказал говорит знаю знаешь хочу пусть чтобы потому или либо ни без для до
при про через над под после между около тогда один два три четыре пять
шесть семь восемь девять десять сто тысяча
''';

const List<String> _russianSuffixes = [
  r'(ого|его|ому|ему|ыми|ими)$',
  r'(ешь|ишь|ете|ите|ают|яют|ует|уют)$',
  r'(ость|ение|ание|ться|тся)$',
  r'(ый|ий|ое|ые)$',
];

const String _kazakh = '''
мен сен ол біз сіз олар бұл сол осы мына ана анау
мені сені оны бізді сізді оларды маған саған оған бізге сізге оларға
менің сенің оның біздің сіздің олардың менде сенде онда бізде сізде
және да де та те ма ме ба бе па пе ғой ғана емес жоқ бар үшін туралы сияқты
дейін кейін бірақ енді қазір тағы тек сосын ал егер өйткені немесе әлі тіпті
бүгін ертең кеше кешке таңертең қалай неге не кім қайда қашан қандай неше
қанша иә ия жақсы рахмет әрине көп аз барлық әр бәрі
айт айтты деді деп келді кетті барамыз барады келеді жатыр болды болады
керек мүмкін
бір екі үш төрт бес алты жеті сегіз тоғыз он жиырма отыз қырық елу жүз мың
аға апа іні әке шеше міне үй үйге үйде
''';

/// В «скелете» казахские буквы уже заменены русскими (қ→к, ң→н, і→и…),
/// поэтому окончания подобраны так, чтобы не совпадать с русскими словами:
/// ни дательного -ға/-қа (→ «-га/-ка», как в «книга»), ни -дің (→ «-дин»,
/// как в «один»).
const List<String> _kazakhSuffixes = [
  r'(нын|нин|дын|тын|тин)$', // родительный падеж
  r'(мыз|миз|быз|биз|пыз|пиз)$', // 1-е лицо мн. ч.
  r'(мын|мин|бын|бин|пын|пин)$', // 1-е лицо ед. ч.: келемін, жоқпын
  r'[ыи]п$', // деепричастие: барып, келіп
  r'(ган|ген|кен)$', // причастие: келген, барған
];
