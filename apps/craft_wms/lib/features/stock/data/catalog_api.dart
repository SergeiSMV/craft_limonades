import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import 'catalog_models.dart';

/// Сетевой источник справочников и остатков: ходит на `/goods`, `/nomenclature-groups`,
/// `/suppliers`, `/cells`, `/barcodes`, `/stock` (API P1-06, P-FS-03/12, P2-02) и возвращает
/// `Either<Failure, T>`. Access-токен подставит AuthInterceptor.
///
/// Экраны сюда не обращаются: между ними и сетью стоит `CatalogRepository`, который сначала
/// смотрит в локальный кэш (P2-02). Отдельный класс нужен, чтобы «откуда данные» и «как их
/// достать по сети» не смешивались в одном файле.
@lazySingleton
class CatalogApi {
  CatalogApi(this._dio);

  final Dio _dio;

  /// Список/поиск товаров с пагинацией и фильтрами. Пустые фильтры не шлём (nil = без фильтра).
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.goods,
        queryParameters: _compact({
          'q': query,
          'group_id': groupId,
          'supplier_id': supplierId,
          'limit': limit,
          'offset': offset,
        }),
      );
      return Right(Paged.fromJson(resp.data!, Good.fromJson));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Товар по штрихкоду (P-FS-16): скан в строке поиска «Остатков» открывает карточку товара.
  /// ШК уникален (`barcodes.barcode UNIQUE`), поэтому ответ — ровно один товар.
  /// ШК не привязан (404) → `Right(null)`: это не ошибка, а сигнал «показать обычный поиск».
  Future<Either<Failure, Good?>> resolveGoodByBarcode(String code) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.barcodeByCode(code),
      );
      return Right(Good.fromJson(resp.data!));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const Right(null);
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Штрихкоды товара (секция «Штрихкоды» в карточке, P-FS-12). Пустой список — норма.
  /// Выдать товару внутренний штрихкод (P4-07).
  ///
  /// Только по сети: код обязан быть уникален во всей системе, а терминал без связи этого
  /// гарантировать не может — заранее выданных ему диапазонов номеров нет (решение P4-09).
  Future<Either<Failure, IssuedBarcode>> issueInternalBarcode(
    String goodId,
  ) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.goodInternalBarcode(goodId),
      );
      final data = resp.data!;
      return Right(
        IssuedBarcode(
          barcode: data['barcode'] as String,
          symbology: data['symbology'] as String?,
          generated: data['generated'] as bool? ?? true,
        ),
      );
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId) async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.goodBarcodes(goodId));
      final items = (resp.data ?? const [])
          .map((e) => Barcode.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Все группы номенклатуры (клиент строит дерево / список фильтра).
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups() async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.nomenclatureGroups);
      final items = (resp.data ?? const [])
          .map((e) => NomenclatureGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Поставщики (для фильтра). Опциональный поиск по подстроке имени.
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query}) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        ApiConst.suppliers,
        queryParameters: _compact({'q': query}),
      );
      final items = (resp.data ?? const [])
          .map((e) => Supplier.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Список/поиск ячеек (по адресу). Нужен вводу остатков: резолв ячейки по скану/выбору.
  Future<Either<Failure, Paged<Cell>>> listCells({
    String? query,
    String? warehouseId,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.cells,
        queryParameters: _compact({
          'q': query,
          'warehouse_id': warehouseId,
          'limit': limit,
          'offset': offset,
        }),
      );
      return Right(Paged.fromJson(resp.data!, Cell.fromJson));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Все ячейки склада разом. Пагинирует внутри по `maxLimit` бэкенда (200): читает страницы,
  /// пока не наберёт `total`. Используется синхронизацией кэша; экраны берут ячейки из кэша.
  Future<Either<Failure, List<Cell>>> listAllCells({
    String? warehouseId,
  }) async {
    const pageSize = 200; // = maxLimit read-API (catalog.go)
    final all = <Cell>[];
    var offset = 0;
    while (true) {
      final res = await listCells(
        warehouseId: warehouseId,
        limit: pageSize,
        offset: offset,
      );
      if (res.isLeft) return Left(res.left);
      final page = res.right;
      all.addAll(page.items);
      offset += page.items.length;
      // Дошли до конца: набрали total или сервер вернул пустую страницу (страховка от зацикливания).
      if (all.length >= page.total || page.items.isEmpty) break;
    }
    return Right(all);
  }

  /// Все товары разом — для наполнения кэша (P2-02). Пагинирует внутри по `maxLimit`.
  Future<Either<Failure, List<Good>>> listAllGoods() async {
    const pageSize = 200; // = maxLimit read-API
    final all = <Good>[];
    var offset = 0;
    while (true) {
      final res = await listGoods(limit: pageSize, offset: offset);
      if (res.isLeft) return Left(res.left);
      final page = res.right;
      all.addAll(page.items);
      offset += page.items.length;
      if (all.length >= page.total || page.items.isEmpty) break;
    }
    return Right(all);
  }

  /// Все привязки ШК разом — справочник для офлайн-кэша (`GET /barcodes`, P2-02).
  /// Пагинирует внутри так же, как ячейки: страницами по `maxLimit`, пока не наберётся `total`.
  Future<Either<Failure, List<BarcodeLink>>> listAllBarcodes() async {
    const pageSize = 200; // = maxLimit read-API
    final all = <BarcodeLink>[];
    var offset = 0;
    while (true) {
      try {
        final resp = await _dio.get<Map<String, dynamic>>(
          ApiConst.barcodes,
          queryParameters: {'limit': pageSize, 'offset': offset},
        );
        final page = Paged.fromJson(resp.data!, BarcodeLink.fromJson);
        all.addAll(page.items);
        offset += page.items.length;
        if (all.length >= page.total || page.items.isEmpty) break;
      } on DioException catch (e) {
        return Left(_mapError(e));
      } catch (_) {
        return const Left(Failure.unknown());
      }
    }
    return Right(all);
  }

  /// Выкидывает null-значения из query — чтобы пустые фильтры не уходили в URL.
  Map<String, dynamic> _compact(Map<String, dynamic> params) {
    params.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
    return params;
  }

  /// Перевод ошибки dio в доменную Failure — общее правило для всех репозиториев
  /// (`core/error/dio_failure.dart`): своё в каждом репозитории уже разошлось однажды.
  Failure _mapError(DioException e) => mapDioError(e);
}
