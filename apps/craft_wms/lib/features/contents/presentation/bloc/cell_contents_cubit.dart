import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../domain/contents_entities.dart';
import '../../domain/contents_repository.dart';
import 'contents_view_state.dart';

/// Содержимое ячейки (P5-05): живые короба и россыпь.
@injectable
class CellContentsCubit extends Cubit<ContentsViewState<CellView>> {
  CellContentsCubit(this._repo) : super(const ContentsViewLoading());

  final ContentsRepository _repo;

  /// Загрузить содержимое ячейки.
  Future<void> load(CellRef cell) async {
    emit(const ContentsViewLoading());
    final res = await _repo.cell(cell);
    if (isClosed) return;
    emit(
      res.fold(
        (f) => ContentsViewFailed<CellView>(f),
        ContentsViewLoaded<CellView>.new,
      ),
    );
  }
}
