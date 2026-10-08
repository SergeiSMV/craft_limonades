import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../domain/contents_entities.dart';
import '../../domain/contents_repository.dart';
import '../../domain/load_unit_label_printer.dart';
import 'contents_view_state.dart';

/// Карточка короба (P5-05): где лежит и что внутри; перепечатка ярлыка (P5-05-1).
@injectable
class LoadUnitCubit extends Cubit<ContentsViewState<LoadUnitView>> {
  LoadUnitCubit(this._repo, this._printer) : super(const ContentsViewLoading());

  final ContentsRepository _repo;
  final LoadUnitLabelPrinter _printer;

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

  /// Перепечатать ярлык короба. Возвращает текст ошибки или `null`.
  ///
  /// Неживой короб тоже можно: учёт печать не меняет, а наклейка нужна человеку.
  Future<String?> reprint(String id) => _printer.printLabel(id);
}
