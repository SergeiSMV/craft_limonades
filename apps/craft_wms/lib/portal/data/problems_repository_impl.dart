import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/problems/problems_repository.dart';

/// «Проблемы склада» в портале (P6-07-3): рабочий список и решение офиса - только admin.
///
/// Отказ по существу (решение недоступно, товар проблемы ушёл со склада-метки, уже решено)
/// сервер объясняет текстом в поле `error` - он приезжает в `ServerFailure.message`.
@LazySingleton(as: ProblemsRepository)
class ProblemsRepositoryImpl implements ProblemsRepository {
  ProblemsRepositoryImpl(this._dio);

  final Dio _dio;

  /// Все проблемы: открытые сверху, свежие первыми.
  @override
  Future<Either<Failure, List<PortalProblem>>> list() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.problems);
    return [
      for (final e in resp.data ?? const [])
        PortalProblem.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Снимок к проблеме (ADHOC-45) как есть - для миниатюры и просмотра.
  @override
  Future<Either<Failure, Uint8List>> photo(String problemId, String photoId) =>
      _call(() async {
        final resp = await _dio.get<List<int>>(
          ApiConst.problemPhoto(problemId, photoId),
          options: Options(responseType: ResponseType.bytes),
        );
        return Uint8List.fromList(resp.data ?? const []);
      });

  /// Справочник поставщиков - выбор, кому возвращать.
  @override
  Future<Either<Failure, List<PortalSupplier>>> suppliers() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.suppliers);
    return [
      for (final e in resp.data ?? const [])
        PortalSupplier.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// «Провести» решение по проблеме. Поля чужого вида не отправляются.
  @override
  Future<Either<Failure, void>> resolve(String id, ProblemResolution r) =>
      _call(
        () => _dio.post<void>(
          ApiConst.problemResolve(id),
          data: {
            'resolution_id': r.resolutionId,
            'decision': r.decision,
            if (ProblemDecision.withDoc(r.decision)) ...{
              'doc_number': r.docNumber,
              'doc_date': r.docDate,
            },
            if (r.decision == ProblemDecision.supplierReturn)
              'supplier_id': r.supplierId,
          },
        ),
      );

  Future<Either<Failure, T>> _call<T>(Future<T> Function() run) async {
    try {
      return Right(await run());
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      final data = e.response?.data;
      final message = data is Map ? data['error'] as String? : null;
      return Left(Failure.server(code, message));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
