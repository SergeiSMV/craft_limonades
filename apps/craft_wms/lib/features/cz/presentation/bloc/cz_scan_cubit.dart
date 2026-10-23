import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/cz_scan.dart';

part 'cz_scan_cubit.freezed.dart';

/// Стадия скана «Честного знака».
enum CzScanStatus { idle, loading, loaded, error }

/// Состояние скана марки или кода короба (CZ-04).
@freezed
abstract class CzScanState with _$CzScanState {
  const factory CzScanState({
    @Default(CzScanStatus.idle) CzScanStatus status,

    /// Код, который сейчас читается или прочитан, — как пришёл со сканера.
    String? code,
    CzScanResult? result,
    Failure? failure,
  }) = _CzScanState;
}

/// Cubit скана «Честного знака» (CZ-04): код со сканера → данные ЧЗ, товар, место в WMS,
/// состав. Куда вести кладовщика по ответу (карточка товара, привязка ШК, короб), решает экран.
@injectable
class CzScanCubit extends Cubit<CzScanState> {
  CzScanCubit(this._repo) : super(const CzScanState());

  final CzScanRepository _repo;

  /// Прочитать код. Пока ждём ответ на предыдущий скан, новый отбрасывается: двойной
  /// запрос в ЧЗ ничего не даст, а кладовщик видит, что код уже читается.
  Future<void> scan(String code) async {
    if (state.status == CzScanStatus.loading) return;
    emit(CzScanState(status: CzScanStatus.loading, code: code));
    final res = await _repo.scan(code);
    if (isClosed) return;
    res.fold(
      (f) =>
          emit(CzScanState(status: CzScanStatus.error, code: code, failure: f)),
      (r) =>
          emit(CzScanState(status: CzScanStatus.loaded, code: code, result: r)),
    );
  }

  /// Ответ показан — вернуться к ожиданию, чтобы тот же код можно было отсканировать снова.
  void reset() => emit(const CzScanState());
}
