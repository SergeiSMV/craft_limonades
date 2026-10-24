import 'dart:typed_data';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/features/problems/domain/problem_photos.dart';
import 'package:craft_wms/features/problems/presentation/bloc/record_photos_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:uuid/uuid.dart';

/// Очередь фото проблем в памяти (ADHOC-45): для экранов, которые её показывают, — карточка
/// проблемы и «Несинхронизированное».
class FakeProblemPhotos implements ProblemPhotoRepository {
  final queued = <String, List<ProblemPhotoShot>>{};

  @override
  Future<void> enqueue(String problemId, List<ProblemPhotoShot> shots) async =>
      (queued[problemId] ??= []).addAll(shots);

  @override
  Future<void> upload() async {}

  @override
  Future<List<PendingProblemPhoto>> pendingOf(String problemId) async => [
    for (final s in queued[problemId] ?? const <ProblemPhotoShot>[])
      PendingProblemPhoto(id: s.id, problemId: problemId, content: s.content),
  ];

  @override
  Stream<int> watchPendingCount() =>
      Stream.value(queued.values.fold(0, (n, l) => n + l.length));

  @override
  Future<Either<Failure, Uint8List>> fetch({
    required String problemId,
    required String photoId,
  }) async => const Left(Failure.network());
}

/// Камера, которая ничего не снимает: съёмку «отменили».
class NoPhotoCamera implements PhotoCamera {
  @override
  Future<Uint8List?> take() async => null;
}

/// Зарегистрировать фото проблем в getIt — очередь в памяти и cubit карточки.
FakeProblemPhotos registerProblemPhotoStubs() {
  final photos = FakeProblemPhotos();
  if (getIt.isRegistered<ProblemPhotoRepository>()) {
    getIt.unregister<ProblemPhotoRepository>();
  }
  getIt.registerSingleton<ProblemPhotoRepository>(photos);
  if (getIt.isRegistered<RecordPhotosCubit>()) {
    getIt.unregister<RecordPhotosCubit>();
  }
  getIt.registerFactory<RecordPhotosCubit>(
    () => RecordPhotosCubit(
      photos,
      NoPhotoCamera(),
      const LoadUnitIdGenerator(Uuid()),
    ),
  );
  return photos;
}
