import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../domain/contents_entities.dart';
import '../../domain/contents_repository.dart';
import 'contents_view_state.dart';

/// Карточка короба (P5-05): где лежит и что внутри.
@injectable
class LoadUnitCubit extends Cubit<ContentsViewState<LoadUnitView>> {
  LoadUnitCubit(this._repo) : super(const ContentsViewLoading());

  final ContentsRepository _repo;

  /// Загрузить карточку короба по идентификатору из QR.
  Future<void> load(String id) async {
    emit(const ContentsViewLoading());
    final res = await _repo.loadUnit(id);
    if (isClosed) return;
    emit(
      res.fold(
        (f) => ContentsViewFailed<LoadUnitView>(f),
        ContentsViewLoaded<LoadUnitView>.new,
      ),
    );
  }
}
