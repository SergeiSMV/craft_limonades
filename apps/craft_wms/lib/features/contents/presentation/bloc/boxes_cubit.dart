import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/contents_entities.dart';
import '../../domain/contents_repository.dart';

/// Стадия вкладки «Короба».
enum BoxesStatus {
  /// Вкладку ещё не открывали — ничего не грузили.
  initial,
  loading,
  ready,

  /// Показать нечего: поиск не дошёл до сервера по причине, отличной от связи.
  failed,
}

/// Состояние вкладки «Короба» (P5-05-1).
class BoxesState {
  const BoxesState({
    this.status = BoxesStatus.initial,
    this.data,
    this.query = '',
    this.invalidQuery = false,
    this.failure,
  });

  final BoxesStatus status;

  /// Список коробов склада или выдача поиска — смотря по [query].
  final Viewed<List<LoadUnitView>>? data;

  /// Строка поиска как набрана.
  final String query;

  /// В строке не код короба — поиск не запускался.
  final bool invalidQuery;
  final Failure? failure;

  /// Показывается выдача поиска, а не весь список.
  bool get searching => query.trim().isNotEmpty;

  BoxesState copyWith({
    BoxesStatus? status,
    Viewed<List<LoadUnitView>>? data,
    String? query,
    bool? invalidQuery,
    Failure? failure,
  }) => BoxesState(
    status: status ?? this.status,
    data: data ?? this.data,
    query: query ?? this.query,
    invalidQuery: invalidQuery ?? this.invalidQuery,
    failure: failure,
  );
}

/// Вкладка «Короба» в «Остатках» (P5-05-1): список коробов из снимка и поиск по короткому коду.
///
/// Открытие вкладки и «потянуть вниз» сначала обновляют снимок с сервера: со связью кладовщик
/// видит склад на сейчас, без связи — снимок с подписью, на когда он.
@injectable
class BoxesCubit extends Cubit<BoxesState> {
  BoxesCubit(this._repo, this._snapshot) : super(const BoxesState());

  final ContentsRepository _repo;
  final ContentsSnapshotSync _snapshot;

  /// Пауза набора перед поиском — как у поиска товаров: не спрашивать сервер на каждый знак.
  static const _debounce = Duration(milliseconds: 400);

  Timer? _timer;

  /// Чем кончилось последнее обновление снимка; `null` — обновился. Список перечитывается из
  /// снимка и при очистке поиска — подпись берётся отсюда, а не «обновляли ли только что»:
  /// иначе после очистки поиска при живой связи экран писал «нет связи» (ADHOC-22).
  Failure? _refreshFailure;

  /// Вкладку открыли: загрузить при первом заходе.
  Future<void> open() async {
    if (state.status == BoxesStatus.initial) await reload();
  }

  /// Обновить снимок и перечитать список или выдачу поиска.
  Future<void> reload() async {
    emit(state.copyWith(status: BoxesStatus.loading));
    final res = await _snapshot.refresh();
    _refreshFailure = res.isLeft ? res.left : null;
    if (isClosed) return;
    await _show();
  }

  /// Набор в строке поиска — поиск после паузы.
  void setQueryDebounced(String text) {
    _timer?.cancel();
    emit(state.copyWith(query: text, invalidQuery: false));
    _timer = Timer(_debounce, () => unawaited(_show()));
  }

  /// Ввод завершён — искать сразу.
  Future<void> submitQuery(String text) async {
    _timer?.cancel();
    emit(state.copyWith(query: text, invalidQuery: false));
    await _show();
  }

  /// Показать список (строка пуста) или выдачу поиска по коду.
  Future<void> _show() async {
    if (!state.searching) {
      final list = await _repo.loadUnits(refreshFailure: _refreshFailure);
      if (!isClosed) {
        emit(state.copyWith(status: BoxesStatus.ready, data: list));
      }
      return;
    }
    final code = shortCodeQuery(state.query);
    if (code == null) {
      emit(state.copyWith(status: BoxesStatus.ready, invalidQuery: true));
      return;
    }
    final query = state.query;
    final res = await _repo.searchLoadUnits(code);
    // Пока шёл запрос, строку могли поменять — устаревшую выдачу не показываем.
    if (isClosed || state.query != query) return;
    emit(
      res.fold(
        (f) => state.copyWith(status: BoxesStatus.failed, failure: f),
        (found) => state.copyWith(status: BoxesStatus.ready, data: found),
      ),
    );
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
