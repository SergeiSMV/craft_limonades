import 'package:flutter/services.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_input.dart';
import '../bloc/receipt_models.dart';

/// Спросить документ поставщика (ADHOC-23); [initial] — исправление уже указанного.
/// `null` — кладовщик отменил.
Future<ReceiptDoc?> showSupplierDocDialog(
  BuildContext context, {
  ReceiptDoc? initial,
}) => showDialog<ReceiptDoc>(
  context: context,
  builder: (_) => SupplierDocDialog(initial: initial),
);

/// Окно «Документ поставщика»: номер накладной (или «б/н» одним нажатием) и её дата.
///
/// Вёрстка — как у окна даты и количества строки: те же вдавленные поля и тот же ввод даты
/// с авто-точками, чтобы кладовщик не переучивался между окнами одного потока.
class SupplierDocDialog extends StatefulWidget {
  const SupplierDocDialog({super.key, this.initial});

  final ReceiptDoc? initial;

  @override
  State<SupplierDocDialog> createState() => _SupplierDocDialogState();
}

class _SupplierDocDialogState extends State<SupplierDocDialog> {
  late final _number = TextEditingController(text: widget.initial?.number);
  late final _date = TextEditingController(text: widget.initial?.date);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _number.dispose();
    _date.dispose();
    super.dispose();
  }

  /// «б/н» — накладная без номера: вписать одним нажатием, а не набирать с клавиатуры.
  void noNumber() => _number.text = t.receipt.docNoNumber;

  /// Проверить и закрыть окно с документом; дата приводится к дд.мм.гггг.
  void submit() {
    if (!_formKey.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(
      ReceiptDoc(
        number: _number.text.trim(),
        date: normalizeEntryDate(_date.text.trim()),
      ),
    );
  }

  /// Номер: не пустой и не длиннее 50 знаков — тот же предел, что на сервере.
  String? validateNumber(String? v) {
    final s = (v ?? '').trim();
    return s.isEmpty || s.length > 50 ? t.receipt.docNumberRequired : null;
  }

  /// Дата: настоящая и не позже сегодняшней — накладная из будущего значит опечатку.
  String? validateDate(String? v) {
    final s = (v ?? '').trim();
    if (!isValidEntryDate(s)) return t.receipt.docDateInvalid;
    final p = normalizeEntryDate(s).split('.');
    final d = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
    final now = DateTime.now();
    return d.isAfter(DateTime(now.year, now.month, now.day))
        ? t.receipt.docDateInvalid
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // scrollable — чтобы текст ошибки под полем не переполнял окно при поднятой клавиатуре.
      backgroundColor: Colors.white,
      scrollable: true,
      insetPadding: AppInsets.h8,
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: AppInsets.left6,
                child: Text(
                  t.receipt.docTitle,
                  style: SemiboldTextStyles().semiboldInter14.copyWith(
                    color: AppColors.kSidebarHover,
                  ),
                ),
              ),
              AppBoxes.kHeight8,
              _label(t.receipt.docNumberLabel),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _field(
                      controller: _number,
                      hint: t.receipt.docNumberHint,
                      validator: validateNumber,
                      autofocus: widget.initial == null,
                    ),
                  ),
                  AppBoxes.kWidth8,
                  TextButton(
                    onPressed: noNumber,
                    child: Text(t.receipt.docNoNumber),
                  ),
                ],
              ),
              AppBoxes.kHeight12,
              _label(t.receipt.docDateLabel),
              _field(
                controller: _date,
                hint: 'дд.мм.гг(гг)',
                validator: validateDate,
                keyboardType: TextInputType.number,
                formatters: [DateTextInputFormatter()],
              ),
              AppBoxes.kHeight12,
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.receipt.cancel),
                  ),
                  FilledButton(
                    onPressed: submit,
                    child: Text(t.receipt.docSave),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: AppInsets.left6,
    child: Text(
      text,
      style: RegularTextStyles().regularInter12.copyWith(
        color: AppColors.kTextMuted,
      ),
    ),
  );

  /// Вдавленное поле — как в окне даты и количества.
  Widget _field({
    required TextEditingController controller,
    required String hint,
    required FormFieldValidator<String> validator,
    bool autofocus = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
  }) => Neumorphic(
    style: NeumorphicStyle(
      shadowLightColor: AppColors.kNeumorphicLight,
      shadowDarkColor: AppColors.kNeumorphicDark,
      intensity: 1,
      color: AppColors.kNeumorphicBg,
      depth: -2,
      shape: NeumorphicShape.flat,
    ),
    child: TextFormField(
      cursorColor: AppColors.kTextMuted,
      cursorWidth: 1.5,
      cursorHeight: 20,
      controller: controller,
      autofocus: autofocus,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kBorderDashed,
        ),
        border: const OutlineInputBorder(
          borderRadius: AppBorders.kCircular8,
          borderSide: BorderSide.none,
        ),
      ),
      validator: validator,
    ),
  );
}
