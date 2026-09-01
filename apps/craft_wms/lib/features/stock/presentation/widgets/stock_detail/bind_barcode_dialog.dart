import 'package:flutter/material.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart'
    show Neumorphic, NeumorphicStyle, NeumorphicShape;

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/error/failure.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';

/// Диалог привязки штрихкода к товару (P-FS-17): одно поле под скан, «Отмена» и «Привязать».
///
/// Поле в фокусе, но экранная клавиатура не открывается: HID-сканер шлёт ввод в сфокусированное
/// поле, а клавиатура на ТСД только занимает место. Достигается `TextInputType.none` — IME
/// не запрашивается вовсе. Прежний приём «показать и спрятать следующим кадром» (как на экране
/// входа) на устройстве давал видимое мелькание клавиатуры снизу.
/// По тапу по полю переключаемся на обычную клавиатуру — для ручного ввода кода.
/// Enter от сканера сразу привязывает: скан одним движением, без второго тапа.
///
/// Ошибку показываем прямо в диалоге и его не закрываем — чтобы после «ШК уже за другим товаром»
/// можно было сразу пересканировать другой код.
class BindBarcodeDialog extends StatefulWidget {
  const BindBarcodeDialog({super.key, required this.onBind});

  /// Привязать код. Возвращает `null` при успехе либо ошибку для показа в диалоге.
  final Future<Failure?> Function(String code) onBind;

  @override
  State<BindBarcodeDialog> createState() => _BindBarcodeDialogState();
}

class _BindBarcodeDialogState extends State<BindBarcodeDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// Текст ошибки под полем (конфликт ШК или сбой запроса); null — ошибки нет.
  String? _error;

  /// Идёт запрос: блокируем повторную отправку.
  bool _busy = false;

  /// Нужна ли экранная клавиатура. По умолчанию нет: ждём скан. `TextInputType.none`
  /// не даёт IME открыться, поэтому мелькания нет — в отличие от «спрятать следующим кадром».
  bool _softKeyboard = false;

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Тап по полю — кладовщик хочет набрать код руками: включаем обычную клавиатуру.
  ///
  /// Одной смены `keyboardType` мало: соединение с IME создаётся в момент получения фокуса и
  /// живёт с той конфигурацией, с которой создано, — поле осталось бы `none`, а `TextInput.show`
  /// для такого соединения ничего не делает. Поэтому снимаем фокус и возвращаем его следующим
  /// кадром: связь пересоздаётся уже как обычное текстовое поле, и клавиатура открывается сама.
  void enableSoftKeyboard() {
    if (_softKeyboard) return;
    setState(() => _softKeyboard = true);
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// Привязать введённый код: успех — закрываем диалог, ошибка — показываем под полем
  /// и возвращаем фокус для следующего скана.
  Future<void> submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.onBind(code);
    if (!mounted) return;

    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      // 409 — единственная ошибка, о причине которой можно сказать точно.
      _error = failure is ServerFailure && failure.statusCode == 409
          ? t.stockDetailScreen.bindConflict
          : t.stockDetailScreen.bindFailed;
    });
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.kNeumorphicBg,
      insetPadding: AppInsets.dialogInset,
      title: Text(
        t.stockDetailScreen.bindTitle,
        style: SemiboldTextStyles().semiboldInter16.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      // Тянем содержимое во всю доступную ширину: иначе диалог сжимается по контенту
      // и подписи кнопок переносятся.
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Neumorphic(
              style: NeumorphicStyle(
                shadowLightColor: AppColors.kNeumorphicLight,
                shadowDarkColor: AppColors.kNeumorphicDark,
                intensity: 1,
                color: AppColors.kNeumorphicBg,
                depth: -2,
                shape: NeumorphicShape.flat,
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                onTap: enableSoftKeyboard,
                keyboardType: _softKeyboard
                    ? TextInputType.text
                    : TextInputType.none,
                onSubmitted: (_) => submit(),
                // Кнопка «Привязать» активна только при непустом поле — перерисовываем на ввод.
                onChanged: (_) => setState(() {}),
                cursorColor: AppColors.kTextMuted,
                cursorWidth: 1.5,
                cursorHeight: 20,
                style: RegularTextStyles().regularInter16.copyWith(
                  color: AppColors.kTextMain,
                ),
                decoration: InputDecoration(
                  hintText: t.stockDetailScreen.bindHint,
                  hintStyle: RegularTextStyles().regularInter14.copyWith(
                    color: AppColors.kBorderDashed,
                  ),
                  border: const OutlineInputBorder(
                    borderRadius: AppBorders.kCircular8,
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              AppBoxes.kHeight8,
              Padding(
                padding: AppInsets.left6,
                child: Text(
                  _error!,
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kDanger,
                  ),
                ),
              ),
            ],
            AppBoxes.kHeight12,
            // Кнопки строкой внутри content, а не в actions: в actions «Привязать» переносится
            // под «Отмену». «Отмена» — по содержимому, весь остаток ширины отдан «Привязать»:
            // на 360dp экрана ТСД иначе её подпись ломается на две строки.
            Row(
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(t.stockDetailScreen.cancel),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: _controller.text.trim().isEmpty || _busy
                        ? null
                        : submit,
                    child: Text(t.stockDetailScreen.bindSubmit),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
