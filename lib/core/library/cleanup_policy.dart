// lib/core/library/cleanup_policy.dart
import 'library_entry.dart';

/// Сколько места библиотеке разрешено занимать по умолчанию.
const int kDefaultLimitBytes = 2 * 1024 * 1024 * 1024;

/// С какой доли лимита предупреждаем заранее.
const double kWarnFraction = 0.8;

/// Что предстоит удалить. План только описывает — удаляет вызывающий,
/// и он же сообщает об этом человеку.
class CleanupPlan {
  /// У этих записей удаляются видео (исходник и результат). Текст остаётся.
  final List<String> idsToStrip;
  final int freedBytes;

  /// Места всё равно не хватает: всё оставшееся закреплено.
  final bool limitStillExceeded;

  const CleanupPlan({
    required this.idsToStrip,
    required this.freedBytes,
    required this.limitStillExceeded,
  });

  bool get isEmpty => idsToStrip.isEmpty;
}

/// Решает, у каких записей убрать видео, чтобы уложиться в [limitBytes].
///
/// Удаляются только видео и только у самых старых незакреплённых записей,
/// и ровно столько, сколько нужно. Текст, тайминги и перевод не трогаются
/// никогда: они весят килобайты, а именно за ними в историю и возвращаются.
CleanupPlan planCleanup(LibraryIndex index, {required int limitBytes}) {
  var total = index.totalBytes;
  if (total <= limitBytes) {
    return const CleanupPlan(
        idsToStrip: [], freedBytes: 0, limitStillExceeded: false);
  }

  final candidates = index.entries
      .where((e) => !e.pinned && !e.mediaRemoved && e.mediaBytes > 0)
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  final ids = <String>[];
  var freed = 0;
  for (final entry in candidates) {
    if (total <= limitBytes) break;
    ids.add(entry.id);
    freed += entry.mediaBytes;
    total -= entry.mediaBytes;
  }

  return CleanupPlan(
    idsToStrip: ids,
    freedBytes: freed,
    limitStillExceeded: total > limitBytes,
  );
}

/// Пора ли предупредить, что место заканчивается.
bool shouldWarnAboutSpace(LibraryIndex index, {required int limitBytes}) =>
    index.totalBytes >= limitBytes * kWarnFraction;
