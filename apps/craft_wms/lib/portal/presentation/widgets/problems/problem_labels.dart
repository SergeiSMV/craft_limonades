import '../../../../core/gen/strings.g.dart';
import '../../../data/problems_repository.dart';

/// Подписи значений транспорта «Проблем склада» (P6-07-3).

/// Причина проблемы — как её выбрал кладовщик на ТСД.
String reasonLabel(String reason) => switch (reason) {
  'breakage' => t.portal.problems.reasonBreakage,
  'spoilage' => t.portal.problems.reasonSpoilage,
  'expired' => t.portal.problems.reasonExpired,
  'foreign_mark' => t.portal.problems.reasonForeignMark,
  'retired' => t.portal.problems.reasonRetired,
  'not_found' => t.portal.problems.reasonNotFound,
  'other' => t.portal.problems.reasonOther,
  _ => reason,
};

/// Решение офиса — подпись варианта в диалоге.
String decisionLabel(String decision) => switch (decision) {
  ProblemDecision.writeOff => t.portal.problems.decisionWriteOff,
  ProblemDecision.place => t.portal.problems.decisionPlace,
  ProblemDecision.supplierReturn => t.portal.problems.decisionSupplierReturn,
  _ => decision,
};

/// ISO-дата `YYYY-MM-DD` в привычную «21.10.2026».
String isoToRu(String iso) {
  final parts = iso.split('-');
  return parts.length == 3 ? '${parts[2]}.${parts[1]}.${parts[0]}' : iso;
}
