import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../bloc/goods_list_cubit.dart';

/// Виджет кнопка открытия листа фильтров с бейджем числа активных фильтров.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key});

  /// Открыть нижний лист фильтров. Cubit пробрасываем через .value — лист им управляет.
  void openFilters(BuildContext context) {
    final cubit = context.read<GoodsListCubit>();
    showModalBottomSheet<void>(
      backgroundColor: AppColors.kNeumorphicBg,
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _FilterSheet()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    // Склад пока не учитываем (ADR-0016) — только группа + поставщик.
    final count =
        (state.groupId != null ? 1 : 0) + (state.supplierId != null ? 1 : 0);

    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: NeumorphicButton(
        onPressed: () => openFilters(context),
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: -2,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        padding: AppInsets.all12,
        child: Icon(MdiIcons.filterVariant, color: AppColors.kSidebarHover),
      ),
    );
  }
}

/// Нижний лист фильтров: группа + поставщик (применяются сразу) + «Сбросить».
class _FilterSheet extends StatelessWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    return SafeArea(
      child: Padding(
        padding: AppInsets.all16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.stockListScreen.filtersTitle,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight16,
            _FilterDropdown(
              label: t.stockListScreen.filterGroup,
              // key по значению — чтобы после «Сбросить» дропдаун показал «Все».
              fieldKey: ValueKey('flt-group-${state.groupId}'),
              selectedId: state.groupId,
              options: [for (final g in state.groups) (id: g.id, name: g.name)],
              onSelected: cubit.setGroup,
            ),
            AppBoxes.kHeight12,
            _FilterDropdown(
              label: t.stockListScreen.filterSupplier,
              fieldKey: ValueKey('flt-supplier-${state.supplierId}'),
              selectedId: state.supplierId,
              options: [
                for (final s in state.suppliers) (id: s.id, name: s.name),
              ],
              onSelected: cubit.setSupplier,
            ),
            AppBoxes.kHeight16,
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: cubit.resetFilters,
                    child: Text(t.stockListScreen.reset),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.stockListScreen.done),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Выпадающий фильтр листа: подпись, вдавленное неоморфное поле и меню, где каждый
/// вариант — выпуклая неоморфная кнопка. Длинные названия групп/поставщиков переносятся
/// на следующую строку, а не обрезаются многоточием: варианты меню тянутся по высоте
/// (`itemHeight: null`), а в свёрнутом поле высота фиксированная — там строка одна.
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.fieldKey,
    required this.selectedId,
    required this.options,
    required this.onSelected,
  });

  /// Подпись над полем.
  final String label;

  /// Ключ поля: меняется вместе с выбранным значением, чтобы «Сбросить» вернул «Все».
  final Key fieldKey;

  /// Выбранный вариант; `null` — «Все».
  final String? selectedId;

  /// Варианты фильтра.
  final List<({String id, String name})> options;

  /// Применить выбранный фильтр.
  final ValueChanged<String?> onSelected;

  /// Выбрать вариант: закрыть меню дропдауна и применить фильтр.
  ///
  /// Контекст берём у самого пункта меню: он живёт в маршруте выпадающего списка, тогда как
  /// контекст листа закрыл бы весь нижний лист вместо меню.
  void select(BuildContext itemContext, String? id) {
    Navigator.of(itemContext).pop();
    onSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.left6,
          child: Text(
            label,
            style: RegularTextStyles().regularInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        Neumorphic(
          style: NeumorphicStyle(
            shadowLightColor: AppColors.kNeumorphicLight,
            shadowDarkColor: AppColors.kNeumorphicDark,
            intensity: 1,
            color: AppColors.kNeumorphicBg,
            depth: -2,
            shape: NeumorphicShape.flat,
          ),
          // Прозрачный focusColor гасит штатную тёмную подложку выбранного пункта:
          // Flutter подсвечивает его через `Ink(color: Theme.of(context).focusColor)`.
          // Тема захватывается вместе с меню (InheritedTheme.capture), поэтому доходит
          // до пунктов в маршруте выпадающего списка. Отметка выбора — красная точка.
          child: Theme(
            data: Theme.of(context).copyWith(focusColor: Colors.transparent),
            child: DropdownButtonFormField<String?>(
              key: fieldKey,
              initialValue: selectedId,
              isExpanded: true,
              // null — разрешает пункту быть выше одной строки (иначе жёсткие 48 px и обрезка).
              itemHeight: null,
              borderRadius: AppBorders.kCircular8,
              dropdownColor: AppColors.kNeumorphicBg,
              decoration: const InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: AppBorders.kCircular8,
                  borderSide: BorderSide.none,
                ),
                isDense: true,
              ),
              // В свёрнутом поле — обычный текст, а не кнопка: иначе внутри поля рисовалась бы
              // вторая неоморфная плашка.
              selectedItemBuilder: (_) => [
                _fieldLabel(t.stockListScreen.filterAll),
                for (final o in options) _fieldLabel(o.name),
              ],
              items: [
                _item(null, t.stockListScreen.filterAll),
                for (final o in options) _item(o.id, o.name),
              ],
              onChanged: onSelected,
            ),
          ),
        ),
      ],
    );
  }

  /// Название выбранного варианта в свёрнутом поле — одной строкой.
  Widget _fieldLabel(String name) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: RegularTextStyles().regularInter14,
      ),
    );
  }

  /// Вариант меню — неоморфная кнопка. Тап обрабатывает она сама: её `GestureDetector`
  /// перехватывает жест раньше `DropdownMenuItem`, поэтому штатный `onChanged` не сработал бы.
  DropdownMenuItem<String?> _item(String? id, String name) {
    return DropdownMenuItem<String?>(
      value: id,
      child: Builder(
        builder: (itemContext) => Padding(
          padding: AppInsets.v4,
          child: NeumorphicButton(
            onPressed: () => select(itemContext, id),
            style: NeumorphicStyle(
              shadowLightColor: AppColors.kNeumorphicLight,
              shadowDarkColor: AppColors.kNeumorphicDark,
              intensity: 1,
              color: AppColors.kNeumorphicBg,
              depth: 2,
              shape: NeumorphicShape.flat,
              boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
            ),
            padding: AppInsets.all8,
            child: Row(
              children: [
                Expanded(
                  // Без overflow-обрезки: длинное название переносится на следующую строку.
                  child: Text(name, style: RegularTextStyles().regularInter14),
                ),
                if (id == selectedId) ...[
                  AppBoxes.kWidth8,
                  const _SelectedDot(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Отметка выбранного варианта в меню фильтра — красная точка справа.
class _SelectedDot extends StatelessWidget {
  const _SelectedDot() : super(key: selectedDotKey);

  /// Ключ отметки — по нему её находит тест (класс приватный).
  static const Key selectedDotKey = Key('filter-selected-dot');

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSizes.kDotMark,
      height: AppSizes.kDotMark,
      decoration: const BoxDecoration(
        color: AppColors.kDanger,
        shape: BoxShape.circle,
      ),
    );
  }
}
