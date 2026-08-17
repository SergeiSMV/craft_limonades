import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

part 'stock_detail_cubit.freezed.dart';

/// Стадия загрузки остатков товара.
enum StockDetailStatus { loading, loaded, error }

/// Состояние карточки остатков товара: строки (ячейка·партия·кол-во) + общий итог + ШК товара.
@freezed
abstract class StockDetailState with _$StockDetailState {
  const factory StockDetailState({
    @Default(StockDetailStatus.loading) StockDetailStatus status,
    @Default(<StockItem>[]) List<StockItem> items,
    @Default('0') String totalQty,
    @Default(<Barcode>[]) List<Barcode> barcodes, // ШК товара (секция «Штрихкоды», P-FS-12)
    Failure? failure,
  }) = _StockDetailState;
}

/// Cubit карточки остатков: грузит остатки + ШК товара, считает общий итог, отвязывает ошибочные ШК.
@injectable
class StockDetailCubit extends Cubit<StockDetailState> {
  StockDetailCubit(this._repo) : super(const StockDetailState());

  final CatalogRepository _repo;
  String _goodId = ''; // для перезагрузки после отвязки ШК

  /// Загрузить остатки товара (по всем ячейкам/партиям) + его ШК. Ошибка ШК не валит карточку —
  /// секция просто покажется пустой (остаток важнее).
  Future<void> load(String goodId) async {
    _goodId = goodId;
    emit(state.copyWith(status: StockDetailStatus.loading, failure: null));
    final result = await _repo.listStock(goodId: goodId);
    final barcodes = await _repo.listGoodBarcodes(goodId);
    result.fold(
      (failure) => emit(state.copyWith(status: StockDetailStatus.error, failure: failure)),
      (page) => emit(state.copyWith(
        status: StockDetailStatus.loaded,
        items: page.items,
        totalQty: _sum(page.items),
        barcodes: barcodes.fold((_) => const [], (b) => b),
      )),
    );
  }

  /// Отвязать ошибочный ШК товара (P-FS-12): DELETE → перезагрузка карточки. Ошибку — в state.
  Future<void> unbindBarcode(String code) async {
    final res = await _repo.unbindBarcode(code);
    final failed = res.fold((f) {
      emit(state.copyWith(failure: f));
      return true;
    }, (_) => false);
    if (failed) return;
    await load(_goodId);
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
