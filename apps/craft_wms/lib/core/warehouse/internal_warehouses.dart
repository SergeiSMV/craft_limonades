import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../constants/api_constants.dart';
import '../database/app_database.dart';
import '../error/dio_failure.dart';
import '../error/failure.dart';

/// Внутренний склад (ADR-0016): «Основной», «Брак», «Изолятор» … Метка короба или товара,
/// а не место — товар с меткой лежит в той же ячейке (P6-07-1).
class InternalWarehouse {
  const InternalWarehouse({
    required this.id,
    required this.code,
    required this.name,
    required this.isDefault,
    this.isActive = true,
  });

  final String id;
  final String code;
  final String name;

  /// Склад по умолчанию («Основной»): на ТСД товар этого склада идёт без метки.
  final bool isDefault;

  /// В выборе (ADHOC-29): скрытым складом не помечают, но его остаток подписывается.
  final bool isActive;
}

/// Справочник внутренних складов на терминале (P6-07-2).
///
/// Что: склады с сервера (`GET /internal-warehouses`) в локальной базе — для выбора, куда
/// пометить товар, и для подписи «Брак» / «Изолятор» на экранах, в том числе без связи.
/// Соглашение терминала: склад по умолчанию в сущностях — `null`. Сервер всегда шлёт id
/// склада, своя очередь до P6-07-1 — нет; приводятся к одному виду через [normalize].
@lazySingleton
class InternalWarehouses {
  InternalWarehouses(this._dio, this._db);

  final Dio _dio;
  final AppDatabase _db;

  /// Прочитанный справочник — склады меняются редко, а подпись нужна на каждой строке.
  List<InternalWarehouse>? _memo;

  /// Перечитать справочник с сервера.
  ///
  /// Сервер без этой ручки (до P6-07-1) отвечает 404 — справочник тогда просто остаётся
  /// прежним: старый сервер брака не знает, и подписывать на терминале нечего.
  Future<Either<Failure, void>> refresh() async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.internalWarehouses);
      final items = [
        for (final e in resp.data ?? const [])
          InternalWarehouse(
            id: (e as Map<String, dynamic>)['id'] as String,
            code: e['code'] as String? ?? '',
            name: e['name'] as String? ?? '',
            isDefault: e['is_default'] as bool? ?? false,
            isActive: e['is_active'] as bool? ?? true,
          ),
      ];
      await _db.transaction(() async {
        await _db.delete(_db.cachedInternalWarehouses).go();
        await _db.batch(
          (b) => b.insertAll(_db.cachedInternalWarehouses, [
            for (final w in items)
              CachedInternalWarehousesCompanion.insert(
                id: w.id,
                code: w.code,
                name: w.name,
                isDefault: Value(w.isDefault),
                isActive: Value(w.isActive),
              ),
          ]),
        );
      });
      _memo = items;
      return const Right(null);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const Right(null);
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Все склады: по умолчанию первым, дальше по имени — как отдаёт сервер.
  Future<List<InternalWarehouse>> all() async {
    final memo = _memo;
    if (memo != null) return memo;
    final rows = await _db.select(_db.cachedInternalWarehouses).get();
    final items =
        [
          for (final r in rows)
            InternalWarehouse(
              id: r.id,
              code: r.code,
              name: r.name,
              isDefault: r.isDefault,
              isActive: r.isActive,
            ),
        ]..sort(
          (a, b) => a.isDefault != b.isDefault
              ? (a.isDefault ? -1 : 1)
              : a.name.compareTo(b.name),
        );
    return _memo = items;
  }

  /// Id склада по умолчанию; `null` — справочник ещё не загружен.
  Future<String?> defaultId() async {
    for (final w in await all()) {
      if (w.isDefault) return w.id;
    }
    return null;
  }

  /// Привести id склада к соглашению терминала: склад по умолчанию и пустое значение — `null`.
  static String? normalize(String? id, String? defaultId) =>
      id == null || id.isEmpty || id == defaultId ? null : id;
}
