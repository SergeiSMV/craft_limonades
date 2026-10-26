import 'dart:async';

import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../domain/cell_count_check.dart';

/// Проверка ячейки на подсчёт через сервер (ADHOC-48).
///
/// Ожидание короткое и общее — и соединения, и ответа: кладовщик стоит со сканером у ячейки,
/// и при плохой связи лучше пропустить предупреждение (сервер собьёт подсчёт сам), чем
/// держать скан десять секунд. Подтверждённые подсчёты помнятся до перезапуска приложения —
/// по ячейке и началу подсчёта: повторный скан той же ячейки в сеансе не спрашивает снова,
/// а новый подсчёт той же ячейки — спрашивает.
@LazySingleton(as: CellCountCheck)
class CellCountCheckImpl implements CellCountCheck {
  CellCountCheckImpl(this._dio);

  final Dio _dio;

  static const _timeout = Duration(seconds: 3);

  final Set<String> _confirmed = {};

  @override
  Future<CellUnderCount?> counting(String cellId) async {
    try {
      final resp = await _dio
          .get<Object?>(ApiConst.cellStocktakeCount(cellId))
          .timeout(_timeout);
      final data = (resp.data as Map<String, dynamic>?)?['counting'];
      if (data is! Map<String, dynamic>) return null;
      final count = CellUnderCount.fromJson(data);
      return _confirmed.contains(_key(cellId, count)) ? null : count;
    } catch (_) {
      // Нет связи, таймаут, старый сервер без ручки — предупреждать не о чем.
      return null;
    }
  }

  @override
  void confirmed(String cellId, CellUnderCount count) =>
      _confirmed.add(_key(cellId, count));

  String _key(String cellId, CellUnderCount count) =>
      '$cellId|${count.startedAt}';
}
