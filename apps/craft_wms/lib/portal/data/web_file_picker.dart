/// Выбор файла в портале — развилка по платформе (ADHOC-38).
///
/// Что: в браузере — системный диалог ([web_file_picker_web.dart]), на VM — заглушка.
/// Зачем: как у скачивания — реализация на `package:web` не собирается на VM и закрывала
///        вкладкам с загрузкой файлов обычные тесты (долг 25).
/// Как: условный экспорт; модель [PickedFile] общая для обеих сторон.
library;

export 'picked_file.dart';
export 'web_file_picker_stub.dart'
    if (dart.library.js_interop) 'web_file_picker_web.dart';
