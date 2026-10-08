import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/theme/bold_text.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/notification_badge.dart';

/// Плитка главного меню ТСД: крупная цветная кнопка с иконкой, заголовком и подписью.
/// [enabled] = false — раздел-заглушка (визуально приглушён, тап показывает уведомление).
class MenuTile extends StatelessWidget {
  const MenuTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.imageIcon,
    required this.color,
    required this.onTap,
    this.enabled = true,
    this.showBadge = false,
    this.badgeCount,
  });

  /// заголовок
  final String title;

  /// подпись
  final String subtitle;

  /// цвет
  final Color color;

  /// callback при нажатии
  final VoidCallback onTap;

  /// enabled = false — раздел-заглушка (визуально приглушён, тап показывает уведомление).
  final bool enabled;

  /// PNG-иконка из ассетов (FlutterGen); если null — рисуем [icon].
  final AssetGenImage imageIcon;

  /// Показать пометку «требует внимания» в углу плитки.
  ///
  /// Пометка — часть плитки, а не обёртка снаружи: плитка занимает всю ячейку сетки, и кружок,
  /// подвешенный поверх неё извне, уезжал в зазор между плитками и висел в воздухе. Заодно
  /// пометку теперь можно включить любой плитке — их ждут задания, приёмка и подбор.
  final bool showBadge;

  /// Число в пометке («сколько ждёт»). Больше нуля — пометка показывается с числом.
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    final tile = _tile();
    final count = badgeCount ?? 0;
    if (!showBadge && count <= 0) return tile;
    return Stack(
      // ⚠ Без expand плитка получила бы СВОБОДНЫЕ констрейнты и сжалась по содержимому, а
      // стопка осталась бы во всю ячейку сетки — пометка легла бы в пустоту справа от плитки.
      // Ровно так и выглядел первый заход: кружок висел в зазоре между плитками.
      fit: StackFit.expand,
      children: [
        // Плитка первой и без Positioned, пометка ложится ВНУТРЬ её границ — за скруглённый
        // угол не вылезает и в зазор сетки не уходит.
        tile,
        Positioned(
          top: AppSizes.kIcon6,
          right: AppSizes.kIcon6,
          child: NotificationBadge(count: count > 0 ? count : null),
        ),
      ],
    );
  }

  /// Ключ крашеного прямоугольника плитки.
  ///
  /// Нужен тесту: он проверяет, что пометка лежит внутри ГРАНИЦ ПЛИТКИ, а не внутри стопки.
  /// Стопка занимает всю ячейку сетки всегда, и по ней дефект «плитка сжалась по содержимому»
  /// не виден — именно так первая версия теста и пропустила его.
  @visibleForTesting
  static const Key surfaceKey = ValueKey('menu_tile_surface');

  /// Сама плитка без пометки.
  Widget _tile() {
    return Container(
      key: surfaceKey,
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppBorders.kCircular12,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppBorders.kCircular12,
        child: Padding(
          padding: AppInsets.h8 + AppInsets.top4,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              imageIcon.image(height: AppSizes.kIcon85),
              AppBoxes.kHeight8,
              Text(
                title,
                textAlign: TextAlign.center,
                style: BoldTextStyles().boldInter16.copyWith(
                  color: AppColors.kTileText,
                ),
              ),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RegularTextStyles().regularInter11.copyWith(
                  height: 1.1,
                  color: AppColors.kTileText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
