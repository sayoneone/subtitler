// ЗАГЛУШКА. Настоящий экран предпросмотра делается отдельно (lib/ui/review/**)
// и при слиянии заменит этот файл целиком. Здесь только конструктор, на
// который опирается оболочка (lib/ui/app_shell.dart), — чтобы она
// собиралась и проверялась до слияния.

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/logging.dart';
import '../player/preview_player.dart';

class ReviewView extends StatefulWidget {
  const ReviewView({
    super.key,
    required this.controller,
    this.playerFactory = createPreviewPlayer,
  });

  final AppController controller;
  final PreviewPlayer Function({DebugLog? log}) playerFactory;

  @override
  State<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<ReviewView> {
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Предпросмотр'));
}
