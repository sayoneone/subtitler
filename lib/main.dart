import 'package:flutter/material.dart';

void main() => runApp(const SubtitlerApp());

class SubtitlerApp extends StatelessWidget {
  const SubtitlerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Subtitler'))),
    );
  }
}
