import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/utils/date_input.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../movement/presentation/widgets/move_format.dart';
import '../../../domain/problem_models.dart';
import '../../../domain/resolved_problems.dart';
import '../problem_format.dart';

/// Подписи решённых проблем (ADHOC-34) для человека.
///
/// Каждый факт — своей строкой со своей подписью («Партия: …», «Количество: …», «Место: …»):
/// склеенная через «·» строка читается как одно поле.

/// Что решил офис — повелительно: «Списать», «Разместить в «Основной»», «Вернуть поставщику».
/// Незнакомое решение (новое на сервере) — как есть.
String decisionLabel(String decision) => switch (decision) {
  ProblemDecision.writeOff => t.problems.decisionWriteOff,
  ProblemDecision.place => t.problems.decisionPlace,
  ProblemDecision.supplierReturn => t.problems.decisionSupplierReturn,
  _ => decision,
};

/// Что сделано по решению — совершённым видом: «Списано», «Размещено в «Основной»»,
/// «Отгружено поставщику»; возврат, который склад ещё не отгрузил, — «Ждёт отгрузки».
String outcomeLabel(ResolvedProblem p) => switch (p.decision) {
  ProblemDecision.writeOff => t.problems.outcomeWriteOff,
  ProblemDecision.place => t.problems.outcomePlace,
  ProblemDecision.supplierReturn =>
    p.awaitingShipment ? t.problems.outcomeAwaiting : t.problems.outcomeShipped,
  _ => p.decision,
};

/// Подробности решения: у возврата — кому и каким заданием.
List<String> decisionLines(ResolvedProblem p) => [
  if (p.supplierName case final s?) t.problems.supplierLine(supplier: s),
  if (p.returnTaskNumber case final n?) t.problems.taskLine(number: n),
];

/// Подробности исполнения: у списания — документ 1С.
List<String> executionLines(ResolvedProblem p) => [
  if ((p.docNumber, p.docDate) case (final n?, final d?))
    t.problems.docLine(number: n, date: isoToDisplayDate(d)),
];

/// Кто и когда исполнил решение. Списание и размещение исполняет само «Провести» в портале —
/// решивший; возврат — тот, кто отгрузил на ТСД. Возврат не отгружен — `null`.
String? executedMeta(ResolvedProblem p) {
  if (p.decision == ProblemDecision.supplierReturn) {
    final at = p.shippedAt;
    return at == null
        ? null
        : t.problems.executedMeta(
            name: p.shippedBy ?? '',
            time: fullDateTime(at),
          );
  }
  return t.problems.executedMeta(
    name: p.resolvedBy,
    time: fullDateTime(p.resolvedAtTime),
  );
}

/// Причина по значению сервера; незнакомая — как есть.
String reasonLabelOf(String wire) {
  for (final r in ProblemReason.values) {
    if (r.wire == wire) return reasonLabel(r);
  }
  return wire;
}

/// Что помечали: короб целиком или товар.
String subjectLabel(ResolvedProblem p) {
  final box = p.loadUnitId;
  if (box != null) return t.problems.box(code: boxCode(box));
  return p.items.isEmpty ? '' : p.items.first.goodName;
}

/// Подробности предмета: у короба — сколько позиций; у товара — партия и количество (решение
/// могло взять товар из нескольких ячеек — количество суммарное).
List<String> subjectLines(ResolvedProblem p) {
  if (p.items.isEmpty) return const [];
  if (p.loadUnitId != null) {
    return [t.problems.positionsLine(count: p.items.length)];
  }
  var qty = 0.0;
  for (final it in p.items) {
    qty += double.tryParse(it.qty) ?? 0;
  }
  return [
    t.problems.batchLine(date: isoToDisplayDate(p.items.first.productionDate)),
    t.problems.qtyLine(qty: fmtQty((qty * 1000).roundToDouble() / 1000)),
  ];
}
