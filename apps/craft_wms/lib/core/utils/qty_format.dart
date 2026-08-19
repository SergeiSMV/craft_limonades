/// Формат количества: целое без дробной части, иначе — с точкой без хвостовых нулей.
/// (`10.0` → «10», `10.500` → «10.5»).
String fmtQty(double q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  return q.toString();
}
