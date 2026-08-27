import 'package:craft_wms/core/theme/semibold_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/bold_text.dart';
import '../../bloc/stock_detail_cubit.dart';

/// Нижняя панель «ИТОГО НА СКЛАДЕ»: сумма количеств по всем местам хранения.
/// Закреплена под списком, поэтому итог виден при любой прокрутке; до загрузки скрыта.
class TotalBar extends StatelessWidget {
  const TotalBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;
    if (state.status != StockDetailStatus.loaded) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.kCardBg,
        border: Border(top: BorderSide(color: AppColors.kBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: AppInsets.all16,
          child: Row(
            children: [
              Text(
                t.stockDetailScreen.totalTitle,
                style: SemiboldTextStyles().semiboldInter16.copyWith(
                  color: AppColors.kSidebarHover,
                ),
              ),
              const Spacer(),
              Text(
                state.totalQty,
                style: BoldTextStyles().boldInter20.copyWith(
                  color: AppColors.kSidebarHover,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
