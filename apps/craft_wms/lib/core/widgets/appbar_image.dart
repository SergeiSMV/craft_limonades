import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../gen/assets.gen.dart';

/// Виджет изображения в шапке экрана (AppBar) с закруглёнными нижними углами.
class AppbarImage extends StatelessWidget {
  const AppbarImage({super.key, required this.image});

  /// Изображение
  final AssetGenImage image;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.only(
        bottomLeft: Radius.circular(10),
        bottomRight: Radius.circular(10),
      ),
      child: image.image(
        width: double.infinity,
        fit: BoxFit.cover,
        height: AppSizes.kIcon140,
      ),
    );
  }
}
