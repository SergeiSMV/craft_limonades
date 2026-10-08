import 'dart:async';

import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../../core/error/failure.dart';
import '../domain/contents_repository.dart';
import 'contents_api.dart';
import 'contents_cache.dart';

/// Загрузка снимка содержимого склада в кэш терминала (P5-05).
///
/// Когда: вместе со справочниками (вход, «Обновить») и после того, как очередь подтвердила
/// свою приёмку или размещение — иначе без связи терминал показывал бы старое место короба,
/// который сам же и перенёс.
@LazySingleton(as: ContentsSnapshotSync)
class ContentsSnapshotSyncImpl implements ContentsSnapshotSync {
  ContentsSnapshotSyncImpl(this._api, this._cache, this._talker);

  final ContentsApi _api;
  final ContentsCache _cache;
  final Talker _talker;

  /// Пауза перед загрузкой по просьбе. Очередь подтверждает операции пачкой, и загрузка на
  /// каждое подтверждение качала бы весь склад несколько раз подряд.
  static const _debounce = Duration(seconds: 2);

  Timer? _timer;

  /// Идущая загрузка: параллельная вторая только удвоила бы трафик.
  Future<Either<Failure, void>>? _inFlight;

  @override
  Future<Either<Failure, void>> refresh() =>
      _inFlight ??= _load().whenComplete(() => _inFlight = null);

  @override
  void requestRefresh() {
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(refresh()));
  }

  Future<Either<Failure, void>> _load() async {
    final started = DateTime.now();
    final res = await _api.snapshot();
    if (res.isLeft) {
      _talker.warning('Снимок содержимого склада не загружен: ${res.left}');
      return Left(res.left);
    }
    await _cache.replace(res.right);
    _talker.info(
      'Снимок содержимого склада за '
      '${DateTime.now().difference(started).inMilliseconds} мс: '
      'коробов ${res.right.loadUnits.length}, строк россыпи ${res.right.loose.length}',
    );
    return const Right(null);
  }
}
