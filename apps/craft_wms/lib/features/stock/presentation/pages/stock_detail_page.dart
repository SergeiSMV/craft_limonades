import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../data/catalog_models.dart';
import '../bloc/stock_detail_cubit.dart';

/// Карточка остатков товара (P1-07): шапка товара + строки «ячейка · партия · кол-во» + итог.
/// Всё показывается «россыпью» — разбивка по грузовым единицам (ГЕ) появится в P4/P5.
@RoutePage()
class StockDetailPage extends StatelessWidget {
  const StockDetailPage({super.key, required this.good});

  final Good good;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StockDetailCubit>()..load(good.id),
      child: Scaffold(
        appBar: AppBar(title: Text(t.stockDetailScreen.title)),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GoodHeader(good: good),
            const _BarcodesSection(),
            const Divider(height: 1),
            Expanded(child: _StockRows(goodId: good.id)),
          ],
        ),
      ),
    );
  }
}

/// Шапка карточки: наименование + артикул/ед./группа/поставщик.
class _GoodHeader extends StatelessWidget {
  const _GoodHeader({required this.good});

  final Good good;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.all16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            good.name,
            style: const TextStyle(
              fontSize: AppSizes.kText18,
              fontWeight: FontWeight.bold,
            ),
          ),
          AppBoxes.kHeight8,
          if (good.code != null)
            Text(t.stockDetailScreen.code(code: good.code!), style: _muted),
          Text(t.stockDetailScreen.uom(uom: good.uom), style: _muted),
          if (good.groupName != null)
            Text(
              t.stockDetailScreen.group(group: good.groupName!),
              style: _muted,
            ),
          if (good.supplierName != null)
            Text(
              t.stockDetailScreen.supplier(supplier: good.supplierName!),
              style: _muted,
            ),
        ],
      ),
    );
  }

  static const TextStyle _muted = TextStyle(
    fontSize: AppSizes.kText13,
    color: AppColors.kTextMuted,
  );
}

/// Секция «Штрихкоды» товара (P-FS-12): чипы ШК с удалением (отвязка ошибочного ШК). Показывается
/// после загрузки карточки; пустой список — подпись «нет привязанных ШК». Отвязка — с подтверждением.
class _BarcodesSection extends StatelessWidget {
  const _BarcodesSection();

  /// Подтвердить и отвязать ШК от товара.
  Future<void> _confirmUnbind(BuildContext context, String code) async {
    final cubit = context.read<StockDetailCubit>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.stockDetailScreen.barcodeDeleteTitle),
        content: Text(t.stockDetailScreen.barcodeDeleteBody(barcode: code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(t.stockDetailScreen.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(t.stockDetailScreen.unbind),
          ),
        ],
      ),
    );
    if (ok == true) cubit.unbindBarcode(code);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;
    if (state.status != StockDetailStatus.loaded) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: AppInsets.h16 + AppInsets.bottom8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stockDetailScreen.barcodesTitle, style: _sectionLabel),
          AppBoxes.kHeight4,
          if (state.barcodes.isEmpty)
            Text(t.stockDetailScreen.barcodesEmpty, style: _muted)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final b in state.barcodes)
                  Chip(
                    label: Text(b.barcode),
                    onDeleted: () => _confirmUnbind(context, b.barcode),
                    deleteIcon: const Icon(Icons.close, size: AppSizes.kIcon16),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static const TextStyle _sectionLabel = TextStyle(
    fontSize: AppSizes.kText13,
    fontWeight: FontWeight.w600,
    color: AppColors.kTextMuted,
  );
  static const TextStyle _muted = TextStyle(
    fontSize: AppSizes.kText13,
    color: AppColors.kTextMuted,
  );
}

/// Строки остатка по ячейкам/партиям + итог; индикатор/ошибка/пусто.
class _StockRows extends StatelessWidget {
  const _StockRows({required this.goodId});

  final String goodId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockDetailCubit>().state;

    switch (state.status) {
      case StockDetailStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case StockDetailStatus.error:
        return _ErrorRetry(
          onRetry: () => context.read<StockDetailCubit>().load(goodId),
        );
      case StockDetailStatus.loaded:
        if (state.items.isEmpty) {
          return Center(child: Text(t.stockDetailScreen.empty));
        }
        return Column(
          children: [
            Expanded(
              child: ListView.separated(
                itemCount: state.items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final it = state.items[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(it.cellAddress),
                    subtitle: Text(
                      '${t.stockDetailScreen.colBatch}: ${_batchDate(it.productionDate)}',
                    ),
                    trailing: Text(
                      it.qty,
                      style: const TextStyle(
                        fontSize: AppSizes.kText16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: AppInsets.all16,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  t.stockDetailScreen.total(qty: state.totalQty),
                  style: const TextStyle(
                    fontSize: AppSizes.kText18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
    }
  }
}

/// Блок ошибки с кнопкой «Повторить».
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(t.stockDetailScreen.error),
          AppBoxes.kHeight12,
          FilledButton(
            onPressed: onRetry,
            child: Text(t.stockDetailScreen.retry),
          ),
        ],
      ),
    );
  }
}

/// Дата партии с бэкенда приходит в ISO (YYYY-MM-DD); показываем в дд.мм.гггг.
String _batchDate(String s) {
  final iso = s.length >= 10 ? s.substring(0, 10) : s;
  final p = iso.split('-');
  if (p.length == 3 && p[0].length == 4) return '${p[2]}.${p[1]}.${p[0]}';
  return s; // неожиданный формат — как есть
}
