import 'dart:async';

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../features/stock/data/catalog_models.dart';
import '../../features/stock/data/catalog_repository.dart';
import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../gen/assets.gen.dart';
import '../gen/strings.g.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';

/// Нижний лист выбора товара из номенклатуры (поиск с дебаунсом).
///
/// Живёт в `core/widgets`, потому что нужен двум фичам: «Ввод остатков» открывает его, когда
/// отсканированный ШК не привязан, а «Остатки» - когда кладовщик согласился привязать такой ШК
/// (ADHOC-06). Держать его в `stock_entry` значило бы тянуть импорт из одной фичи в другую;
/// от самого `stock_entry` лист не зависит - ему нужен только справочник товаров.
class GoodPickerSheet extends StatefulWidget {
  const GoodPickerSheet({super.key, required this.repo});

  final CatalogRepository repo;

  @override
  State<GoodPickerSheet> createState() => _GoodPickerSheetState();
}

class _GoodPickerSheetState extends State<GoodPickerSheet> {
  Timer? _debounce;
  List<Good> _goods = const [];
  int _total = 0;
  String? _query;
  bool _loading = true;
  bool _loadingMore = false;

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

  /// Есть ли ещё непогруженные товары под текущий фильтр.
  bool get _hasMore => _goods.length < _total;

  /// Загрузка первой страницы товаров (с фильтром по названию/коду, если есть). Сбрасывает пагинацию.
  Future<void> _load(String? query) async {
    _query = query;
    setState(() => _loading = true);
    final res = await widget.repo.listGoods(query: query, limit: 50);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.isRight) {
        _goods = res.right.items;
        _total = res.right.total;
      } else {
        _goods = const [];
        _total = 0;
      }
    });
  }

  /// Подгрузить следующую страницу (бесконечный скролл): дозапрос от offset=_goods.length, дописываем
  /// в конец. Защита от повторного входа и от запроса за границей total.
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final res = await widget.repo.listGoods(
      query: _query,
      limit: 50,
      offset: _goods.length,
    );
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (res.isRight) {
        _goods = [..._goods, ...res.right.items];
        _total = res.right.total;
      }
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
    return Padding(
      padding:
          AppInsets.h8 +
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.goodPicker.title, style: SemiboldTextStyles().semiboldInter18),
          AppBoxes.kHeight12,
          Padding(
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
                cursorColor: AppColors.kTextMuted,
                cursorWidth: 1.5,
                cursorHeight: 20,
                autofocus: true,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  prefixIcon: const Icon(
                    Icons.search,
                    size: AppSizes.kIcon25,
                    color: AppColors.kTextMuted,
                  ),
                  hintText: t.goodPicker.searchHint,
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
          ),
          AppBoxes.kHeight12,
          Flexible(
            child: _loading
                ? const Center(
                    child: Padding(
                      padding: AppInsets.all16,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : _goods.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Assets.icons.goodsNotFound.image(width: 90),
                        AppBoxes.kHeight8,
                        Text(t.goodPicker.nothingFound),
                      ],
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    // Ближе 400px к концу - тянем следующую страницу (loadMore защищён от повторов).
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
                        _loadMore();
                      }
                      return false;
                    },
                    child: Padding(
                      padding: AppInsets.bottom8,
                      child: ListView.builder(
                        shrinkWrap: true,
                        // +1 на футер-индикатор, пока есть непогруженные товары.
                        itemCount: _goods.length + (_hasMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _goods.length) {
                            return const Padding(
                              padding: AppInsets.v16,
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final g = _goods[i];
                          return Padding(
                            padding: AppInsets.top8 + AppInsets.h8,
                            child: NeumorphicButton(
                              onPressed: () => Navigator.of(context).pop(g),
                              style: NeumorphicStyle(
                                shadowLightColor: AppColors.kNeumorphicLight,
                                shadowDarkColor: AppColors.kNeumorphicDark,
                                intensity: 1,
                                color: AppColors.kNeumorphicBg,
                                depth: 3,
                                shape: NeumorphicShape.flat,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    g.name,
                                    style: RegularTextStyles().regularInter12,
                                  ),
                                  Text(
                                    [
                                      if (g.code != null) g.code!,
                                      g.uom,
                                    ].join(' · '),
                                    style: RegularTextStyles().regularInter10
                                        .copyWith(color: AppColors.kTextMuted),
                                  ),
                                ],
                              ),
                            ),
                          );

                          /*
                        ListTile(
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
                        */
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
