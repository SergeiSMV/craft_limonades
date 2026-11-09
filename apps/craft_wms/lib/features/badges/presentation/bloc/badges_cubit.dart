import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/printer/badge_label.dart';
import '../../../../core/printer/printer_device.dart';
import '../../../../core/printer/printer_service.dart';
import '../../domain/badge_holder.dart';
import '../../domain/badges_repository.dart';

part 'badges_cubit.freezed.dart';

/// Подсказка экрана «Бейджи» - показывается один раз.
sealed class BadgesNotice {
  const BadgesNotice();
}

/// Номер не получен с сервера - причина [failure].
final class BadgesNoticeFetchFailed extends BadgesNotice {
  const BadgesNoticeFetchFailed(this.failure);
  final Failure failure;
}

/// Бейдж сотрудника [fullName] напечатан.
final class BadgesNoticePrinted extends BadgesNotice {
  const BadgesNoticePrinted(this.fullName);
  final String fullName;
}

/// Принтер не напечатал - текст [reason] для человека.
final class BadgesNoticePrintFailed extends BadgesNotice {
  const BadgesNoticePrintFailed(this.reason);
  final String reason;
}

enum BadgesStatus { loading, loaded, error }

/// Список «Бейджи» (ADHOC-65) и печать.
@freezed
abstract class BadgesState with _$BadgesState {
  const factory BadgesState({
    @Default(BadgesStatus.loading) BadgesStatus status,
    @Default(<BadgeHolder>[]) List<BadgeHolder> holders,
    Failure? failure,

    /// Идёт печать: повторное касание не ставит вторую.
    @Default(false) bool busy,
    BadgesNotice? notice,
  }) = _BadgesState;
}

/// «Бейджи» на ТСД (ADHOC-65): кого можно печатать - решает сервер по правам, печать - номер с
/// сервера сразу на принтер.
///
/// Номер в состоянии не хранится: он - вход в систему от имени сотрудника. Не напечаталось -
/// касание ещё раз берёт номер заново (сервер пишет в журнал каждое раскрытие).
@injectable
class BadgesCubit extends Cubit<BadgesState> {
  BadgesCubit(this._repo, this._printer) : super(const BadgesState());

  final BadgesRepository _repo;
  final PrinterService _printer;

  Future<void> load() async {
    emit(state.copyWith(status: BadgesStatus.loading));
    final res = await _repo.holders();
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(status: BadgesStatus.error, failure: f)),
      (list) => emit(
        state.copyWith(
          status: BadgesStatus.loaded,
          holders: list,
          failure: null,
        ),
      ),
    );
  }

  /// Напечатать бейдж сотрудника [h]; [position] - готовая подпись «Должность: …».
  Future<void> printBadge(BadgeHolder h, {String? position}) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true));
    final res = await _repo.badge(h.id);
    if (isClosed) return;
    if (res.isLeft) {
      emit(
        state.copyWith(busy: false, notice: BadgesNoticeFetchFailed(res.left)),
      );
      return;
    }
    final b = res.right;
    BadgesNotice notice;
    try {
      await _printer.printBadgeLabel(
        BadgeLabel(number: b.number, fullName: b.fullName, position: position),
      );
      notice = BadgesNoticePrinted(b.fullName);
    } on PrinterFailure catch (e) {
      notice = BadgesNoticePrintFailed(e.userMessage);
    } catch (e) {
      notice = BadgesNoticePrintFailed('$e');
    }
    if (isClosed) return;
    emit(state.copyWith(busy: false, notice: notice));
  }

  void clearNotice() => emit(state.copyWith(notice: null));
}
