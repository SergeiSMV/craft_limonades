import 'picked_file.dart';

/// Заглушка выбора файла для VM (ADHOC-38): портал собирается только для Web, здесь её видят
/// лишь тесты, которые диалог выбора не открывают.
Future<PickedFile?> pickFileFromBrowser({required String accept}) =>
    throw UnsupportedError('Выбор файла доступен только в браузере');
