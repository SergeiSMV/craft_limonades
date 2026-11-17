import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../domain/catalog/portal_catalog_repository.dart';
import '../../../../features/stock/domain/catalog_models.dart';
import '../nomenclature/good_card_dialog.dart';
import '../nomenclature/goods_list_card.dart';
import '../nomenclature/goods_toolbar.dart';
import '../nomenclature/import_goods_dialog.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_list_page.dart';

/// Вкладка «Номенклатура склада» (ADHOC-56): весь справочник товаров - и те, которых на складе
/// нет, как «Номенклатура» на ТСД.
///
/// Что: поиск по наименованию и коду, фильтры по группе и поставщику, список страницами по 50
/// с «Показать ещё»; загрузка из 1С - кнопкой на панели (по праву загрузки).
/// Как: читает сервер напрямую (`PortalCatalogRepository`, без кэша ТСД). Поиск применяется после паузы в
/// наборе; ответ на устаревший запрос отбрасывается по номеру запроса - иначе медленный ответ
/// на «ка» перекрыл бы уже пришедший ответ на «кальмар».
class NomenclatureTab extends StatefulWidget {
  const NomenclatureTab({
    super.key,
    required this.canImport,
    this.canStock = false,
  });

  /// Право «Загружать номенклатуру из 1С».
  final bool canImport;

  /// Право «Остатки склада: смотреть» - в карточке товара видны места хранения.
  final bool canStock;

  @override
  State<NomenclatureTab> createState() => _NomenclatureTabState();
}

class _NomenclatureTabState extends State<NomenclatureTab> {
  final _api = getIt<PortalCatalogRepository>();
  final _search = TextEditingController();
  Timer? _debounce;

  static const _debounceDelay = Duration(milliseconds: 350);

  /// Наибольшая страница, которую отдаёт сервер (`maxLimit` каталога).
  static const _maxPage = 200;

  /// Обычная страница списка - как у [PortalCatalogRepository.listGoods] по умолчанию.
  static const _firstPage = 50;

  List<NomenclatureGroup> _groups = const [];
  List<Supplier> _suppliers = const [];
  String? _groupId;
  String? _supplierId;

  List<Good>? _goods;
  int _total = 0;
  bool _loadingMore = false;
  String? _error;

  /// Номер последнего запроса списка: ответ на более ранний - устарел.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    loadFilters();
    load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Справочники фильтров; не загрузились - фильтр просто без вариантов.
  Future<void> loadFilters() async {
    final groups = await _api.listGroups();
    final suppliers = await _api.listSuppliers();
    if (!mounted) return;
    setState(() {
      _groups = groups.fold((_) => const [], (g) => g);
      _suppliers = suppliers.fold((_) => const [], (s) => s);
    });
  }

  /// Первая страница под текущие поиск и фильтры.
  Future<void> load() async {
    final seq = ++_seq;
    final res = await _api.listGoods(
      query: _query,
      groupId: _groupId,
      supplierId: _supplierId,
    );
    if (!mounted || seq != _seq) return;
    setState(() {
      _loadingMore = false;
      res.fold((f) => _error = _text(f), (page) {
        _goods = page.items;
        _total = page.total;
        _error = null;
      });
    });
  }

  /// Следующая страница - дописать в конец. Ошибку подгрузки показываем под списком.
  Future<void> loadMore() async {
    final goods = _goods;
    if (goods == null || _loadingMore) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    final res = await _api.listGoods(
      query: _query,
      groupId: _groupId,
      supplierId: _supplierId,
      offset: goods.length,
    );
    if (!mounted || seq != _seq) return;
    setState(() {
      _loadingMore = false;
      res.fold((f) => _error = _text(f), (page) {
        _goods = [...goods, ...page.items];
        _total = page.total;
        _error = null;
      });
    });
  }

  /// Номенклатура изменилась на сервере (ADHOC-60): перечитать фильтры и уже показанные
  /// строки под текущие поиск и фильтры - тихо, без загрузки на весь экран.
  ///
  /// Как: столько строк, сколько уже показано (а не первую страницу) - иначе после «Показать
  /// ещё» список укоротился бы и прокрутка уехала. Сервер отдаёт до [_maxPage] за раз, поэтому
  /// длинный список собирается несколькими запросами. Ошибка тихого чтения не показывается:
  /// на экране остаётся прежний список. Номер запроса - общий с [load]: смена поиска во время
  /// перечитывания отбросит его ответ.
  Future<void> refresh() async {
    final shown = _goods?.length;
    loadFilters();
    if (shown == null) return load();
    final seq = ++_seq;
    final items = <Good>[];
    var total = 0;
    // Не меньше обычной страницы: пустой список после правки мог пополниться.
    final want = shown < _firstPage ? _firstPage : shown;
    while (items.length < want) {
      final res = await _api.listGoods(
        query: _query,
        groupId: _groupId,
        supplierId: _supplierId,
        limit: (want - items.length).clamp(1, _maxPage),
        offset: items.length,
      );
      if (!mounted || seq != _seq) return;
      if (res.isLeft) {
        setState(() => _loadingMore = false);
        return;
      }
      items.addAll(res.right.items);
      total = res.right.total;
      if (res.right.items.isEmpty || items.length >= total) break;
    }
    setState(() {
      // Подгрузка «Показать ещё», начатая до перечитывания, отброшена по номеру запроса.
      _loadingMore = false;
      _goods = items;
      _total = total;
      _error = null;
    });
  }

  String? get _query {
    final q = _search.text.trim();
    return q.isEmpty ? null : q;
  }

  /// Поиск по мере набора - после паузы, чтобы не спрашивать сервер на каждую букву.
  void onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, load);
  }

  /// Фильтр по группе; `null` - все.
  void onGroup(String? id) {
    setState(() => _groupId = id);
    load();
  }

  /// Фильтр по поставщику; `null` - все.
  void onSupplier(String? id) {
    setState(() => _supplierId = id);
    load();
  }

  /// Загрузка из 1С; после неё перечитать фильтры и список - появились новые товары и группы.
  Future<void> import() async {
    if (!await showImportGoodsDialog(context) || !mounted) return;
    loadFilters();
    load();
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
    final goods = _goods;
    return DataVersionsListener(
      domains: const {DataDomain.goods},
      onChanged: refresh,
      child: _listPage(goods),
    );
  }

  /// Страница-список: панель поиска и фильтров, под ней - товары.
  Widget _listPage(List<Good>? goods) {
    return PortalListPage(
      toolbar: GoodsToolbar(
        search: _search,
        onSearch: onSearch,
        groups: _groups,
        groupId: _groupId,
        onGroup: onGroup,
        suppliers: _suppliers,
        supplierId: _supplierId,
        onSupplier: onSupplier,
        trailing: [
          if (widget.canImport)
            PortalButton(
              label: t.portal.goods.import,
              icon: Icons.upload_file_outlined,
              onPressed: import,
            ),
        ],
      ),
      body: goods == null
          ? SettingsListCard(
              loading: _error == null,
              error: _error,
              rows: const [],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GoodsListCard(
                  goods: goods,
                  total: _total,
                  loadingMore: _loadingMore,
                  onMore: loadMore,
                  onOpen: (good) => showGoodCardDialog(
                    context,
                    good,
                    withPlaces: widget.canStock,
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
