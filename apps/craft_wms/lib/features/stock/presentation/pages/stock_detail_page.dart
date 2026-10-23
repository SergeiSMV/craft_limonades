import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../data/catalog_models.dart';
import '../bloc/stock_detail_cubit.dart';
import '../widgets/stock_detail/stock_detail_body.dart';

/// Карточка остатков товара (P1-07): шапка товара, привязанные штрихкоды,
/// строки «ячейка · партия · количество» и итог по складу.
/// Всё показывается «россыпью» — разбивка по грузовым единицам (ГЕ) появится в P4/P5.
@RoutePage()
class StockDetailPage extends StatelessWidget {
  const StockDetailPage({super.key, required this.good, this.czMark});

  final Good good;

  /// Ответ на скан марки «Честного знака», если карточка открыта сканом марки (CZ-04): тогда
  /// под шапкой товара — блок марки. `null` — обычная карточка.
  final CzScanResult? czMark;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StockDetailCubit>()..load(good.id),
      // Шапка светлая, поэтому статусбар — с тёмными иконками (на «Остатках» он светлый).
      child: SystemUiWrapper(
        child: Scaffold(
          backgroundColor: AppColors.kBg,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: AppColors.kBg,
            title: PageHeader(
              title: t.stockDetailScreen.title,
              textColor: AppColors.kSidebarHover,
              goBack: () => Navigator.of(context).pop(),
            ),
          ),
          body: StockDetailBody(good: good, czMark: czMark),
        ),
      ),
    );
  }
}
