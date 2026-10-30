import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Вариант [PortalSelect]: значение и подпись.
typedef PortalSelectOption = ({String id, String label});

/// Фильтр списка в плоском стиле (ADHOC-56, фильтр Shopify Polaris): «Группа: Все ▾».
///
/// Что: кнопка с подписью фильтра и выбранным значением, по нажатию — меню вариантов.
/// Как: первым пунктом меню — «все» ([allLabel], значение `null`); выбранный пункт отмечен
///      галочкой. Длинный справочник (поставщики) прокручивается внутри меню. Пока фильтр
///      задан, кнопка выделена рамкой, — видно, что список сужен.
class PortalSelect extends StatelessWidget {
  const PortalSelect({
    super.key,
    required this.label,
    required this.allLabel,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  /// Подпись фильтра («Группа»).
  final String label;

  /// Подпись варианта «без фильтра» («Все»).
  final String allLabel;
  final List<PortalSelectOption> options;

  /// Выбранный вариант; `null` — без фильтра.
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Подпись выбранного варианта; вариант пропал из справочника — как «все».
  String get _valueLabel {
    for (final o in options) {
      if (o.id == value) return o.label;
    }
    return allLabel;
  }

  @override
  Widget build(BuildContext context) {
    final active = value != null;
    // Меню не шире экрана с полями: на телефоне 440 не влезло бы.
    final menuWidth = math.min(
      AppSizes.kPortalSelectMenuWidth,
      MediaQuery.sizeOf(context).width - AppSizes.kPortalSelectMenuMargin,
    );
    return MenuAnchor(
      style: MenuStyle(
        // Чуть темнее карточки и с заметной рамкой — меню не сливается с таблицей под ним.
        backgroundColor: const WidgetStatePropertyAll(AppColors.kPopoverBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        maximumSize: WidgetStatePropertyAll(
          Size(menuWidth, AppSizes.kPortalSelectMenuHeight),
        ),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: const WidgetStatePropertyAll(AppColors.kCardShadow),
        padding: const WidgetStatePropertyAll(AppInsets.v4),
        // Рамка задаётся отдельно от формы: иначе меню берёт свою, толстую тёмную.
        side: const WidgetStatePropertyAll(
          BorderSide(color: AppColors.kInputBorder),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppBorders.kCircular8),
        ),
      ),
      menuChildren: [
        _item(null, allLabel, menuWidth),
        for (final o in options) _item(o.id, o.label, menuWidth),
      ],
      builder: (context, controller, _) => SizedBox(
        height: AppSizes.kControlHeight,
        child: Material(
          color: AppColors.kCardBg,
          shape: RoundedRectangleBorder(
            borderRadius: AppBorders.kCircular8,
            side: BorderSide(
              color: active ? AppColors.kButtonPrimary : AppColors.kInputBorder,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            hoverColor: AppColors.kBg,
            child: Padding(
              padding: AppInsets.button,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$label: ',
                    style: RegularTextStyles().regularInter13.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                  // Длинное имя поставщика сокращается, а не выталкивает кнопку за край.
                  Flexible(
                    child: Text(
                      _valueLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SemiboldTextStyles().semiboldInter13.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                  ),
                  AppBoxes.kWidth4,
                  const Icon(
                    Icons.expand_more,
                    size: AppSizes.kIcon18,
                    color: AppColors.kTextMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Пункт меню; выбранный — с галочкой. Подпись не шире меню за вычетом отступов и галочки,
  /// длинная — переносится на вторую строку: иначе строка выходит за край меню и срезается.
  Widget _item(String? id, String text, double menuWidth) => MenuItemButton(
    onPressed: () => onChanged(id),
    style: MenuItemButton.styleFrom(
      minimumSize: const Size(0, AppSizes.kControlHeight),
      // Отступ сверху и снизу — двухстрочная подпись не липнет к соседним пунктам.
      padding: AppInsets.choice,
      overlayColor: AppColors.kTextMain,
      // Строка меню — в рост кнопки и на телефоне, без «пальцевых» 48.
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    trailingIcon: id == value
        ? const Icon(Icons.check, size: AppSizes.kIcon16)
        : null,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: menuWidth - AppSizes.kPortalSelectItemReserve,
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: RegularTextStyles().regularInter13.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
    ),
  );
}
