import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:injectable/injectable.dart';

import '../domain/problem_photos.dart';

/// Снимок штатной камерой терминала (ADHOC-45) через `image_picker`.
///
/// Сжатие — здесь, на ТСД: снимок 13 Мп весит мегабайты, а для разбора брака хватает 1600 px.
/// Пакет сам уменьшает и перекодирует в JPEG; итог — 200–400 КБ, сервер принимает до 1 МБ.
@LazySingleton(as: PhotoCamera)
class CameraPhoto implements PhotoCamera {
  CameraPhoto() : _picker = ImagePicker();

  final ImagePicker _picker;

  /// Сторона снимка и качество JPEG: разбор брака видит этикетку и повреждение, а снимок
  /// остаётся в пределе сервера.
  static const double _maxSide = 1600;
  static const int _quality = 75;

  @override
  Future<Uint8List?> take() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
    );
    return file?.readAsBytes();
  }
}
