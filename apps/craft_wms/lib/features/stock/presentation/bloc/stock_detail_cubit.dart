import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../contents/domain/stock_entities.dart';
import '../../data/catalog_models.dart';
import '../../data/catalog_repository.dart';

part 'stock_detail_cubit.freezed.dart';

/// Стадия загрузки остатков товара.
enum StockDetailStatus { loading, loaded }

/// Состояние карточки остатков товара: места (ячейка · короб · партия · кол-во) + общий итог
/// + ШК товара.
@freezed
abstract class StockDetailState with _$StockDetailState {
  const factory StockDetailState({
    @Default(StockDetailStatus.loading) StockDetailStatus status,
    @Default(<StockPlace>[]) List<StockPlace> items,
    @Default('0') String totalQty,

    /// Откуда места: с только что обновлённого снимка или из прежнего (ADHOC-33).
    DataFreshness? freshness,
    @Default(<Barcode>[])
    List<Barcode> barcodes, // ШК товара (секция «Штрихкоды», P-FS-12)
    Failure? failure,
  }) = _StockDetailState;
}

/// Cubit карточки остатков: грузит места товара + его ШК, считает общий итог, отвязывает
/// ошибочные ШК.
///
/// Места — из снимка склада со своей очередью поверх (ADHOC-33, закрыл долг 22): карточка
/// открывается и без связи, с подписью, на когда снимок. До ADHOC-33 остатки читались только
/// с сервера (`GET /stock`), и без связи карточка уходила в экран ошибки.
@injectable
class StockDetailCubit extends Cubit<StockDetailState> {
  StockDetailCubit(this._repo, this._contents, this._snapshot)
    : super(const StockDetailState());

  final CatalogRepository _repo;
  final ContentsRepository _contents;
  final ContentsSnapshotSync _snapshot;
  String _goodId = ''; // для перезагрузки после отвязки ШК

  /// Загрузить места товара (по всем ячейкам, коробам и партиям) + его ШК. Сначала снимок
  /// обновляется с сервера; не вышло — места из прежнего снимка с подписью. Ошибка ШК не валит
  /// карточку — секция просто покажется пустой (остаток важнее).
  Future<void> load(String goodId) async {
    _goodId = goodId;
    emit(state.copyWith(status: StockDetailStatus.loading, failure: null));
    final refreshed = await _snapshot.refresh();
    final places = await _contents.goodPlaces(
      goodId,
      refreshFailure: refreshed.isLeft ? refreshed.left : null,
    );
    final barcodes = await _repo.listGoodBarcodes(goodId);
    if (isClosed) return;
    final items = places.value ?? const <StockPlace>[];
    emit(
      state.copyWith(
        status: StockDetailStatus.loaded,
        items: items,
        totalQty: _sum(items),
        freshness: places.freshness,
        barcodes: barcodes.fold((_) => const [], (b) => b),
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
  /// Полная перезагрузка тут не нужна: остатки не менялись, а без связи она заново ждала бы
  /// обновления снимка. Неудачу чтения тоже не показываем: список ШК берётся из локального кэша, а если и он не
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

  /// Общий итог по товару: сумма количеств всех мест, всех внутренних складов — кладовщику нужно
  /// фактическое количество на складе. Формат — без лишних нулей.
  String _sum(List<StockPlace> items) {
    var total = 0.0;
    for (final it in items) {
      total += it.qty;
    }
    // До тысячных, как numeric(20,3): сложение double иначе даёт «11.999999».
    return fmtQty((total * 1000).roundToDouble() / 1000);
  }
}
