import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../../stock/domain/catalog_repository.dart';
import '../bloc/receipt_cubit.dart';
import 'supplier_doc_dialog.dart';

/// Первый шаг приёмки - поставщик.
///
/// Список из локального справочника: поставщика выбирают у машины, где связи может не быть.
/// «Без поставщика» стоит первым пунктом, а не прячется: внутреннее поступление и возврат -
/// обычные случаи, а выдуманный «прочий поставщик» всплыл бы в отчёте как настоящий.
class SupplierSelectView extends StatefulWidget {
  const SupplierSelectView({super.key});

  @override
  State<SupplierSelectView> createState() => _SupplierSelectViewState();
}

class _SupplierSelectViewState extends State<SupplierSelectView> {
  final _repo = getIt<CatalogRepository>();
  final _controller = TextEditingController();

  List<Supplier> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Загрузить справочник поставщиков целиком: их немного, фильтр - в памяти.
  Future<void> _load() async {
    final res = await _repo.listSuppliers();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _all = res.fold((_) => const [], (s) => s);
    });
    if (res.isLeft) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.receipt.suppliersLoadFailed)));
    }
  }

  /// Поставщики под набранный текст.
  List<Supplier> get _filtered {
    final q = _controller.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((s) => s.name.toLowerCase().contains(q)).toList();
  }

  /// Начать приёмку от выбранного поставщика (`null` - без поставщика).
  ///
  /// Сначала - документ поставщика (ADHOC-23): без него приёмка не начинается. Отмена окна
  /// оставляет на выборе поставщика.
  ///
  /// Клавиатуру поиска убираем ДО перехода (ADHOC-18): иначе она остаётся на рабочем экране,
  /// где не нужна вовсе - поле скана её не вызывает, - и съедает половину высоты. На DT50S
  /// подсказка пустого списка переполнялась под ней на 37 точек.
  Future<void> _choose(Supplier? supplier) async {
    dismissKeyboard();
    final cubit = context.read<ReceiptCubit>();
    final doc = await showSupplierDocDialog(context);
    if (doc == null) return;
    dismissKeyboard();
    await cubit.start(supplier, doc);
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBoxes.kHeight16,
        Padding(
          padding: AppInsets.h8,
          child: Text(
            t.receipt.supplierPrompt,
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        AppBoxes.kHeight8,
        _searchField(),
        AppBoxes.kHeight12,
        Padding(
          padding: AppInsets.h8,
          child: _SupplierTile(
            title: t.receipt.noSupplier,
            subtitle: t.receipt.noSupplierHint,
            onTap: () => _choose(null),
          ),
        ),
        // AppBoxes.kHeight8,
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Center(child: Text(t.receipt.nothingFound))
              : ListView.builder(
                  padding: AppInsets.bottom16 + AppInsets.h8 + AppInsets.top8,
                  itemCount: items.length,
                  itemBuilder: (context, i) => _SupplierTile(
                    title: items[i].name,
                    onTap: () => _choose(items[i]),
                  ),
                ),
        ),
      ],
    );
  }

  /// Вдавленное поле поиска - как поле адреса в «Вводе остатков».
  Widget _searchField() => Padding(
    padding: AppInsets.h8,
    child: Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: -2,
        shape: NeumorphicShape.flat,
      ),
      child: TextField(
        controller: _controller,
        cursorColor: AppColors.kTextMuted,
        decoration: InputDecoration(
          prefixIcon: Icon(
            MdiIcons.magnify,
            size: AppSizes.kIcon25,
            color: AppColors.kTextMuted,
          ),
          hintText: t.receipt.supplierSearchHint,
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
    ),
  );
}

/// Плитка поставщика - выпуклая, как плитки ячеек в «Вводе остатков».
class _SupplierTile extends StatelessWidget {
  const _SupplierTile({
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.bottom8,
      child: NeumorphicButton(
        onPressed: onTap,
        padding: AppInsets.all12,
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: 3,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kSidebarHover,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: RegularTextStyles().regularInter12.copyWith(
                  color: AppColors.kTextMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
