import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Контракт демо-сервера для портала (ADHOC-67). Реализация — `data`.
abstract interface class DemoRepository {
  /// Сервер — демо: портал показывает вход одной кнопкой и раздел «Демо» в настройках.
  /// Нет ответа или сервер рабочий — `false`.
  Future<bool> isDemoServer();

  /// Вернуть демо-данные к исходным: база стирается и заполняется заново, все сеансы демо
  /// закрываются. Не чаще раза в 10 минут — иначе отказ сервера текстом.
  Future<Either<Failure, void>> reset();
}
