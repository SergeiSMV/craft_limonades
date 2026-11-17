/// Формат полезной нагрузки QR-ярлыка грузовой единицы (P4-04).
///
/// Что: `CWLU<версия>:<uuid>` - например `CWLU1:550e8400-e29b-41d4-a716-446655440000`.
/// Зачем: ГЕ должна опознаваться **по содержимому кода**, а не по символике. QR универсален, им
/// кодируют что угодно - на живой проверке DT50S им оказалась ссылка на домофон, и приложение
/// назвало её грузовой единицей (долг 7).
/// Как: короткий признак принадлежности лежит в самих данных. Голый UUID для этого не годится:
/// он подходит под форму адреса ячейки (сегменты из букв и цифр через дефис), и различать их
/// пришлось бы порядком проверок - той самой хрупкостью, от которой уходим. Двоеточия в алфавите
/// адреса ячейки нет, поэтому столкновение исключено конструкцией.
///
/// Версия в префиксе даёт сменить схему, не обесценив уже наклеенные ярлыки: код, встретив
/// незнакомую версию, честно скажет «ярлык новее, чем я понимаю», а не «неизвестный код».
library;

/// Схема ярлыка - Craft WMS Load Unit.
const String kLoadUnitScheme = 'CWLU';

/// Версия формата, которую печатает и понимает это приложение.
const int kLoadUnitFormatVersion = 1;

/// Форма полезной нагрузки: схема, версия, двоеточие, UUID в каноническом виде.
///
/// ⚠ Версия UUID (v4) намеренно НЕ закрепляется: какую версию генерировать - дело
/// [LoadUnitIdGenerator], а не читателя. Пин в разборе сломал бы переход, например, на v7,
/// причём на уже наклеенных ярлыках.
final RegExp _payload = RegExp(
  '^$kLoadUnitScheme'
  r'(\d{1,3}):'
  r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
  caseSensitive: false,
);

/// Полезная нагрузка ярлыка для печати: [id] - идентификатор ГЕ, выданный устройством.
///
/// UUID приводится к нижнему регистру: на сервер уезжает он же, и два написания одного
/// идентификатора выглядели бы в отчётах как две разные ГЕ.
String encodeLoadUnitPayload(String id) =>
    '$kLoadUnitScheme$kLoadUnitFormatVersion:${id.trim().toLowerCase()}';

/// Что оказалось в отсканированном коде с точки зрения грузовой единицы.
sealed class LoadUnitPayload {
  const LoadUnitPayload();
}

/// Ярлык ГЕ прочитан. [id] - чистый UUID: именно он уезжает на сервер, без префикса.
/// Префикс - свойство этикетки, и в `load_units.id` ему делать нечего.
final class LoadUnitPayloadId extends LoadUnitPayload {
  const LoadUnitPayloadId(this.id);

  final String id;

  @override
  bool operator ==(Object other) =>
      other is LoadUnitPayloadId && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LoadUnitPayloadId($id)';
}

/// Ярлык наш, но версия схемы новее той, что понимает приложение.
///
/// Отдельный случай, а не «чужой код»: кладовщик держит в руках исправную этикетку, и сказать
/// ему «код не распознан» значило бы отправить искать несуществующую поломку. Правильный ответ -
/// обновить приложение.
final class LoadUnitPayloadUnsupported extends LoadUnitPayload {
  const LoadUnitPayloadUnsupported(this.version);

  final int version;

  @override
  bool operator ==(Object other) =>
      other is LoadUnitPayloadUnsupported && other.version == version;

  @override
  int get hashCode => version.hashCode;

  @override
  String toString() => 'LoadUnitPayloadUnsupported($version)';
}

/// Код к грузовым единицам отношения не имеет - товар, ячейка или вовсе чужая этикетка.
final class LoadUnitPayloadForeign extends LoadUnitPayload {
  const LoadUnitPayloadForeign();

  @override
  bool operator ==(Object other) => other is LoadUnitPayloadForeign;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'LoadUnitPayloadForeign()';
}

/// Разбирает отсканированный код как ярлык ГЕ.
LoadUnitPayload readLoadUnitPayload(String raw) {
  final match = _payload.firstMatch(raw.trim());
  if (match == null) return const LoadUnitPayloadForeign();
  final version = int.tryParse(match.group(1)!);
  if (version != kLoadUnitFormatVersion) {
    // Версия распарсилась, но она не наша. `null` сюда не попадёт - в группе только цифры,
    // и их не больше трёх, но подстраховка дешевле разбирательства на складе.
    return LoadUnitPayloadUnsupported(version ?? 0);
  }
  return LoadUnitPayloadId(match.group(2)!.toLowerCase());
}

/// Идентификатор ГЕ из кода, либо `null` - если код не наш или версия не поддержана.
/// Короткая форма для мест, где причина отказа не нужна.
String? loadUnitIdFrom(String raw) => switch (readLoadUnitPayload(raw)) {
  LoadUnitPayloadId(:final id) => id,
  _ => null,
};
