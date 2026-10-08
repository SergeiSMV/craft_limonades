import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'contents_entities.dart';

/// Содержимое ячеек и коробов для экранов (P5-05).
///
/// Что: карточка короба и содержимое ячейки по скану.
/// Зачем абстракция: экраны не знают, откуда данные — с сервера, из снимка на терминале или
/// из своей неотправленной операции. Реализация решает это сама и говорит только «откуда»
/// ([DataFreshness]), чтобы экран честно подписал данные.
/// Как реализовано — `ContentsRepositoryImpl` в `data`: сначала сервер, без связи — снимок,
/// поверх обоих — свои операции очереди в статусах «ожидает» и «отправляется».
abstract interface class ContentsRepository {
  /// Карточка короба по идентификатору из QR ярлыка.
  ///
  /// `Left` — только когда показать нечего вовсе: связи нет и снимка ещё не было.
  Future<Either<Failure, Viewed<LoadUnitView>>> loadUnit(String id);

  /// Содержимое ячейки.
  Future<Either<Failure, Viewed<CellView>>> cell(CellRef cell);

  /// Ячейка по отсканированному адресу — из справочника терминала; `null` — такой нет.
  Future<CellRef?> findCell(String address);
}

/// Загрузка снимка содержимого склада в кэш терминала.
///
/// Отдельно от [ContentsRepository]: ей пользуются не экраны, а синхронизация (вместе со
/// справочниками) и очередь (после подтверждения приёмки и размещения).
abstract interface class ContentsSnapshotSync {
  /// Загрузить снимок сейчас.
  Future<Either<Failure, void>> refresh();

  /// Попросить загрузить вскоре: несколько подтверждений подряд дают одну загрузку.
  void requestRefresh();
}
