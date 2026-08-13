import 'package:flutter/services.dart';

/// Маска ввода даты `дд.мм.гггг`: пользователь набирает только цифры, точки-разделители
/// ставятся автоматически (после дня и месяца). Максимум 8 цифр. Курсор — в конец.
class DateTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // Оставляем только цифры и режем до 8 (ддммгггг).
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 8) digits = digits.substring(0, 8);

    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 2 || i == 4) buf.write('.'); // точки после дня и месяца
      buf.write(digits[i]);
    }
    final text = buf.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Проверка даты в формате `дд.мм.гггг`: и по форме, и по существованию (31.02 → невалидна).
bool isValidEntryDate(String s) {
  if (!RegExp(r'^\d{2}\.\d{2}\.\d{4}$').hasMatch(s)) return false;
  final p = s.split('.');
  final d = int.parse(p[0]);
  final m = int.parse(p[1]);
  final y = int.parse(p[2]);
  if (m < 1 || m > 12 || d < 1) return false;
  final dt = DateTime(y, m, d);
  // Если день «перекрутился» (напр. 31.02 → 03.03), компоненты не совпадут — дата невалидна.
  return dt.year == y && dt.month == m && dt.day == d;
}
