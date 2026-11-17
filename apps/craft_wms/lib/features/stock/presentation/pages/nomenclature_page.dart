import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/goods_list_cubit.dart';
import '../goods_search_handlers.dart';
import '../widgets/goods_list/goods_result.dart';
import '../widgets/goods_list/stock_header.dart';

/// Экран «Номенклатура» (ADHOC-33): весь справочник товаров - и те, которых на складе нет.
///
/// Открывается из меню главного экрана «⋮». Поиск, фильтры (группа/поставщик), скан ШК и
/// привязка ШК к товару - как было во вкладке «Товары» «Остатков» до ADHOC-33; тап по товару →
/// та же карточка остатков. Сами «Остатки» с ADHOC-33 показывают только товары с остатком.
@RoutePage()
class NomenclaturePage extends StatelessWidget {
  const NomenclaturePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<GoodsListCubit>()..init(),
      child: const _NomenclatureView(),
    );
  }
}

class _NomenclatureView extends StatefulWidget {
  const _NomenclatureView();

  @override
  State<_NomenclatureView> createState() => _NomenclatureViewState();
}

class _NomenclatureViewState extends State<_NomenclatureView>
    with HardwareScanListener, GoodsSearchHandlers {
  /// Код с аппаратного сканера (intent-режим) - тем же путём, что завершённый ввод в строке.
  @override
  void onHardwareScan(ScanCode code) => onSearchSubmitted(code.raw);

  /// Назад в главное меню. Отложенный поиск гасим: экран уходит, а его запрос иначе улетел бы
  /// вдогонку.
  void goBack() {
    context.read<GoodsListCubit>().cancelPendingSearch();
    context.router.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        body: Column(
          children: [
            StockHeader(
              title: t.stockListScreen.nomenclatureTitle,
              goBack: goBack,
              search: goodsSearch(),
            ),
            const Expanded(child: GoodsResult()),
          ],
        ),
      ),
    );
  }
}
