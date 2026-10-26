import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/stocktake_count.dart';
import '../../domain/stocktake_models.dart';
import '../../domain/stocktake_repository.dart';

part 'stocktake_cells_cubit.freezed.dart';

/// Загрузка списка ячеек пересчёта.
enum StocktakeCellsStatus { loading, loaded, error }

/// Подсказка по скану ячейки или действию — один раз.
sealed class CellsNotice {
  const CellsNotice();
}

/// Отсканированной ячейки нет среди свободных и своих — её держит другой или она не из этого
/// пересчёта.
final class CellsNoticeNotHere extends CellsNotice {
  const CellsNoticeNotHere(this.address);
  final String address;
}

/// Ячейку взяли — работник идёт к ней.
final class CellsNoticeTaken extends CellsNotice {
  const CellsNoticeTaken(this.address);
  final String address;
}

/// Действие не удалось — причина [failure].
final class CellsNoticeFailed extends CellsNotice {
  const CellsNoticeFailed(this.failure);
  final Failure failure;
}

/// Пересчёт закрыт.
final class CellsNoticeClosed extends CellsNotice {
  const CellsNoticeClosed();
}

/// Ячейки пересчёта для работника (P10-04): свободные и свои; без связи — свои черновики.
@freezed
abstract class StocktakeCellsState with _$StocktakeCellsState {
  const factory StocktakeCellsState({
    @Default(StocktakeCellsStatus.loading) StocktakeCellsStatus status,
    StocktakeInfo? info,
    @Default(<StocktakeCell>[]) List<StocktakeCell> cells,

    /// Незавершённые подсчёты на терминале — продолжить без связи.
    @Default(<StocktakeCount>[]) List<StocktakeCount> drafts,
    Failure? failure,
    @Default(false) bool busy,
    CellsNotice? notice,

    /// Начатая ячейка — экран открывает подсчёт и сбрасывает поле.
    StocktakeCellView? started,
  }) = _StocktakeCellsState;

  const StocktakeCellsState._();

  List<StocktakeCell> get mine => [
    for (final c in cells)
      if (c.isMineOpen) c,
  ];

  List<StocktakeCell> get free => [
    for (final c in cells)
      if (c.isFree && !c.mine) c,
  ];
}

/// Ячейки пересчёта (P10-04): список, взять, отказаться, скан ячейки на месте — и старшему
/// смены закрыть пересчёт.
///
/// Скан адреса ячейки — главный путь: свободная берётся и сразу начинается, своя — начинается.
/// Так работник, дойдя до полки, не тыкает в список. Касание свободной — взять заранее, чтобы
/// к ней не пошёл другой.
@injectable
class StocktakeCellsCubit extends Cubit<StocktakeCellsState> {
  StocktakeCellsCubit(this._repo, @factoryParam this.stocktakeId)
    : super(const StocktakeCellsState());

  final StocktakeRepository _repo;
  final String stocktakeId;

  /// Загрузить ход и ячейки. Без связи — черновики этого пересчёта на терминале.
  Future<void> load() async {
    final info = await _repo.stocktake(stocktakeId);
    final cells = await _repo.cells(stocktakeId);
    final drafts = [
      for (final d in await _repo.drafts(stocktakeId))
        StocktakeCount.fromJson(d),
    ];
    if (isClosed) return;
    if (info.isLeft || cells.isLeft) {
      emit(
        state.copyWith(
          status: StocktakeCellsStatus.error,
          failure: info.isLeft ? info.left : cells.left,
          drafts: drafts,
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        status: StocktakeCellsStatus.loaded,
        info: info.right,
        cells: cells.right,
        drafts: drafts,
        failure: null,
      ),
    );
  }

  /// Взять свободную ячейку — к ней не пойдёт другой.
  Future<void> take(StocktakeCell cell) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.take(cell.id);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? CellsNoticeTaken(cell.address)
            : CellsNoticeFailed(res.left),
      ),
    );
    await load();
  }

  /// Отказаться от своей ячейки: начатый подсчёт отбрасывается.
  Future<void> release(StocktakeCell cell) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.release(cell.id);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isLeft ? CellsNoticeFailed(res.left) : null,
      ),
    );
    await load();
  }

  /// Скан ячейки на месте: свободная берётся, своя — начинается; снимок — в [started].
  Future<void> scanCell(String address) async {
    if (state.busy) return;
    final a = address.toLowerCase();
    final cell = state.cells
        .where(
          (c) => c.address.toLowerCase() == a && (c.isFree || c.isMineOpen),
        )
        .firstOrNull;
    if (cell == null) {
      emit(state.copyWith(notice: CellsNoticeNotHere(address)));
      return;
    }
    emit(state.copyWith(busy: true));
    if (!cell.mine) {
      final taken = await _repo.take(cell.id);
      if (taken.isLeft) {
        if (isClosed) return;
        emit(
          state.copyWith(busy: false, notice: CellsNoticeFailed(taken.left)),
        );
        await load();
        return;
      }
    }
    final res = await _repo.start(cell.id);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        started: res.isRight ? res.right : null,
        notice: res.isLeft ? CellsNoticeFailed(res.left) : null,
      ),
    );
  }

  /// Экран открыл подсчёт.
  void clearStarted() => emit(state.copyWith(started: null));

  /// Подсказка показана.
  void clearNotice() => emit(state.copyWith(notice: null));

  /// Закрыть пересчёт (старший смены); [force] — с неподсчитанными ячейками.
  Future<void> closeStocktake({required bool force}) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.close(stocktakeId, force: force);
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        notice: res.isRight
            ? const CellsNoticeClosed()
            : CellsNoticeFailed(res.left),
      ),
    );
  }
}
