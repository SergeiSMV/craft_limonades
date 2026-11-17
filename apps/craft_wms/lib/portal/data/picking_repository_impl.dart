import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/picking/registry_repository.dart';

/// Сборка-отгрузка в портале (P8-02): предпросмотр и загрузка «Реестра» 1С.
/// Слой data: изолирует HTTP от UI, отдаёт `Either<Failure, RegistryPreview>`.
@LazySingleton(as: PickingRepository)
class PickingRepositoryImpl implements PickingRepository {
  PickingRepositoryImpl(this._dio);

  final Dio _dio;

  /// Предпросмотр: сервер разбирает файл и сверяет с заказами той же даты, ничего не записывая.
  @override
  Future<Either<Failure, RegistryPreview>> preview({
    required List<int> bytes,
    required String filename,
  }) => _send(ApiConst.pickingRegistryPreview, bytes, filename);

  /// Загрузка после подтверждения: тот же файл, сверка повторяется по свежему состоянию.
  @override
  Future<Either<Failure, RegistryPreview>> load({
    required List<int> bytes,
    required String filename,
  }) => _send(ApiConst.pickingRegistryLoad, bytes, filename);

  Future<Either<Failure, RegistryPreview>> _send(
    String path,
    List<int> bytes,
    String filename,
  ) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final resp = await _dio.post<Map<String, dynamic>>(path, data: form);
      return Right(RegistryPreview.fromJson(resp.data!));
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      // 422 - файл не принят (нет листа или колонки, несколько дат): текст сервера показываем.
      final msg = (e.response?.data is Map)
          ? (e.response!.data['error'] as String?)
          : null;
      return Left(Failure.server(code, code == 422 ? msg : null));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
