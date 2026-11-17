/// Коды «Честного знака» на скане (CZ-04): марка в DataMatrix и код транспортного короба
/// в GS1-128.
///
/// Разбор нужен классификации: марку надо отличить от текста поиска, а код короба -
/// от штрихкода товара (оба - сплошные цифры). Сервер приводит код к ключу ЧЗ сам, поэтому
/// на сервер уходит скан как есть; здесь - только «что это за код».
library;

/// Разделитель групп GS1 (`0x1D`): после КИ в марке идёт криптохвост. В Dart `trim()` его
/// не срезает (в отличие от Kotlin на стороне моста), поэтому по краям срезаем явно.
const _gs = '\u001d';

/// Префикс AIM, если сканер приклеивает его к данным: `]d2` - GS1 DataMatrix, `]C1` - GS1-128.
final _aimPrefix = RegExp(r'^\][A-Za-z][0-9A-Za-z]');

/// Код короба: `00` + SSCC (18 цифр). Без `00` True API короб не находит (CZ-01).
final _czBox = RegExp(r'^00\d{18}$');

/// КИ марки или групповой упаковки: `01` + GTIN (14 цифр) + `21` + серийный номер.
final _czMark = RegExp(r'^01\d{14}21.+$');

/// Код ЧЗ из скана: без пробелов и GS по краям, без префикса AIM и без криптохвоста.
String _czKey(String raw) {
  var code = raw.trim();
  code = _trimGs(code).replaceFirst(_aimPrefix, '');
  code = _trimGs(code);
  final gs = code.indexOf(_gs);
  return gs < 0 ? code : code.substring(0, gs);
}

String _trimGs(String s) {
  var start = 0, end = s.length;
  while (start < end && s[start] == _gs) {
    start++;
  }
  while (end > start && s[end - 1] == _gs) {
    end--;
  }
  return s.substring(start, end);
}

/// КИ марки (или групповой упаковки - что именно, скажет ЧЗ), если скан - марка; иначе `null`.
String? czMarkFrom(String raw) {
  final key = _czKey(raw);
  return _czMark.hasMatch(key) ? key : null;
}

/// Код короба `00`+SSCC, если скан - код транспортного короба ЧЗ; иначе `null`.
String? czBoxFrom(String raw) {
  final key = _czKey(raw);
  return _czBox.hasMatch(key) ? key : null;
}
