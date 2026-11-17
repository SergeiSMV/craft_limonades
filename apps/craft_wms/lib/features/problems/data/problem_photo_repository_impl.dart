import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/database/app_database.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../../../core/sync/sync_engine.dart';
import '../domain/problem_photos.dart';

/// Очередь фото проблем (ADHOC-45): снимки лежат в локальной базе, пока сервер их не принял.
///
/// Когда грузить: сразу после постановки и после каждого прохода очереди операций - к этому
/// моменту проблема, к которой снимок относится, уже на сервере. Порядок - по времени съёмки.
/// Исходы загрузки:
/// - принят (в том числе повтор) - снимок удаляется из очереди;
/// - проблемы на сервере ещё нет (404) - снимок ждёт: её операция не дошла;
/// - связи нет - проход останавливается до следующего;
/// - отказ по существу (решение уже принято, три фото, не снимок) - снимок удаляется, причина
///   уходит в журнал: повтор её не исправит.
///
/// Ленивый, как остальные репозитории: регистрация зависимостей общая с порталом, а в вебе
/// локальной базы нет - созданный при старте, он ронял бы портал. Запускает очередь
/// приложение ТСД после входа ([upload]); с этого момента она подписана на проходы очереди.
@LazySingleton(as: ProblemPhotoRepository)
class ProblemPhotoRepositoryImpl implements ProblemPhotoRepository {
  ProblemPhotoRepositoryImpl(this._db, this._dio, this._engine, this._talker) {
    // После прохода очереди операций - догрузить снимки: проблема к ним уже на сервере.
    _engine.syncing.addListener(_onSyncing);
  }

  final AppDatabase _db;
  final Dio _dio;
  final SyncEngine _engine;
  final Talker _talker;

  /// Загрузка уже идёт - второй проход отправил бы тот же снимок дважды.
  bool _uploading = false;

  /// Во время прохода в очередь легли новые снимки - пройти её ещё раз, а не ждать события.
  bool _again = false;

  void _onSyncing() {
    if (!_engine.syncing.value) upload();
  }

  @override
  Future<void> enqueue(String problemId, List<ProblemPhotoShot> shots) async {
    if (shots.isEmpty) return;
    // Время съёмки - порядок загрузки; снимки одной партии разводятся на миллисекунду, чтобы
    // на сервере легли в том порядке, в каком их сняли.
    final now = DateTime.now();
    await _db.batch((b) {
      for (final (i, s) in shots.indexed) {
        b.insert(
          _db.problemPhotoUploads,
          ProblemPhotoUploadsCompanion.insert(
            id: s.id,
            problemId: problemId,
            content: s.content,
            createdAt: now.add(Duration(milliseconds: i)),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
    await upload();
  }

  @override
  Future<List<PendingProblemPhoto>> pendingOf(String problemId) async {
    final rows =
        await (_db.select(_db.problemPhotoUploads)
              ..where((t) => t.problemId.equals(problemId))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return [for (final r in rows) _toPending(r)];
  }

  @override
  Stream<int> watchPendingCount() {
    final count = _db.problemPhotoUploads.id.count();
    return (_db.selectOnly(
      _db.problemPhotoUploads,
    )..addColumns([count])).watchSingle().map((row) => row.read(count) ?? 0);
  }

  @override
  Future<Either<Failure, Uint8List>> fetch({
    required String problemId,
    required String photoId,
  }) async {
    try {
      final resp = await _dio.get<List<int>>(
        ApiConst.problemPhoto(problemId, photoId),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = resp.data;
      if (data == null) return const Left(Failure.unknown());
      return Right(Uint8List.fromList(data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Пройти очередь снимков по порядку съёмки. Снимки проблемы, которой на сервере ещё нет,
  /// пропускаются до следующего прохода; без связи проход останавливается.
  @override
  Future<void> upload() async {
    if (_uploading) {
      _again = true;
      return;
    }
    _uploading = true;
    try {
      do {
        _again = false;
        if (!await _pass()) return;
      } while (_again);
    } finally {
      _uploading = false;
    }
  }

  /// Один проход очереди. `false` - связи нет, дальше не идём.
  Future<bool> _pass() async {
    final rows = await (_db.select(
      _db.problemPhotoUploads,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();
    final waiting = <String>{}; // проблемы, которых сервер ещё не знает
    for (final r in rows) {
      if (waiting.contains(r.problemId)) continue;
      final outcome = await _put(r);
      switch (outcome) {
        case _Put.done || _Put.rejected:
          await (_db.delete(
            _db.problemPhotoUploads,
          )..where((t) => t.id.equals(r.id))).go();
        case _Put.noProblem:
          waiting.add(r.problemId);
        case _Put.offline:
          return false;
      }
    }
    return true;
  }

  /// Загрузить один снимок и разобрать исход.
  Future<_Put> _put(ProblemPhotoUpload r) async {
    try {
      await _dio.put<void>(
        ApiConst.problemPhoto(r.problemId, r.id),
        data: r.content,
        options: Options(
          contentType: 'image/jpeg',
          headers: {Headers.contentLengthHeader: r.content.length},
        ),
      );
      return _Put.done;
    } on DioException catch (e) {
      final f = mapDioError(e);
      return switch (f) {
        ServerFailure(statusCode: 404) => _Put.noProblem,
        ServerFailure(:final statusCode, :final message)
            when statusCode >= 400 && statusCode < 500 =>
          _reject(r, message ?? '$statusCode'),
        _ => _Put.offline,
      };
    }
  }

  /// Отказ по существу: снимок из очереди убирается, причина - в журнал.
  _Put _reject(ProblemPhotoUpload r, String reason) {
    _talker.warning(
      'Фото ${r.id} проблемы ${r.problemId} отклонено сервером: $reason',
    );
    return _Put.rejected;
  }

  PendingProblemPhoto _toPending(ProblemPhotoUpload r) =>
      PendingProblemPhoto(id: r.id, problemId: r.problemId, content: r.content);
}

/// Исход загрузки одного снимка.
enum _Put { done, rejected, noProblem, offline }
