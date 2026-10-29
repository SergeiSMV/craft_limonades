import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/utils/date_input.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/doc_number.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../movement/presentation/widgets/move_format.dart';
import '../../../domain/problem_models.dart';
import '../../../domain/problem_records.dart';
import '../problem_format.dart';

/// Подписи проблем склада в списках «Текущие» и «Завершённые» (ADHOC-34, ADHOC-35).
///
/// Каждый факт — своей строкой со своей подписью («Партия: …», «Количество: …», «Место: …»):
/// склеенная через «·» строка читается как одно поле.

/// Что решил офис — повелительно: «Списать», «Разместить в «Основной»», «Вернуть поставщику».
/// Незнакомое решение (новое на сервере) — как есть.
String decisionLabel(String decision) => switch (decision) {
  ProblemDecision.writeOff => t.problems.decisionWriteOff,
  ProblemDecision.place => t.problems.decisionPlace,
  ProblemDecision.supplierReturn => t.problems.decisionSupplierReturn,
  ProblemDecision.regrade => t.problems.decisionRegrade,
  _ => decision,
};

/// Что сделано по решению — совершённым видом: «Списано», «Размещено в «Основной»»,
/// «Отгружено поставщику»; возврат, который склад ещё не отгрузил, — «Ждёт отгрузки».
///
/// У открытой — где она сейчас: «Ожидает отправки» (своя, сервер о ней не знает) или «Ждёт
/// решения офиса».
String outcomeLabel(ProblemRecord p) => switch (p.decision) {
  _ when p.pending => t.problems.pendingSend,
  '' => t.problems.awaitingDecision,
  ProblemDecision.writeOff => t.problems.outcomeWriteOff,
  ProblemDecision.place => t.problems.outcomePlace,
  ProblemDecision.supplierReturn =>
    p.awaitingShipment ? t.problems.outcomeAwaiting : t.problems.outcomeShipped,
  ProblemDecision.regrade => t.problems.outcomeRegrade,
  _ => p.decision,
};

/// Подробности решения: у возврата — кому и каким заданием.
List<String> decisionLines(ProblemRecord p) => [
  if (p.supplierName case final s?) t.problems.supplierLine(supplier: s),
  if (p.returnTaskNumber case final n?) t.problems.taskLine(number: n),
];

/// Подробности исполнения: у списания — документ 1С.
List<String> executionLines(ProblemRecord p) => [
  if ((p.docNumber, p.docDate) case (final n?, final d?))
    t.problems.docLine(number: n, date: isoToDisplayDate(d)),
];

/// Кто и когда зафиксировал: своя неотправленная — «на этом терминале».
String createdMeta(ProblemRecord p) => p.pending
    ? t.problems.createdMetaPending(time: fullDateTime(p.createdAt))
    : t.problems.createdMeta(
        name: p.createdBy,
        time: fullDateTime(p.createdAt),
      );

/// Кто и когда исполнил решение. Списание и размещение исполняет само «Провести» в портале —
/// решивший; возврат — тот, кто отгрузил на ТСД. Возврат не отгружен — `null`.
String? executedMeta(ProblemRecord p) {
  if (p.isOpen) return null;
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

/// Номер проблемы: «Проблема ПБ-000009»; своя неотправленная номера ещё не имеет (ADHOC-55).
String numberLabel(ProblemRecord p) => switch (p.number) {
  final n? => t.problems.numberLine(number: docNumber(DocKind.problem, n)),
  null => t.problems.numberPending,
};

/// Причина по значению сервера; незнакомая — как есть.
String reasonLabelOf(String wire) {
  for (final r in ProblemReason.values) {
    if (r.wire == wire) return reasonLabel(r);
  }
  return wire;
}

/// Что помечали: короб целиком или товар.
String subjectLabel(ProblemRecord p) {
  final box = p.loadUnitId;
  if (box != null) return t.problems.box(code: boxCode(box));
  return p.items.isEmpty ? '' : p.items.first.goodName;
}

/// Подробности предмета: у короба — сколько позиций; у товара — партия и количество (решение
/// могло взять товар из нескольких ячеек — количество суммарное).
List<String> subjectLines(ProblemRecord p) {
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
