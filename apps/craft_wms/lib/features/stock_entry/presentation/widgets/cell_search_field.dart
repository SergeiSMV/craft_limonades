import 'package:flutter/services.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../stock/data/catalog_models.dart';

/// Неоморф-поле адреса ячейки с инлайн-автокомплитом (локальная prefix-фильтрация по [cells]).
/// Переиспользуется на экране выбора ячейки и в листе смены ячейки. [onPicked] — тап по варианту из
/// выпадашки; [onSubmit] — сырой ввод/скан + Enter (резолв адреса — на стороне вызывающего).
class CellSearchField extends StatefulWidget {
  const CellSearchField({
    super.key,
    required this.cells,
    required this.onPicked,
    required this.onSubmit,
    this.autofocus = true,
    this.loading = false,
  });

  final List<Cell> cells;
  final void Function(Cell) onPicked;
  final void Function(String) onSubmit;
  final bool autofocus;
  final bool loading; // крутилка в суффиксе, пока грузится справочник

  @override
  State<CellSearchField> createState() => _CellSearchFieldState();
}

class _CellSearchFieldState extends State<CellSearchField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Cell>(
      textEditingController: _controller,
      focusNode: _focusNode,
      displayStringForOption: (c) => c.address,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<Cell>.empty();
        return widget.cells.where((c) => c.address.toLowerCase().startsWith(q));
      },
      onSelected: (cell) {
        _controller.clear();
        widget.onPicked(cell);
      },
      fieldViewBuilder: (context, controller, focusNode, _) =>
          _field(controller, focusNode),
      optionsViewBuilder: (context, onSelected, options) =>
          _options(context, onSelected, options),
    );
  }

  /// Неоморф-поле (вдавленное); ввод сканером/руками, submit → [CellSearchField.onSubmit].
  Widget _field(TextEditingController controller, FocusNode focusNode) {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: -2,
        shape: NeumorphicShape.flat,
      ),
      child: TextField(
        cursorColor: AppColors.kTextMuted,
        cursorWidth: 1.5,
        cursorHeight: 20,
        controller: controller,
        focusNode: focusNode,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.done,
        // Если клавиатуру свернули, поле сохраняет фокус — Flutter не переоткрывает её по тапу
        // (фокус не менялся). Принудительно показываем клавиатуру снова.
        onTap: () {
          if (focusNode.hasFocus) {
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          }
        },
        onSubmitted: widget.onSubmit,
        decoration: InputDecoration(
          prefixIcon: Icon(
            MdiIcons.barcode,
            size: AppSizes.kIcon25,
            color: AppColors.kTextMuted,
          ),
          suffixIconConstraints: const BoxConstraints(
            maxWidth: AppSizes.kIcon36,
            maxHeight: AppSizes.kIcon16,
          ),
          suffixIcon: widget.loading
              ? Padding(
                  padding: AppInsets.right20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.kTextMuted,
                  ),
                )
              : null,
          hintText: t.stockEntry.cellHint,
          hintStyle: RegularTextStyles().regularInter16.copyWith(
            color: AppColors.kBorderDashed,
          ),
          border: const OutlineInputBorder(
            borderRadius: AppBorders.kCircular8,
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
      ),
    );
  }

  /// Выпадающий список подходящих ячеек под полем — приподнятая неоморф-поверхность (как карточки
  /// «Остатков»); ширина во всю доступную, высота ограничена. `Material(transparency)` — чтобы у
  /// `ListTile` был ink-таргет, а фон/тень давал неоморфизм.
  Widget _options(
    BuildContext context,
    void Function(Cell) onSelected,
    Iterable<Cell> options,
  ) {
    final width =
        MediaQuery.of(context).size.width -
        AppSizes.kIcon16; // за вычетом паддинга h8×2
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: AppSizes.kIcon256,
          maxWidth: width,
        ),
        child: Material(
          color: AppColors.kNeumorphicBg,
          // type: MaterialType.transparency,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, i) {
              final c = options.elementAt(i);
              return Padding(
                padding: AppInsets.all8,
                child: Neumorphic(
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                    boxShape: NeumorphicBoxShape.roundRect(
                      BorderRadius.circular(8),
                    ),
                  ),
                  child: ListTile(
                    dense: true,
                    title: Row(
                      children: [
                        Text(
                          c.address,
                          style: RegularTextStyles().regularInter14,
                        ),
                        AppBoxes.kWidth8,
                        if (c.isFloor)
                          Icon(
                            MdiIcons.arrowDownBold,
                            size: AppSizes.kIcon20,
                            color: AppColors.kTextMuted,
                          ),
                      ],
                    ),
                    onTap: () => onSelected(c),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
