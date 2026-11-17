import 'dart:typed_data';

/// Выбранный в браузере файл: имя + содержимое.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}
