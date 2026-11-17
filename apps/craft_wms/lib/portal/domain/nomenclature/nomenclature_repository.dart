import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../import/import_report.dart';

/// Репозиторий импорта справочников через веб-портал.
/// Отдаёт `Either<Failure, ImportReport>`.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `NomenclatureRepositoryImpl` в `data`.
abstract interface class NomenclatureRepository {
  /// Загрузка `.xls`-выгрузки номенклатуры: `POST /import/goods` (multipart, поле `file`).
  /// Что: шлём байты выбранного файла на бэкенд, получаем отчёт created/updated/skipped.
  /// Зачем: на вебе файла на диске нет - работаем с байтами из file_picker (`withData`).
  /// Как: MultipartFile.fromBytes с именем файла (бэкенд читает поле `file`); admin-only -
  ///      access подставит AuthInterceptor, 403 для не-admin приедет как ServerFailure.
  Future<Either<Failure, ImportReport>> importGoods({
    required List<int> bytes,
    required String filename,
  });
}
