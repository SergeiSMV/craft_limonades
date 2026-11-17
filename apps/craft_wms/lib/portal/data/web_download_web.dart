import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Скачивает байты как файл в браузере (портал - Flutter Web, файловой системы нет).
///
/// Что: сохраняет [bytes] под именем [filename] через диалог загрузки браузера.
/// Зачем: PDF-этикетки приходят с бэкенда бинарём - их надо отдать пользователю файлом.
/// Как: Blob из байтов → временный object URL → скрытый `<a download>` → click → revoke URL.
void downloadBytes({
  required Uint8List bytes,
  required String filename,
  String mime = 'application/octet-stream',
}) {
  // Blob принимает JSArray частей; часть - типизированный массив байтов.
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  final url = web.URL.createObjectURL(blob);
  (web.document.createElement('a') as web.HTMLAnchorElement)
    ..href = url
    ..download = filename
    ..click();
  // Ссылку сразу освобождаем - файл к этому моменту уже сохранён/начал сохраняться.
  web.URL.revokeObjectURL(url);
}
