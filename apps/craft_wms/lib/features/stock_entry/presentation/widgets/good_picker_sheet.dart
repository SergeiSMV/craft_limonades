import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';

/// Нижний лист выбора товара из номенклатуры (поиск с дебаунсом).
class GoodPickerSheet extends StatefulWidget {
  const GoodPickerSheet({super.key, required this.repo});

  final CatalogRepository repo;

  @override
  State<GoodPickerSheet> createState() => _GoodPickerSheetState();
}

class _GoodPickerSheetState extends State<GoodPickerSheet> {
  Timer? _debounce;
  List<Good> _goods = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Загрузка товаров с сервера (с фильтром по названию/коду, если есть).
  Future<void> _load(String? query) async {
    setState(() => _loading = true);
    final res = await widget.repo.listGoods(query: query, limit: 50);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _goods = res.fold((_) => const [], (p) => p.items);
    });
  }

  /// Поиск с дебаунсом 350 мс: не дёргаем API на каждый символ.
  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _load(value.isEmpty ? null : value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding:
            AppInsets.all16 +
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.stockEntry.pickGood,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight12,
            TextField(
              autofocus: true,
              onChanged: _onSearch,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.stockEntry.searchGood,
                border: const OutlineInputBorder(
                  borderRadius: AppBorders.kCircular8,
                ),
                isDense: true,
              ),
            ),
            AppBoxes.kHeight12,
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: AppInsets.all16,
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _goods.isEmpty
                  ? Center(child: Text(t.stockEntry.nothingFound))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _goods.length,
                      itemBuilder: (context, i) {
                        final g = _goods[i];
                        return ListTile(
                          title: Text(
                            g.name,
                            style: RegularTextStyles().regularInter14,
                          ),
                          subtitle: Text(
                            [if (g.code != null) g.code!, g.uom].join(' · '),
                            style: RegularTextStyles().regularInter10.copyWith(
                              color: AppColors.kTextMuted,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(g),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
