import 'dart:typed_data';

import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Фото к проблеме склада (ADHOC-45): снимает ТСД, хранятся на сервере в базе.

/// Сколько фото может быть у проблемы - столько же разрешает сервер.
const int kProblemPhotoMax = 3;

/// Снимок, сделанный на терминале: идентификатор выдан здесь же.
class ProblemPhotoShot {
  const ProblemPhotoShot({required this.id, required this.content});

  final String id;
  final Uint8List content;
}

/// Снимок, ещё не загруженный на сервер.
class PendingProblemPhoto {
  const PendingProblemPhoto({
    required this.id,
    required this.problemId,
    required this.content,
  });

  final String id;
  final String problemId;
  final Uint8List content;
}

/// Фото проблем: своя очередь загрузки и чтение снимков с сервера.
///
/// Зачем отдельная очередь: снимок весит сотни килобайт, и в теле операции проблемы он
/// задерживал бы всё, что стоит за ней. Проблема уходит обычной операцией, снимки догоняют её.
/// Реализация - `ProblemPhotoRepositoryImpl` в `data`.
abstract interface class ProblemPhotoRepository {
  /// Поставить снимки проблемы в очередь и сразу попробовать отправить. Без связи уйдут сами.
  Future<void> enqueue(String problemId, List<ProblemPhotoShot> shots);

  /// Догрузить очередь - после входа: снимки, снятые до перезапуска, уходят, не дожидаясь
  /// следующего прохода очереди операций. Без связи - ждут дальше.
  Future<void> upload();

  /// Неотправленные снимки проблемы - показать рядом с загруженными.
  Future<List<PendingProblemPhoto>> pendingOf(String problemId);

  /// Сколько снимков ждут отправки - живое число для экрана «Несинхронизированное».
  Stream<int> watchPendingCount();

  /// Снимок с сервера. Только со связью.
  Future<Either<Failure, Uint8List>> fetch({
    required String problemId,
    required String photoId,
  });
}

/// Камера терминала: снять и сжать снимок. `null` - съёмку отменили.
abstract interface class PhotoCamera {
  Future<Uint8List?> take();
}
