import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/documents_repository.dart';
import '../common/neumorphic_icon_button.dart';

/// Строка документа в списке вкладки (ADHOC-25): неоморфные кнопки действий слева, затем
/// заголовок и дата с числом позиций.
///
/// Строка без рамки, прямо на фоне рабочей области: список читается как перечень, а не как
/// стопка карточек. Кнопки стоят вплотную к своей строке и в одной колонке при любой длине
/// заголовка — глазу не нужно идти через пустое место к действиям, рука находит их на месте.
class DocRow extends StatelessWidget {
  const DocRow({
    super.key,
    required this.doc,
    required this.mark,
    required this.downloading,
    required this.marking,
    required this.onDownload,
    required this.onMarkDone,
    required this.onHistory,
  });

  final PortalDoc doc;

  /// Название документа в строке.
  final String mark;
  final bool downloading;
  final bool marking;
  final VoidCallback onDownload;
  final VoidCallback onMarkDone;
  final VoidCallback onHistory;

  /// Формат даты документа: `дд.мм.гггг чч:мм` в локальной зоне.
  String _date(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  /// Заголовок строки: документ · склад, а у «Поступления» ещё поставщик и его документ —
  /// по ним оператор узнаёт приход среди других и находит накладную для 1С (P4-10, ADHOC-23).
  /// У «Движения» — операция и основание: задание и приёмка, из которой оно родилось (P5-04).
  String _title() {
    switch (doc.kind) {
      case 'receipt':
        return '$mark · ${_supplier()}${_supplierDoc()} · ${doc.warehouseName}';
      case 'movement':
        final task = doc.taskNumber > 0
            ? ' · ${t.portal.movement.task(number: doc.taskNumber)}'
            : '';
        final supplier = doc.supplier.isEmpty ? '' : ' · ${doc.supplier}';
        return '$mark · ${_operation()}$task$supplier${_supplierDoc()} · ${doc.warehouseName}';
      default:
        return '$mark · ${doc.warehouseName}';
    }
  }

  /// Поставщик «Поступления»; пусто — подпись «без поставщика».
  String _supplier() =>
      doc.supplier.isEmpty ? t.portal.receipt.noSupplier : doc.supplier;

  /// Накладная поставщика « · № … от …»; пусто, если её нет.
  String _supplierDoc() => doc.docNumber.isEmpty
      ? ''
      : ' · ${t.portal.receipt.doc(number: doc.docNumber, date: doc.docDate.replaceAll('-', '.'))}';

  /// Операция «Движения» для человека; незнакомая показывается как есть.
  String _operation() => switch (doc.operation) {
    'putaway' => t.portal.movement.opPutaway,
    _ => doc.operation,
  };

  /// Ряд действий: слот статуса, история, скачивание.
  ///
  /// Слот статуса: невыполненный документ — кнопка «отметить», выполненный — галочка на её
  /// месте. Слот одного размера с кнопкой, галочка в нём по центру: колонка статуса читается
  /// сверху вниз ровно.
  Widget _actions() {
    final done = doc.status == DocStatus.done;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: AppSizes.kIcon40,
          child: done
              ? const Center(
                  child: Icon(
                    Icons.task_alt,
                    color: AppColors.kGreenLime,
                    size: AppSizes.kIcon28,
                  ),
                )
              : NeumorphicIconButton(
                  icon: Icons.check,
                  tooltip: t.portal.documents.markDone,
                  busy: marking,
                  onPressed: onMarkDone,
                ),
        ),
        AppBoxes.kWidth16,
        NeumorphicIconButton(
          icon: Icons.history,
          tooltip: t.portal.documents.history,
          onPressed: onHistory,
        ),
        AppBoxes.kWidth16,
        NeumorphicIconButton(
          icon: Icons.download,
          tooltip: t.portal.documents.download,
          busy: downloading,
          onPressed: onDownload,
        ),
      ],
    );
  }

  /// Текст строки: заголовок и дата с числом позиций.
  Widget _text() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title(),
          style: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kTextSecondary,
          ),
        ),
        Text(
          '${_date(doc.createdAt)} · ${t.portal.documents.lines(count: doc.linesCount)}',
          style: RegularTextStyles().regularInter12.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.v8,
      // Раскладка — по ширине самой строки, а не окна: на узкой (телефон) кнопки уходят под
      // текст, иначе ряд из трёх кнопок оставлял бы заголовку пару букв в строку.
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth < AppSizes.kDocRowCompactWidth
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [_text(), AppBoxes.kHeight12, _actions()],
              )
            : Row(
                children: [
                  _actions(),
                  AppBoxes.kWidth24,
                  Expanded(child: _text()),
                ],
              ),
      ),
    );
  }
}
