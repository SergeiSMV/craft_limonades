import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';

/// Нижний лист выбора ячейки (поиск по адресу).
class CellPickerSheet extends StatefulWidget {
  const CellPickerSheet({super.key, required this.repo});

  final CatalogRepository repo;

  @override
  State<CellPickerSheet> createState() => _CellPickerSheetState();
}

class _CellPickerSheetState extends State<CellPickerSheet> {
  Timer? _debounce;
  List<Cell> _cells = const [];
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

  /// Загрузка ячеек с сервера (с фильтром по адресу, если есть).
  Future<void> _load(String? query) async {
    setState(() => _loading = true);
    final res = await widget.repo.listCells(query: query, limit: 50);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _cells = res.fold((_) => const [], (p) => p.items);
    });
  }

  /// Поиск с дебаунсом 350 мс: не дёргаем API на каждый символ адреса.
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
              t.stockEntry.pickCell,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight12,
            TextField(
              autofocus: true,
              onChanged: _onSearch,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t.stockEntry.cellHint,
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
                  : _cells.isEmpty
                  ? Center(child: Text(t.stockEntry.nothingFound))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _cells.length,
                      itemBuilder: (context, i) {
                        final c = _cells[i];
                        return ListTile(
                          leading: c.isFloor
                              ? const Icon(Icons.south)
                              : const Icon(Icons.grid_view),
                          title: Text(
                            c.address,
                            style: RegularTextStyles().regularInter14,
                          ),
                          onTap: () => Navigator.of(context).pop(c),
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
