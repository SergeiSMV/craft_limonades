import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_id_generator.dart';
import '../../domain/problem_photos.dart';
import '../../domain/problem_records.dart';
import 'problem_photo_view.dart';

/// Фото в карточке проблемы (ADHOC-45): снимки с сервера, свои неотправленные и съёмка новых.
///
/// Снимки с сервера грузятся по одному после открытия карточки - сама карточка от связи не
/// зависит. Свои неотправленные показываются сразу из очереди, с пометкой. Новое фото - только
/// у открытой проблемы и пока их меньше [kProblemPhotoMax]; уходит той же очередью.
@injectable
class RecordPhotosCubit extends Cubit<List<ProblemPhotoView>> {
  RecordPhotosCubit(this._photos, this._camera, this._ids) : super(const []);

  final ProblemPhotoRepository _photos;
  final PhotoCamera _camera;
  final LoadUnitIdGenerator _ids;
  ProblemRecord? _record;

  /// Можно снять ещё одно фото.
  bool get canAdd =>
      (_record?.isOpen ?? false) && state.length < kProblemPhotoMax;

  /// Показать фото проблемы: свои из очереди - сразу, с сервера - по мере загрузки.
  Future<void> load(ProblemRecord record) async {
    _record = record;
    final pending = await _photos.pendingOf(record.id);
    final pendingIds = {for (final p in pending) p.id};
    // Снимок, который уже на сервере, но ещё в очереди (ответ потерялся), - один раз.
    final remote = [
      for (final id in record.photos)
        if (!pendingIds.contains(id)) id,
    ];
    if (isClosed) return;
    emit([
      for (final id in remote) ProblemPhotoView(id: id),
      for (final p in pending)
        ProblemPhotoView(id: p.id, content: p.content, pending: true),
    ]);
    for (final id in remote) {
      final res = await _photos.fetch(problemId: record.id, photoId: id);
      if (isClosed) return;
      _replace(
        id,
        res.fold(
          (Failure _) => ProblemPhotoView(id: id, failed: true),
          (content) => ProblemPhotoView(id: id, content: content),
        ),
      );
    }
  }

  /// Снять фото и поставить в очередь. Отменили съёмку - ничего.
  Future<void> take() async {
    final record = _record;
    if (record == null || !canAdd) return;
    final content = await _camera.take();
    if (content == null || isClosed) return;
    final shot = ProblemPhotoShot(id: _ids.newId(), content: content);
    emit([
      ...state,
      ProblemPhotoView(id: shot.id, content: content, pending: true),
    ]);
    await _photos.enqueue(record.id, [shot]);
  }

  void _replace(String id, ProblemPhotoView view) =>
      emit([for (final p in state) p.id == id ? view : p]);
}
