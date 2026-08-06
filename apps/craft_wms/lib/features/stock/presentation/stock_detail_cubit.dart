import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

part 'stock_detail_cubit.freezed.dart';

/// Стадия загрузки остатков товара.
enum StockDetailStatus { loading, loaded, error }

/// Состояние карточки остатков товара: строки (ячейка·партия·кол-во) + общий итог.
@freezed
abstract class StockDetailState with _$StockDetailState {
  const factory StockDetailState({
    @Default(StockDetailStatus.loading) StockDetailStatus status,
    @Default(<StockItem>[]) List<StockItem> items,
    @Default('0') String totalQty,
    Failure? failure,
  }) = _StockDetailState;
}

/// Cubit карточки остатков: грузит остатки товара и считает общий итог.
@injectable
class StockDetailCubit extends Cubit<StockDetailState> {
  StockDetailCubit(this._repo) : super(const StockDetailState());

  final CatalogRepository _repo;

  /// Загрузить остатки товара (по всем ячейкам/партиям).
  Future<void> load(String goodId) async {
    emit(state.copyWith(status: StockDetailStatus.loading, failure: null));
    final result = await _repo.listStock(goodId: goodId);
    result.fold(
      (failure) => emit(state.copyWith(status: StockDetailStatus.error, failure: failure)),
      (page) => emit(state.copyWith(
        status: StockDetailStatus.loaded,
        items: page.items,
        totalQty: _sum(page.items),
      )),
    );
  }

  /// Общий итог по товару: сумма qty всех строк. Для отображения считаем в double
  /// (кол-ва ≤ numeric(20,3), точности double хватает); формат — без лишних нулей.
  String _sum(List<StockItem> items) {
    var total = 0.0;
    for (final it in items) {
      total += double.tryParse(it.qty) ?? 0;
    }
    // Убираем хвостовые нули: 10.500 → «10.5», 3.000 → «3».
    return total
        .toStringAsFixed(3)
        .replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
