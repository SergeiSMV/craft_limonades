import 'package:flutter/services.dart';

/// Маска ввода даты `дд.мм.гг(гг)`: пользователь набирает только цифры, точки-разделители
/// ставятся автоматически (после дня и месяца). До 8 цифр — год можно ввести 2 или 4 знаками
/// (`140826` → `14.08.26`, `14082026` → `14.08.2026`). Курсор — в конец.
class DateTextInputFormatter extends TextInputFormatter {
  /// Переформатирует ввод на каждый keystroke: оставляет цифры (до 8) и авто-проставляет точки
  /// после дня и месяца; курсор — в конец.
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

/// Двузначный год → 20YY; четырёхзначный — как есть.
int _fullYear(String raw) => raw.length == 2 ? 2000 + int.parse(raw) : int.parse(raw);

/// Проверка даты `дд.мм.гг` или `дд.мм.гггг`: и по форме, и по существованию (31.02 → невалидна).
/// Двузначный год трактуется как 20YY.
bool isValidEntryDate(String s) {
  final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{2}|\d{4})$').firstMatch(s);
  if (m == null) return false;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final y = _fullYear(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1) return false;
  final dt = DateTime(y, mo, d);
  // Если день «перекрутился» (напр. 31.02 → 03.03), компоненты не совпадут — дата невалидна.
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// Нормализация даты к `дд.мм.гггг` (двузначный год → 20YY). Вход должен пройти [isValidEntryDate];
/// иначе возвращается без изменений.
String normalizeEntryDate(String s) {
  final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{2}|\d{4})$').firstMatch(s);
  if (m == null) return s;
  return '${m.group(1)}.${m.group(2)}.${_fullYear(m.group(3)!)}';
}

/// Дата из API (ISO `ГГГГ-ММ-ДД`, возможно с временем) → отображаемая `дд.мм.гггг`.
/// Неожиданный формат возвращается как есть — на экране лучше «сырая» дата, чем пусто.
String isoToDisplayDate(String iso) {
  final date = iso.length >= 10 ? iso.substring(0, 10) : iso;
  final p = date.split('-');
  if (p.length == 3 && p[0].length == 4) return '${p[2]}.${p[1]}.${p[0]}';
  return iso;
}
