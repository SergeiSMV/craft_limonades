import 'package:flutter/material.dart';

import '../../../../../core/auth/rights.dart';
import '../../../../../core/auth/session_rights.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/di/injection.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/widgets/good_picker_sheet.dart';
import '../../../../cz/domain/cz_regrade_repository.dart';
import '../../../data/catalog_models.dart';
import '../../../data/catalog_repository.dart';

/// Отвязка ШК маркируемого товара (ADHOC-53, решение 2026-10-28).
///
/// Что: перед отвязкой сервер говорит, сколько марок ЧЗ с этим ШК лежит на складе. Марок нет -
/// отвязка идёт как обычно. Есть - отвязать нельзя: ШК перепривязывается к правильному товару,
/// марки и их остаток переходят на него, а в «Проблемы склада» уходит пересорт.
///
/// Зачем: отвязка оставила бы марки на складе без товара в справочнике - скан марки не нашёл бы
/// её товар. Ошибочная привязка исправляется перепривязкой, а не удалением.
///
/// Как: всё онлайн - без связи отвязать ШК маркируемого товара нельзя, марки не проверить.
/// Перепривязку делает должность с правом `tsd.stock.regrade`, остальным - объяснение.
class RegradeFlow {
  RegradeFlow(this.context, {required this.goodId, required this.goodName});

  final BuildContext context;

  /// Товар карточки - за ним сейчас ШК и марки.
  final String goodId;
  final String goodName;

  /// Можно ли отвязывать ШК как обычно: `true` - марок на складе нет; `false` - отвязку
  /// заменила перепривязка (или отказ), карточке делать нечего.
  ///
  /// [onRegraded] - перепривязка прошла: карточке пора перечитаться.
  Future<bool> canUnbind(
    String code, {
    required VoidCallback onRegraded,
  }) async {
    _snack(t.regrade.checking);
    final res = await getIt<CzRegradeRepository>().marksInStock(code);
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (res.isLeft) {
      _snack(_failureText(res.left));
      return false;
    }
    final marks = res.right;
    if (marks == 0) return true;
    if (await _offerRegrade(code, marks) && context.mounted) {
      await _regrade(code, marks, onRegraded);
    }
    return false;
  }

  /// Объяснить, почему не отвязать, и предложить перепривязку; `true` - согласились.
  Future<bool> _offerRegrade(String code, int marks) async {
    final can = sessionCan(context, Rights.tsdStockRegrade);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.regrade.blockedTitle),
        content: Text(
          can
              ? t.regrade.blockedBody(n: marks, barcode: code)
              : t.regrade.blockedNoRight(n: marks, barcode: code),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(can ? t.regrade.cancel : t.regrade.ok),
          ),
          if (can)
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: Text(t.regrade.rebind),
            ),
        ],
      ),
    );
    return ok == true;
  }

  /// Выбрать правильный товар, подтвердить и перепривязать.
  Future<void> _regrade(String code, int marks, VoidCallback onRegraded) async {
    final good = await _pickGood();
    if (good == null || !context.mounted) return;
    if (good.id == goodId) {
      _snack(t.regrade.sameGood);
      return;
    }
    if (!await _confirm(code, marks, good) || !context.mounted) return;
    final res = await getIt<CzRegradeRepository>().regrade(
      barcode: code,
      goodId: good.id,
    );
    if (!context.mounted) return;
    if (res.isLeft) {
      _snack(_failureText(res.left));
      return;
    }
    _snack(t.regrade.done(n: res.right, name: good.name));
    onRegraded();
  }

  /// Выбор товара - тот же лист, что у привязки незнакомого ШК.
  Future<Good?> _pickGood() => showModalBottomSheet<Good>(
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.95,
    ),
    builder: (_) => GoodPickerSheet(repo: getIt<CatalogRepository>()),
  );

  /// Последнее слово перед перепривязкой: что, сколько и с какого товара на какой.
  Future<bool> _confirm(String code, int marks, Good to) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(t.regrade.confirmTitle),
        content: Text(
          t.regrade.confirmBody(
            barcode: code,
            n: marks,
            from: goodName,
            to: to.name,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(t.regrade.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(t.regrade.rebind),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Текст неудачи: без связи - отдельно, отказ сервера - его словами.
  String _failureText(Failure f) => switch (f) {
    NetworkFailure() => t.regrade.offline,
    ServerFailure(:final message?) => message,
    _ => t.regrade.failed,
  };

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
