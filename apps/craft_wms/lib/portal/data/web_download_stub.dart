import 'dart:typed_data';

/// Заглушка скачивания для VM (ADHOC-38): портал собирается только для Web, здесь её видят
/// лишь тесты, которые кнопку скачивания не нажимают.
void downloadBytes({
  required Uint8List bytes,
  required String filename,
  String mime = 'application/octet-stream',
}) => throw UnsupportedError('Скачивание файла доступно только в браузере');
