import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../data/catalog_models.dart';
import '../../data/catalog_repository.dart';

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
    @Default(<Barcode>[])
    List<Barcode> barcodes, // ШК товара (секция «Штрихкоды», P-FS-12)
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
      (failure) => emit(
        state.copyWith(status: StockDetailStatus.error, failure: failure),
      ),
      (page) => emit(
        state.copyWith(
          status: StockDetailStatus.loaded,
          items: page.items,
          totalQty: _sum(page.items),
          barcodes: barcodes.fold((_) => const [], (b) => b),
        ),
      ),
    );
  }

  /// Привязать ШК к товару (P-FS-17): POST → перезагрузка карточки, чтобы список ШК пришёл
  /// с сервера, а не собирался локально. Возвращает `null` при успехе либо [Failure] — диалог
  /// показывает её у себя (в частности 409 «ШК уже за другим товаром») и остаётся открытым,
  /// поэтому в state ошибку не кладём: карточка позади не должна уходить в экран ошибки.
  Future<Failure?> bindBarcode(String code) async {
    final res = await _repo.bindBarcode(goodId: _goodId, barcode: code);
    final failure = res.fold((f) => f, (_) => null);
    if (failure == null) {
      await load(_goodId);
      return null;
    }
    // Сервер не ответил, но привязка уже легла в кэш при постановке в очередь (P2-06), и
    // карточка обязана её показать — с пометкой «ожидает отправки». Иначе кладовщик видит
    // прежний список и считает, что работа пропала.
    await _reloadBarcodes();
    return failure;
  }

  /// Перечитать только список ШК, не трогая остатки.
  ///
  /// Полная перезагрузка тут не годится: остатки читаются всегда из сети (P2-02), и без связи
  /// она увела бы карточку в экран ошибки — при том что привязка на самом деле принята.
  /// Неудачу чтения тоже не показываем: список ШК берётся из локального кэша, а если и он не
  /// дался, прежний список вернее пустого.
  Future<void> _reloadBarcodes() async {
    final barcodes = await _repo.listGoodBarcodes(_goodId);
    emit(
      state.copyWith(
        barcodes: barcodes.fold((_) => state.barcodes, (list) => list),
      ),
    );
  }

  /// Отвязать ошибочный ШК товара (P-FS-12): DELETE → перезагрузка карточки. Ошибку — в state.
  ///
  /// Товар передаётся вместе с кодом: серверу он для отвязки не нужен, но им восстанавливается
  /// привязка в локальном кэше, если сервер операцию отклонит (P2-06).
  Future<void> unbindBarcode(String code) async {
    final res = await _repo.unbindBarcode(goodId: _goodId, barcode: code);
    final failed = res.fold((f) {
      emit(state.copyWith(failure: f));
      return true;
    }, (_) => false);
    if (failed) {
      // Отвязка убрала ШК из кэша ещё при постановке в очередь — список надо перечитать,
      // иначе карточка показывает уже отвязанный код.
      await _reloadBarcodes();
      return;
    }
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
    return total.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
