import 'dart:typed_data';

import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../import/import_report.dart';
import 'cell_setup.dart';

/// Репозиторий страницы «Ячейки» портала (ADHOC-57): список ячеек и стеллажей, массовая
/// правка галочек этикеток, загрузка и выгрузка `.xlsx` в формате rack_labels, печать PDF.
/// Отдаёт `Either<Failure, T>`.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `CellsRepositoryImpl` в `data`.
abstract interface class CellsRepository {
  /// Код склада. На пилоте склад один - «Шабулина»/SHB (совпадает с дефолтом бэкенда).
  static const String warehouse = 'SHB';

  /// Все ячейки склада (без ячейки приёмки) и его стеллажи: `GET /cells/setup`.
  Future<Either<Failure, CellsSetup>> loadSetup();

  /// Массовая правка галочек: `PATCH /cells/setup`. В теле - только изменённые галочки;
  /// «на карточке» сервер ставит только ячейкам со стеллажом. Всё или ничего: 409 - среди
  /// ячеек есть чужие, ничего не изменено. Ответ - сколько ячеек изменено.
  Future<Either<Failure, int>> saveSettings(
    List<String> cellIds,
    Map<CellFlag, bool> changes,
  );

  /// Выгрузка всего склада `.xlsx` в формате rack_labels: `GET /cells/export.xlsx`.
  Future<Either<Failure, Uint8List>> exportCells();

  /// PDF одного вида: `POST /cells/labels.pdf`. Пустой [cellIds] - весь склад. 409 - чужие
  /// ячейки; 422 - печатать нечего или не влезает (причины - в тексте ошибки).
  Future<Either<Failure, Uint8List>> labelsPdf(
    LabelKind kind,
    List<String> cellIds,
  );

  /// Загрузка `.xlsx` в формате rack_labels: `POST /import/cells` (multipart, поле `file`).
  /// На вебе файла на диске нет - шлём байты из выбора файла браузера.
  Future<Either<Failure, CellsImportReport>> importCells({
    required List<int> bytes,
    required String filename,
  });

  /// Завести напольную ячейку (ADHOC-61): `POST /cells/floor`. Ответ - id и адрес, как его
  /// записал сервер («d-h-п» → «D-Н-П»). 400 - адрес не вида «D-Н-П», 409 - адрес занят.
  Future<Either<Failure, ({String id, String address})>> createFloorCell(
    String address,
  );

  /// Новый адрес напольной ячейки: `PATCH /cells/floor/{id}`. 404 - ячейки уже нет, 409 - адрес
  /// занят.
  Future<Either<Failure, ({String id, String address})>> renameFloorCell(
    String id,
    String address,
  );

  /// Убрать пустую напольную ячейку: `DELETE /cells/floor/{id}`. 409 - в ячейке товар или
  /// короба.
  Future<Either<Failure, void>> deleteFloorCell(String id);
}
