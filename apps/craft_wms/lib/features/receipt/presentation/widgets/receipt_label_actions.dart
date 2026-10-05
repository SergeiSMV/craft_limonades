import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../stock/data/catalog_models.dart';
import '../bloc/receipt_cubit.dart';
import 'receipt_failure_text.dart';

/// Печать ярлыков из потока приёмки: ярлык короба, товарный ярлык, выдача внутреннего ШК.
///
/// Вынесено из рабочего экрана в миксин: у печати своя цепочка решений (какой ШК печатать,
/// выдавать ли новый, что сказать при отказе принтера), и смешанная со сканами она делала бы
/// экран нечитаемым. Миксин, а не отдельный виджет: печать ничего не рисует, ей нужен только
/// контекст экрана для диалогов и снекбаров.
///
/// Неудача печати приёмку никогда не останавливает: товар и короб уже учтены, ярлык можно
/// допечатать из меню строки или короба.
mixin ReceiptLabelActions<T extends StatefulWidget> on State<T> {
  ReceiptCubit get _cubit => context.read<ReceiptCubit>();

  /// Показать снекбар — общий для экрана и миксина.
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Напечатать ярлык короба и сказать, чем кончилось.
  Future<void> printBoxLabel(String boxId) async {
    final error = await _cubit.printBoxLabel(boxId);
    if (!mounted) return;
    snack(
      error == null ? t.receipt.printed : t.receipt.printFailed(message: error),
    );
  }

  /// Напечатать товарный ярлык: ШК у товара один — печатаем его, несколько — спрашиваем,
  /// нет ни одного — предлагаем выдать внутренний.
  Future<void> printGoodLabel(Good good) async {
    final res = await _cubit.barcodesOf(good.id);
    if (!mounted) return;
    if (res.isLeft) {
      snack(t.receipt.printFailed(message: receiptFailureText(res.left)));
      return;
    }
    final codes = res.right.map((b) => b.barcode).toList();
    if (codes.isEmpty) {
      await offerInternalBarcode(good);
      return;
    }
    final code = codes.length == 1 ? codes.first : await _pickBarcode(codes);
    if (code == null || !mounted) return;
    await _printGood(code, good);
  }

  /// Предложить выдать товару без ШК внутренний код и напечатать ярлык (P4-07, P4-08).
  ///
  /// Только по сети (решение P4-09): без связи кладовщик получает понятный отказ, а товар
  /// принимается без ярлыка — приёмку отсутствие наклейки не останавливает.
  Future<void> offerInternalBarcode(Good good) async {
    final confirmed = await showBindPromptDialog(
      context,
      title: t.receipt.noBarcodeTitle,
      body: t.receipt.noBarcodeBody,
      confirmLabel: t.receipt.issueBarcode,
      cancelLabel: t.receipt.skipBarcode,
    );
    if (!confirmed || !mounted) return;
    final res = await _cubit.issueBarcode(good.id);
    if (!mounted) return;
    if (res.isLeft) {
      final f = res.left;
      snack(
        f is NetworkFailure
            ? t.receipt.issueOffline
            : t.receipt.issueFailed(message: receiptFailureText(f)),
      );
      return;
    }
    final issued = res.right;
    // Выдача идемпотентна: у товара код уже мог быть. Печатаем его же, но говорим об этом —
    // иначе кладовщик решит, что у товара теперь два внутренних кода.
    if (!issued.generated) {
      snack(t.receipt.barcodeExisted(barcode: issued.barcode));
    }
    await _printGood(issued.barcode, good);
  }

  /// Выбор штрихкода для печати, когда у товара их несколько (штука и короб, P-FS-11).
  Future<String?> _pickBarcode(List<String> codes) => showDialog<String>(
    context: context,
    builder: (dctx) => SimpleDialog(
      title: Text(t.receipt.pickBarcode),
      children: [
        for (final c in codes)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dctx).pop(c),
            child: Text(c),
          ),
      ],
    ),
  );

  /// Печать товарного ярлыка с отчётом об исходе. Наименование уходит в принтер как есть —
  /// чистит его шаблон ярлыка (`sanitizeTsplText`), а не каждый вызывающий.
  Future<void> _printGood(String barcode, Good good) async {
    final error = await _cubit.printGoodLabel(
      barcode: barcode,
      goodName: good.name,
    );
    if (!mounted) return;
    snack(
      error == null ? t.receipt.printed : t.receipt.printFailed(message: error),
    );
  }
}
