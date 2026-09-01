import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/failure.dart';
import 'catalog_models.dart';

/// Репозиторий чтения справочников: ходит на `/goods`, `/nomenclature-groups`,
/// `/suppliers`, `/stock` (API P1-06) и возвращает `Either<Failure, T>`.
/// Слой data — изолирует сеть от домена/UI; access-токен подставит AuthInterceptor.
@lazySingleton
class CatalogRepository {
  CatalogRepository(this._dio);

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

  /// Привязать ШК к товару (P-FS-17). Бэкенд идемпотентен: повторная привязка того же кода к тому
  /// же товару — не ошибка. `symbology` не знаем (код мог прийти сканом или руками) — шлём пустой,
  /// как и поток ввода остатков. Конфликт «ШК уже за другим товаром» приходит как 409
  /// (`Failure.server(409)`) — вызывающий отличает его от прочих ошибок по коду.
  Future<Either<Failure, void>> bindBarcode({
    required String goodId,
    required String barcode,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        ApiConst.barcodes,
        data: {'good_id': goodId, 'barcode': barcode, 'symbology': ''},
      );
      return const Right(null);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Отвязать ШК от товара (коррекция ошибочной привязки, P-FS-12). DELETE идемпотентен (204).
  Future<Either<Failure, void>> unbindBarcode(String code) async {
    try {
      await _dio.delete<void>(ApiConst.barcodeByCode(code));
      return const Right(null);
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

  /// Все ячейки склада разом (справочник мал — ~700; грузим целиком под локальный автокомплит ввода
  /// остатков). Пагинирует внутри по `maxLimit` бэкенда (200): читает страницы, пока не наберёт `total`.
  /// В P2 (offline-first) станет чтением из локального стора — сигнатура вызова не изменится.
  Future<Either<Failure, List<Cell>>> listAllCells({String? warehouseId}) async {
    const pageSize = 200; // = maxLimit read-API (catalog.go)
    final all = <Cell>[];
    var offset = 0;
    while (true) {
      final res = await listCells(warehouseId: warehouseId, limit: pageSize, offset: offset);
      if (res.isLeft) return Left(res.left);
      final page = res.right;
      all.addAll(page.items);
      offset += page.items.length;
      // Дошли до конца: набрали total или сервер вернул пустую страницу (страховка от зацикливания).
      if (all.length >= page.total || page.items.isEmpty) break;
    }
    return Right(all);
  }

  /// Остатки товара в разрезе ячеек/партий (карточка «где лежит товар X»).
  Future<Either<Failure, Paged<StockItem>>> listStock({
    String? goodId,
    String? cellId,
    int limit = 200,
    int offset = 0,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.stock,
        queryParameters: _compact({
          'good_id': goodId,
          'cell_id': cellId,
          'limit': limit,
          'offset': offset,
        }),
      );
      return Right(Paged.fromJson(resp.data!, StockItem.fromJson));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Выкидывает null-значения из query — чтобы пустые фильтры не уходили в URL.
  Map<String, dynamic> _compact(Map<String, dynamic> params) {
    params.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
    return params;
  }

  /// Маппинг ошибок dio в доменные Failure (что показать — решает cubit).
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) {
      return const Failure.auth();
    }
    if (code != null) {
      return Failure.server(code);
    }
    return const Failure.network();
  }
}
