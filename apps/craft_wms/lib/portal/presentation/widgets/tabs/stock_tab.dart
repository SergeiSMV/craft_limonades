import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/utils/search_text.dart';
import '../../../../features/stock/data/catalog_api.dart';
import '../../../../features/stock/data/catalog_cache.dart';
import '../../../../features/stock/data/catalog_models.dart';
import '../../../data/warehouse_stock_repository.dart';
import '../nomenclature/good_card_dialog.dart';
import '../nomenclature/goods_list_card.dart';
import '../nomenclature/goods_toolbar.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_list_page.dart';
import '../ui/portal_select.dart';

/// Вкладка «Остатки склада» (ADHOC-56): товары, которые есть на складе, с количеством — как
/// «Остатки» на ТСД.
///
/// Что: поиск, фильтры по группе, поставщику и внутреннему складу; в строке — остаток на
///      выбранном складе (по умолчанию на всех); нажатие — карточка товара.
/// Как: остатки — из снимка склада ([WarehouseStockRepository]); поиск и фильтры отбирают их
///      в памяти, без сети. «Обновить» — свежий снимок; когда он снят, видно на панели.
///      Показ — страницами по 50, как в номенклатуре: сотни строк разом тормозили бы вёрстку.
class StockTab extends StatefulWidget {
  const StockTab({super.key});

  @override
  State<StockTab> createState() => _StockTabState();
}

class _StockTabState extends State<StockTab> {
  final _repo = getIt<WarehouseStockRepository>();
  final _catalog = getIt<CatalogApi>();
  final _search = TextEditingController();

  static const _page = 50;

  PortalStock? _stock;
  bool _loading = true;
  String? _error;

  List<NomenclatureGroup> _groups = const [];
  List<Supplier> _suppliers = const [];
  String? _groupId;
  String? _supplierId;
  String? _warehouseId;
  int _shown = _page;

  @override
  void initState() {
    super.initState();
    load();
    loadFilters();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Свежий снимок склада.
  Future<void> load() async {
    setState(() => _loading = true);
    final res = await _repo.load();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = _text(f), (s) {
        _stock = s;
        _error = null;
      });
    });
  }

  /// Справочники фильтров; не загрузились — фильтр без вариантов.
  Future<void> loadFilters() async {
    final groups = await _catalog.listGroups();
    final suppliers = await _catalog.listSuppliers();
    if (!mounted) return;
    setState(() {
      _groups = groups.fold((_) => const [], (g) => g);
      _suppliers = suppliers.fold((_) => const [], (s) => s);
    });
  }

  /// Поиск или фильтр сменился — список заново с первой страницы.
  void _refilter(VoidCallback change) => setState(() {
    change();
    _shown = _page;
  });

  /// Товары под поиск и фильтры с остатком на выбранном складе больше нуля.
  List<PortalStockGood> _filtered(PortalStock stock) {
    final words = searchWords(_search.text);
    final groupId = _groupId;
    final groups = groupId == null
        ? null
        : CatalogCache.descendantGroupIds(_groups, groupId).toSet();
    return [
      for (final s in stock.goods)
        if ((groups == null || groups.contains(s.good.groupId)) &&
            (_supplierId == null || s.good.supplierId == _supplierId) &&
            s.qtyOn(_warehouseId) > 0 &&
            words.every(
              normalizeSearchText(
                '${s.good.name} ${s.good.code ?? ''}',
              ).contains,
            ))
          s,
    ];
  }

  String _text(Failure f) => switch (f) {
    ServerFailure(:final message?) => message,
    ServerFailure(:final statusCode) => t.portal.goods.errorCode(
      code: statusCode,
    ),
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  @override
  Widget build(BuildContext context) {
    final stock = _stock;
    final found = stock == null ? const <PortalStockGood>[] : _filtered(stock);
    final qty = {for (final s in found) s.good.id: s.qtyOn(_warehouseId)};
    return PortalListPage(
      toolbar: GoodsToolbar(
        search: _search,
        onSearch: (_) => _refilter(() {}),
        groups: _groups,
        groupId: _groupId,
        onGroup: (id) => _refilter(() => _groupId = id),
        suppliers: _suppliers,
        supplierId: _supplierId,
        onSupplier: (id) => _refilter(() => _supplierId = id),
        trailing: [
          PortalSelect(
            label: t.portal.stock.warehouse,
            allLabel: t.portal.goods.all,
            options: [
              for (final w in stock?.warehouses ?? const [])
                (id: w.id, label: w.name),
            ],
            value: _warehouseId,
            onChanged: (id) => _refilter(() => _warehouseId = id),
          ),
          PortalButton(
            label: t.portal.stock.refresh,
            icon: Icons.refresh,
            busy: _loading && stock != null,
            onPressed: load,
          ),
          if (stock != null)
            Text(
              t.portal.stock.asOf(time: fullDateTime(stock.asOf.toLocal())),
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
        ],
      ),
      body: stock == null
          ? SettingsListCard(
              loading: _error == null,
              error: _error,
              rows: const [],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GoodsListCard(
                  goods: [for (final s in found.take(_shown)) s.good],
                  total: found.length,
                  loadingMore: false,
                  onMore: () => setState(() => _shown += _page),
                  onOpen: (good) =>
                      showGoodCardDialog(context, good, withPlaces: true),
                  qty: (g) => t.portal.stock.qty(
                    qty: fmtQty(qty[g.id] ?? 0),
                    uom: g.uom,
                  ),
                ),
                if (_error != null) ...[
                  AppBoxes.kHeight8,
                  AccessError(_error!),
                ],
              ],
            ),
    );
  }
}
