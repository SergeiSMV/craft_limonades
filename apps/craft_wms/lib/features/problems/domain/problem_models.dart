/// Проблемы склада на ТСД (P6-07-2): пометка короба или товара браком, изолятором …
///
/// Слой `domain` фичи: ни Flutter, ни сети, ни базы.
library;

/// Причина проблемы — фиксированный список (решение 2026-10-14), как на сервере.
enum ProblemReason {
  /// Бой.
  breakage('breakage'),

  /// Порча.
  spoilage('spoilage'),

  /// Просрок.
  expired('expired'),

  /// Не наша марка ЧЗ.
  foreignMark('foreign_mark'),

  /// Прочее — комментарий обязателен.
  other('other');

  const ProblemReason(this.wire);

  /// Как значение уходит на сервер.
  final String wire;
}
