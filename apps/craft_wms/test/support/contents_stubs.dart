import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/domain/contents_repository.dart';
import 'package:either_dart/either.dart';

/// Заглушка загрузки снимка содержимого склада (P5-05): ничего не качает, считает просьбы.
///
/// Нужна тестам очереди и синхронизации справочников: им снимок не интересен, но обе службы
/// теперь его дёргают — подтверждение приёмки и размещения, заход «Обновить».
class FakeContentsSnapshotSync implements ContentsSnapshotSync {
  /// Сколько раз загружали сразу.
  int refreshes = 0;

  /// Сколько раз просили загрузить вскоре.
  int requests = 0;

  /// Что вернёт [refresh].
  Either<Failure, void> result = const Right(null);

  @override
  Future<Either<Failure, void>> refresh() async {
    refreshes++;
    return result;
  }

  @override
  void requestRefresh() => requests++;
}

/// Заглушка репозитория содержимого (P5-05) для экранов: ячейки ищутся в [cells] по адресу,
/// ответы — то, что положил тест.
class FakeContentsRepository implements ContentsRepository {
  /// Справочник ячеек: адрес → ячейка.
  final Map<String, CellRef> cells = {};

  /// Что вернёт [loadUnit].
  Either<Failure, Viewed<LoadUnitView>> loadUnitResult = const Left(
    Failure.network(),
  );

  /// Что вернёт [cell].
  Either<Failure, Viewed<CellView>> cellResult = const Left(Failure.network());

  @override
  Future<Either<Failure, Viewed<LoadUnitView>>> loadUnit(String id) async =>
      loadUnitResult;

  @override
  Future<Either<Failure, Viewed<CellView>>> cell(CellRef cell) async =>
      cellResult;

  @override
  Future<CellRef?> findCell(String address) async => cells[address];
}

/// Зарегистрировать [repo] как репозиторий содержимого в getIt (вместо прежнего).
FakeContentsRepository registerFakeContentsRepository([
  FakeContentsRepository? repo,
]) {
  final r = repo ?? FakeContentsRepository();
  if (getIt.isRegistered<ContentsRepository>()) {
    getIt.unregister<ContentsRepository>();
  }
  getIt.registerSingleton<ContentsRepository>(r);
  return r;
}
