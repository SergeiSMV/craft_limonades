import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../cz/presentation/widgets/cz_lines.dart';
import '../../bloc/stock_detail_cubit.dart';
import 'bind_barcode_button.dart';

/// Марка числится за товаром карточки, а её ШК ни к какому товару не привязан (ADHOC-53).
///
/// Что: предупреждение и кнопка «Вернуть привязку ШК» - к товару карточки, за которым марка
/// числится. Если товар на самом деле другой, ШК потом перепривязывают из карточки с
/// пересортом; сначала привязка должна вернуться, иначе следующие марки этого GTIN не найдут
/// товар.
class UnboundBarcodeNotice extends StatefulWidget {
  const UnboundBarcodeNotice({super.key, required this.barcode});

  /// ШК из марки (EAN-13 из GTIN).
  final String barcode;

  @override
  State<UnboundBarcodeNotice> createState() => _UnboundBarcodeNoticeState();
}

class _UnboundBarcodeNoticeState extends State<UnboundBarcodeNotice> {
  /// Привязку вернули: на сервере или в очереди.
  String? _done;

  /// Привязать ШК к товару карточки: без связи привязка уходит в очередь, как обычная.
  Future<void> _bind() async {
    final failure = await context.read<StockDetailCubit>().bindBarcode(
      widget.barcode,
    );
    if (!mounted) return;
    switch (failure) {
      case null:
        setState(() => _done = t.regrade.unboundBound);
      case NetworkFailure():
        setState(() => _done = t.regrade.unboundQueued);
      case RejectedFailure(:final reason):
        _snack(reason);
      case ServerFailure(:final message?):
        _snack(message);
      default:
        _snack(t.regrade.failed);
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.top8,
    child: czCard([
      if (_done != null)
        czText(_done!)
      else ...[
        czText(t.regrade.unbound(barcode: widget.barcode)),
        AppBoxes.kHeight8,
        BindBarcodeButton(label: t.regrade.unboundBind, onPressed: _bind),
      ],
    ]),
  );
}
