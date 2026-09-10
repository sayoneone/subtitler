import 'package:flutter_test/flutter_test.dart';
import 'package:subtitler/core/ffmpeg/commands.dart';

void main() {
  test('Спецсимволы в путях фильтра экранируются', () {
    expect(escapeFilterArg(r'C:\Users\dev\subs.srt'),
        r'C\:\\Users\\dev\\subs.srt');
    expect(escapeFilterArg("it's.srt"), r"it\'s.srt");
  });

  test('Команда извлечения звука даёт моно 48 кГц', () {
    final args = FfmpegCommands.extractAudio(input: 'in.mp4', output: 'out.wav');
    expect(args, containsAllInOrder(['-i', 'in.mp4']));
    expect(args, containsAllInOrder(['-ac', '1']));
    expect(args, containsAllInOrder(['-ar', '48000']));
    expect(args, contains('-vn'));
    expect(args.last, 'out.wav');
  });

  test('Команда поиска пауз содержит порог и длительность', () {
    final args = FfmpegCommands.detectSilence(
        input: 'a.wav', noise: '-30dB', minDuration: 0.3);
    expect(args, contains('silencedetect=noise=-30dB:d=0.3'));
    expect(args, containsAllInOrder(['-f', 'null']));
  });

  test('Команда нарезки задаёт границы и OggOpus 64k моно', () {
    final args = FfmpegCommands.cutSegment(
        input: 'a.wav', output: 's.ogg', start: 7.52, end: 13.23);
    expect(args, containsAllInOrder(['-ss', '7.52']));
    expect(args, containsAllInOrder(['-to', '13.23']));
    expect(args, containsAllInOrder(['-c:a', 'libopus']));
    expect(args, containsAllInOrder(['-b:a', '64k']));
    expect(args, containsAllInOrder(['-ac', '1']));
  });

  test('Команда вшивания фиксирует кодек, качество и копирование звука', () {
    final args = FfmpegCommands.burnSubtitles(
      input: 'in.mp4',
      srtPath: 'subs.srt',
      fontsDir: 'fonts',
      output: 'out.mp4',
    );
    final filter = args[args.indexOf('-vf') + 1];
    expect(filter, contains('subtitles=subs.srt'));
    expect(filter, contains('fontsdir=fonts'));
    expect(filter, contains("force_style='FontName=Noto Sans,Outline=2'"));
    expect(args, containsAllInOrder(['-c:v', 'libx264']));
    expect(args, containsAllInOrder(['-crf', '18']));
    expect(args, containsAllInOrder(['-c:a', 'copy']));
  });

  test('Команда серой полосы вырезает нижние 20 % кадра в файл', () {
    final args = FfmpegCommands.grayBand(
        input: 'v.mp4', atSeconds: 4.2, output: 'band.gray');
    expect(args, containsAllInOrder(['-ss', '4.20']));
    expect(args.join(' '), contains('crop=iw:ih*0.2:0:ih*0.8'));
    expect(args.join(' '), contains('format=gray'));
    expect(args, containsAllInOrder(['-f', 'rawvideo']));
    expect(args.last, 'band.gray',
        reason: 'пишем в файл, а не в stdout: так работает и Android-раннер');
  });
}
