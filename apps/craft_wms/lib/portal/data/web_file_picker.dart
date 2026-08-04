import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Выбранный в браузере файл: имя + содержимое.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Открывает системный диалог выбора файла и возвращает имя + байты (или null, если отменили).
///
/// Что: веб-замена file_picker без плагина (тот конфликтует с talker по версии win32).
/// Зачем: портал — Flutter Web, файла на диске нет — читаем байты в браузере (FileReader).
/// Как: создаём скрытый `<input type=file>`, по change читаем первый файл в ArrayBuffer.
/// [accept] — фильтр диалога, напр. `.xls`.
Future<PickedFile?> pickFileFromBrowser({required String accept}) {
  final completer = Completer<PickedFile?>();

  final input = (web.document.createElement('input') as web.HTMLInputElement)
    ..type = 'file'
    ..accept = accept;

  input.onchange = (web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      completer.complete(null);
      return;
    }
    final file = files.item(0)!;

    final reader = web.FileReader();
    reader.onload = (web.Event _) {
      final buffer = (reader.result as JSArrayBuffer).toDart;
      completer.complete(PickedFile(name: file.name, bytes: buffer.asUint8List()));
    }.toJS;
    reader.onerror = ((web.Event _) => completer.completeError('file read error')).toJS;
    reader.readAsArrayBuffer(file);
  }.toJS;

  input.click();
  return completer.future;
}
