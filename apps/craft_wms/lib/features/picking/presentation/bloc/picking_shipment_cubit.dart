import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/printer/printer_device.dart';
import '../../../../core/printer/printer_service.dart';
import '../../domain/picking_repository.dart';
import '../../domain/picking_shipment.dart';
import '../widgets/picking_format.dart';

part 'picking_shipment_cubit.freezed.dart';

/// Подсказка экрана отгрузки - показывается один раз.
sealed class ShipmentNotice {
  const ShipmentNotice();
}

/// Запрос к серверу не удался - причина [failure].
final class ShipmentNoticeFailed extends ShipmentNotice {
  const ShipmentNoticeFailed(this.failure);
  final Failure failure;
}

/// Напечатано [count] ярлыков.
final class ShipmentNoticePrinted extends ShipmentNotice {
  const ShipmentNoticePrinted(this.count);
  final int count;
}

/// Принтер не напечатал - текст [reason] для человека.
final class ShipmentNoticePrintFailed extends ShipmentNotice {
  const ShipmentNoticePrintFailed(this.reason);
  final String reason;
}

/// Скан ярлыка: короб [seq] отмечен ([again] - уже был), `null` - короб не из заказа.
final class ShipmentNoticeScanned extends ShipmentNotice {
  const ShipmentNoticeScanned(this.seq, {this.again = false});
  final int? seq;
  final bool again;
}

/// Заказ отгружен - экран закрывается.
final class ShipmentNoticeShipped extends ShipmentNotice {
  const ShipmentNoticeShipped();
}

enum PickingShipmentStatus { loading, loaded, error }

/// Собранный заказ на экране отгрузки (P9-07).
@freezed
abstract class PickingShipmentState with _$PickingShipmentState {
  const factory PickingShipmentState({
    @Default(PickingShipmentStatus.loading) PickingShipmentStatus status,
    PickingShipment? shipment,
    Failure? failure,

    /// Отсканированные ярлыки - короба, уже проверенные на отгрузке.
    @Default(<String>{}) Set<String> scanned,
    @Default(false) bool busy,
    ShipmentNotice? notice,
  }) = _PickingShipmentState;
}

/// Ярлыки и отгрузка собранного заказа (P9-07).
///
/// Что: печать ярлыков «короб N из M» и отгрузка сканом ярлыка каждого короба. Когда
/// отсканированы все короба, заказ уходит на сервер «Отгрузить» - со связью.
/// Зачем печать через сервер: сколько раз печатали ярлык, хранит сервер - повторная печать
/// только по праву, иначе испорченный ярлык перепечатывает старший смены.
@injectable
class PickingShipmentCubit extends Cubit<PickingShipmentState> {
  PickingShipmentCubit(this._repo, this._printer, @factoryParam this.orderId)
    : super(const PickingShipmentState());

  final PickingRepository _repo;
  final PrinterService _printer;
  final String orderId;

  /// Загрузить заказ с коробами; [shipment] - уже известный (ответ «Завершить сборку»).
  Future<void> load({PickingShipment? shipment}) async {
    if (shipment != null) {
      emit(
        state.copyWith(
          status: PickingShipmentStatus.loaded,
          shipment: shipment,
        ),
      );
      return;
    }
    final res = await _repo.shipment(orderId);
    if (isClosed) return;
    res.fold(
      (f) => emit(
        state.copyWith(
          status: state.shipment == null
              ? PickingShipmentStatus.error
              : state.status,
          failure: f,
        ),
      ),
      (s) => emit(
        state.copyWith(
          status: PickingShipmentStatus.loaded,
          shipment: s,
          failure: null,
        ),
      ),
    );
  }

  /// Напечатать ярлыки: ещё не печатавшиеся, а если все напечатаны - все повторно (сервер
  /// пропустит повтор только с правом).
  Future<void> printLabels() async {
    final s = state.shipment;
    if (s == null) return;
    await _print(s.unprinted.isNotEmpty ? s.unprinted : s.boxes);
  }

  /// Напечатать ярлык одного короба - испорченный; повтор - по праву.
  Future<void> printBox(PickingShipmentBox box) => _print([box]);

  Future<void> _print(List<PickingShipmentBox> boxes) async {
    if (boxes.isEmpty || state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.labels(orderId, [
      for (final b in boxes) b.loadUnitId,
    ]);
    if (isClosed) return;
    if (res.isLeft) {
      emit(state.copyWith(busy: false, notice: ShipmentNoticeFailed(res.left)));
      return;
    }
    final fresh = res.right;
    emit(state.copyWith(shipment: fresh));
    var printed = 0;
    try {
      for (final b in fresh.boxes) {
        if (!boxes.any((x) => x.loadUnitId == b.loadUnitId)) continue;
        await _printer.printPickingBoxLabel(pickingBoxLabel(fresh, b));
        printed++;
      }
    } on PrinterFailure catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(
          busy: false,
          notice: ShipmentNoticePrintFailed(e.userMessage),
        ),
      );
      return;
    } catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(busy: false, notice: ShipmentNoticePrintFailed('$e')),
      );
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(busy: false, notice: ShipmentNoticePrinted(printed)));
  }

  /// Скан ярлыка короба: свой короб отмечается, когда отмечены все - «Отгрузить».
  Future<void> scan(String raw) async {
    final s = state.shipment;
    if (s == null || s.shipped || state.busy) return;
    final id = loadUnitIdFrom(raw);
    final box = s.boxes.where((b) => b.loadUnitId == id).firstOrNull;
    if (box == null) {
      emit(state.copyWith(notice: const ShipmentNoticeScanned(null)));
      return;
    }
    if (state.scanned.contains(box.loadUnitId)) {
      emit(state.copyWith(notice: ShipmentNoticeScanned(box.seq, again: true)));
      return;
    }
    final scanned = {...state.scanned, box.loadUnitId};
    emit(
      state.copyWith(scanned: scanned, notice: ShipmentNoticeScanned(box.seq)),
    );
    if (scanned.length == s.boxes.length) await _ship(scanned);
  }

  Future<void> _ship(Set<String> boxIds) async {
    emit(state.copyWith(busy: true));
    final res = await _repo.ship(orderId, boxIds.toList());
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(busy: false, notice: ShipmentNoticeFailed(f))),
      (s) => emit(
        state.copyWith(
          busy: false,
          shipment: s,
          notice: const ShipmentNoticeShipped(),
        ),
      ),
    );
  }

  void clearNotice() => emit(state.copyWith(notice: null));
}
