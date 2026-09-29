/// Руководство пользователя — `assets/help/guide.md`. Один файл и для
/// окна «Как пользоваться», и для GitHub: там он открывается как обычная
/// страница с картинками, и два текста не разойдутся.
///
/// В окне руководство листается по шагам, как «Советы» в macOS
/// ([guidePages]): `#` — обложка, `##` — раздел, `###` — шаг, у шага одна
/// картинка, текст и сноски (`>`).
///
/// Разметка — подмножество Markdown, которого хватает руководству:
/// заголовки `#`, `##`, `###`; абзацы; пункты `1.` и `-` (продолжение
/// пункта — строки с отступом); картинка отдельной строкой `![подпись](файл)`
/// — файл рядом с guide.md; врезка `>`; внутри текста `**жирный**`,
/// `` `код` `` и `[ссылка](адрес)`. Остальное показывается как есть.
library;

/// Где лежат руководство и его картинки.
const String kGuideDir = 'assets/help';
const String kGuideAsset = '$kGuideDir/guide.md';

/// Кусок текста с оформлением.
class GuideSpan {
  final String text;
  final bool bold;
  final bool code;

  /// Адрес ссылки; `null` — не ссылка.
  final String? link;

  const GuideSpan(this.text, {this.bold = false, this.code = false, this.link});

  @override
  bool operator ==(Object other) =>
      other is GuideSpan &&
      other.text == text &&
      other.bold == bold &&
      other.code == code &&
      other.link == link;

  @override
  int get hashCode => Object.hash(text, bold, code, link);

  @override
  String toString() => [
        if (bold) '**',
        if (code) '`',
        link == null ? text : '[$text]($link)',
        if (code) '`',
        if (bold) '**',
      ].join();
}

sealed class GuideBlock {
  const GuideBlock();
}

class GuideHeading extends GuideBlock {
  /// 1 — название руководства, 2 — раздел, 3 — подраздел.
  final int level;
  final String text;
  const GuideHeading(this.level, this.text);
}

class GuideParagraph extends GuideBlock {
  final List<GuideSpan> spans;
  const GuideParagraph(this.spans);
}

/// Пункт списка. У нумерованного — [number]: картинка между пунктами в
/// Markdown прерывает список, поэтому номер пишется явно и берётся как есть.
class GuideItem extends GuideBlock {
  final int? number;
  final List<GuideSpan> spans;
  const GuideItem(this.spans, {this.number});
}

class GuideImage extends GuideBlock {
  /// Имя файла рядом с guide.md.
  final String file;

  /// Подпись: что на картинке.
  final String caption;
  const GuideImage(this.file, this.caption);

  String get asset => '$kGuideDir/$file';
}

/// Врезка — важное, что нельзя пропустить.
class GuideNote extends GuideBlock {
  final List<GuideSpan> spans;
  const GuideNote(this.spans);
}

final RegExp _heading = RegExp(r'^(#{1,3})\s+(.+)$');
final RegExp _image = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)$');
final RegExp _numbered = RegExp(r'^(\d+)\.\s+(.*)$');
final RegExp _bullet = RegExp(r'^[-*]\s+(.*)$');
final RegExp _note = RegExp(r'^>\s?(.*)$');

/// Разбирает руководство на блоки.
List<GuideBlock> parseGuide(String source) {
  final blocks = <GuideBlock>[];
  // Текущий блок, в который ещё дописываются строки.
  String? kind; // 'p', 'item', 'note'
  int? number;
  final text = <String>[];

  void flush() {
    if (kind == null) return;
    final spans = parseInline(text.join(' '));
    blocks.add(switch (kind!) {
      'item' => GuideItem(spans, number: number),
      'note' => GuideNote(spans),
      _ => GuideParagraph(spans),
    });
    kind = null;
    number = null;
    text.clear();
  }

  void start(String what, String first, {int? n}) {
    flush();
    kind = what;
    number = n;
    text.add(first.trim());
  }

  for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    final indented = line.length != trimmed.length;
    if (_heading.firstMatch(line) case final m?) {
      flush();
      blocks.add(GuideHeading(m[1]!.length, m[2]!.trim()));
    } else if (_image.firstMatch(trimmed) case final m? when !indented) {
      flush();
      blocks.add(GuideImage(m[2]!, m[1]!.trim()));
    } else if (_numbered.firstMatch(line) case final m?) {
      start('item', m[2]!, n: int.parse(m[1]!));
    } else if (_bullet.firstMatch(line) case final m?) {
      start('item', m[1]!);
    } else if (_note.firstMatch(line) case final m?) {
      if (kind == 'note') {
        text.add(m[1]!.trim());
      } else {
        start('note', m[1]!);
      }
    } else if ((kind == 'item' && indented) || kind == 'p' || kind == 'note') {
      // Продолжение пункта (с отступом), абзаца или врезки.
      text.add(trimmed);
    } else {
      start('p', trimmed);
    }
  }
  flush();
  return blocks;
}

final RegExp _inline =
    RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)');

/// Разбирает оформление внутри строки.
List<GuideSpan> parseInline(String text) {
  final spans = <GuideSpan>[];
  var at = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > at) spans.add(GuideSpan(text.substring(at, m.start)));
    if (m[1] != null) {
      spans.add(GuideSpan(m[1]!, bold: true));
    } else if (m[2] != null) {
      spans.add(GuideSpan(m[2]!, code: true));
    } else {
      spans.add(GuideSpan(m[3]!, link: m[4]));
    }
    at = m.end;
  }
  if (at < text.length) spans.add(GuideSpan(text.substring(at)));
  return spans;
}

/// Один экран руководства: картинка, заголовок, текст и сноски под чертой.
class GuidePage {
  /// Раздел (`##`), к которому относится шаг; `null` — обложка.
  final String? chapter;
  final String title;
  final GuideImage? image;

  /// Абзацы и пункты.
  final List<GuideBlock> body;

  /// Сноски — врезки `>`: мелким текстом под чертой.
  final List<GuideNote> notes;

  const GuidePage({
    required this.chapter,
    required this.title,
    required this.image,
    required this.body,
    required this.notes,
  });
}

/// Экраны руководства: обложка (`#` и всё до первого раздела) и по экрану
/// на каждый шаг (`###`). Заголовок раздела (`##`) экрана не создаёт —
/// он подписывает свои шаги. Вторая картинка шага уходит в текст.
List<GuidePage> guidePages(List<GuideBlock> blocks) {
  final pages = <GuidePage>[];
  String? chapter;
  String? title;
  GuideImage? image;
  var body = <GuideBlock>[];
  var notes = <GuideNote>[];

  void finish() {
    if (title != null) {
      pages.add(GuidePage(
          chapter: chapter, title: title!, image: image, body: body, notes: notes));
    }
    title = null;
    image = null;
    body = [];
    notes = [];
  }

  for (final block in blocks) {
    switch (block) {
      case GuideHeading(level: 1, :final text):
        finish();
        chapter = null;
        title = text;
      case GuideHeading(level: 2, :final text):
        finish();
        chapter = text;
      case GuideHeading(:final text):
        finish();
        title = text;
      case GuideImage() when image == null:
        image = block;
      case GuideNote():
        notes.add(block);
      default:
        body.add(block);
    }
  }
  finish();
  return pages;
}
