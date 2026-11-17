import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../constants/api_constants.dart';
import '../database/app_database.dart';
import '../error/dio_failure.dart';
import '../error/failure.dart';
import '../gen/strings.g.dart';

/// Коды причин, на которые опирается программа (ADHOC-55): остальные причины заводит офис в
/// справочнике портала, у них код выдаёт сервер.
abstract final class ProblemReasonCodes {
  /// Не наша марка ЧЗ - при пометке на ТСД просит скан марки.
  static const foreignMark = 'foreign_mark';
  static const retired = 'retired';
  static const notFound = 'not_found';
  static const regrade = 'regrade';
  static const other = 'other';
}

/// Название причины, заведённой миграцией, по коду - пока справочника на терминале ещё нет
/// (до первой синхронизации) или у старого сервера; незнакомый код - `null`.
String? fallbackReasonName(String code) => switch (code) {
  'breakage' => t.problems.reasonBreakage,
  'spoilage' => t.problems.reasonSpoilage,
  'expired' => t.problems.reasonExpired,
  ProblemReasonCodes.foreignMark => t.problems.reasonForeignMark,
  ProblemReasonCodes.retired => t.problems.reasonRetired,
  ProblemReasonCodes.notFound => t.problems.reasonNotFound,
  ProblemReasonCodes.regrade => t.problems.reasonRegrade,
  ProblemReasonCodes.other => t.problems.reasonOther,
  _ => null,
};

/// Причины на выбор, пока справочника на терминале нет: прежний список (решение 2026-10-14) -
/// кладовщик может помечать и до первой синхронизации.
List<ProblemReason> fallbackProblemReasons() => [
  for (final code in const [
    'breakage',
    'spoilage',
    'expired',
    ProblemReasonCodes.foreignMark,
    ProblemReasonCodes.other,
  ])
    ProblemReason(
      code: code,
      name: fallbackReasonName(code)!,
      commentRequired: code == ProblemReasonCodes.other,
    ),
];

/// Причина проблемы склада из справочника (ADHOC-55).
class ProblemReason {
  const ProblemReason({
    required this.code,
    required this.name,
    this.isSystem = false,
    this.manual = true,
    this.commentRequired = false,
    this.isActive = true,
    this.resolutions = const [],
  });

  factory ProblemReason.fromJson(Map<String, dynamic> j) => ProblemReason(
    code: j['code'] as String,
    name: j['name'] as String? ?? '',
    isSystem: j['is_system'] as bool? ?? false,
    manual: j['manual'] as bool? ?? true,
    commentRequired: j['comment_required'] as bool? ?? false,
    isActive: j['is_active'] as bool? ?? true,
    resolutions: [
      for (final id in j['resolutions'] as List<dynamic>? ?? const [])
        id as String,
    ],
  );

  final String code;
  final String name;

  /// Заводит программа: не выключается, в портале - только название и варианты.
  final bool isSystem;

  /// Кладовщик выбирает её на ТСД; `false` - ставит только программа.
  final bool manual;

  /// Без комментария пометка не уходит.
  final bool commentRequired;

  /// В выборе; неактивной не помечают, но старые проблемы ею подписаны.
  final bool isActive;

  /// Id допустимых вариантов решения, в порядке справочника вариантов.
  final List<String> resolutions;

  /// Кладовщик может выбрать её при пометке сейчас.
  bool get selectable => manual && isActive;
}

/// Вариант решения проблемы (ADHOC-55): название для офиса и действие кода.
class ResolutionVariant {
  const ResolutionVariant({
    required this.id,
    required this.name,
    required this.action,
    this.isActive = true,
  });

  factory ResolutionVariant.fromJson(Map<String, dynamic> j) =>
      ResolutionVariant(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        action: j['action'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? true,
      );

  final String id;
  final String name;

  /// Что программа делает с товаром: `write_off`, `place`, `supplier_return`, `regrade`.
  final String action;
  final bool isActive;
}

/// Справочник причин на терминале (ADHOC-55).
///
/// Что: причины с сервера (`GET /problem-reasons`) в локальной базе - для выбора причины при
/// пометке и для подписи проблем, в том числе без связи. Варианты решения терминалу не нужны:
/// решает офис.
@lazySingleton
class ProblemReasons {
  ProblemReasons(this._dio, this._db);

  final Dio _dio;
  final AppDatabase _db;

  /// Прочитанный справочник - меняется редко, а подпись нужна на каждой проблеме.
  List<ProblemReason>? _memo;

  /// Перечитать справочник с сервера. Сервер без этой ручки (до ADHOC-55) отвечает 404 -
  /// справочник тогда остаётся прежним.
  Future<Either<Failure, void>> refresh() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.problemReasons,
      );
      final items = [
        for (final e in resp.data?['reasons'] as List<dynamic>? ?? const [])
          ProblemReason.fromJson(e as Map<String, dynamic>),
      ];
      await _db.transaction(() async {
        await _db.delete(_db.cachedProblemReasons).go();
        await _db.batch(
          (b) => b.insertAll(_db.cachedProblemReasons, [
            for (final (i, r) in items.indexed)
              CachedProblemReasonsCompanion.insert(
                code: r.code,
                name: r.name,
                ord: i,
                manual: Value(r.manual),
                commentRequired: Value(r.commentRequired),
                isActive: Value(r.isActive),
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

  /// Все причины, и неактивные, в порядке справочника. Справочника ещё нет - прежний список
  /// ([fallbackProblemReasons]); он не запоминается: следующая синхронизация принесёт настоящий.
  Future<List<ProblemReason>> all() async {
    final memo = _memo;
    if (memo != null) return memo;
    final rows = await (_db.select(
      _db.cachedProblemReasons,
    )..orderBy([(t) => OrderingTerm(expression: t.ord)])).get();
    if (rows.isEmpty) return fallbackProblemReasons();
    return _memo = [
      for (final r in rows)
        ProblemReason(
          code: r.code,
          name: r.name,
          manual: r.manual,
          commentRequired: r.commentRequired,
          isActive: r.isActive,
        ),
    ];
  }
}
