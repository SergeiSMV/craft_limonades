import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/bar_buttons.dart';
import '../bloc/receipt_cubit.dart';

/// Шапка общего списка приёмки: от кого принимаем и по какому документу, куда кладём штучный
/// товар, новый короб.
///
/// Поставщик и ячейка видны постоянно: они определяют, куда ляжет следующий скан, и кладовщик
/// должен видеть это до скана, а не узнавать из списка строк после. Короб заводится только
/// кнопкой «короб плюс» (ADHOC-18) - отдельной кнопки «Штучно» больше нет: штучно и есть
/// общий список.
class ReceiptContextBar extends StatelessWidget {
  const ReceiptContextBar({
    super.key,
    required this.state,
    required this.onChangeCell,
    required this.onNewBox,
    required this.onEditDoc,
  });

  final ReceiptState state;

  /// Указать или исправить документ поставщика (ADHOC-23).
  final VoidCallback onEditDoc;

  /// Сменить ячейку для штучных строк и новых коробов.
  final VoidCallback onChangeCell;

  /// Завести новый короб и открыть его.
  final VoidCallback onNewBox;

  @override
  Widget build(BuildContext context) {
    final supplier = state.supplier;
    final doc = state.doc;
    final cell = state.targetCell;
    final cellText = cell == null
        ? t.receipt.cellDefault(address: state.defaultCell?.address ?? '')
        : t.receipt.cell(address: cell.address);
    return Container(
      color: AppColors.kNeumorphicBg,
      padding: AppInsets.all8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.left6,
            child: Text(
              supplier == null
                  ? t.receipt.supplierNone
                  : t.receipt.supplier(name: supplier.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
          // Документ поставщика - под поставщиком; касание открывает окно правки. Не указан
          // (черновик до ADHOC-23) - подсвечен: без него приёмку не завершить.
          InkWell(
            onTap: onEditDoc,
            child: Padding(
              padding: AppInsets.left6 + AppInsets.top4,
              child: Text(
                doc == null
                    ? t.receipt.docMissing
                    : t.receipt.docLine(number: doc.number, date: doc.date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RegularTextStyles().regularInter12.copyWith(
                  color: doc == null ? AppColors.kDanger : AppColors.kTextMuted,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.kTextMuted,
                ),
              ),
            ),
          ),
          AppBoxes.kHeight8,
          Row(
            children: [
              Expanded(
                child: BarButton(
                  onPressed: onChangeCell,
                  text: cellText,
                  icon: MdiIcons.cogTransfer,
                ),
              ),
              AppBoxes.kWidth8,
              BarIconButton(
                onPressed: onNewBox,
                icon: MdiIcons.packageVariantPlus,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
