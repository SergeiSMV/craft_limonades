import 'package:flutter/material.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../di/injection.dart';
import '../gen/strings.g.dart';
import '../printer/printer_service.dart';
import '../theme/regular_text.dart';

/// Плашка «Подключаюсь к принтеру…» внизу экрана, пока сервис печати переподключается (P6-04).
///
/// Зачем: после выключенного и снова включённого принтера переподключение идёт несколько
/// секунд. Без подсказки кладовщик решил бы, что нажатие не сработало, и нажал «Печать» снова.
/// Как: слушает [PrinterService.reconnecting] и рисует плашку поверх любого экрана - печатают
/// из разных мест, и учить каждое показывать её значило бы повторять это везде.
class PrinterReconnectBanner extends StatelessWidget {
  const PrinterReconnectBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<bool>(
          valueListenable: getIt<PrinterService>().reconnecting,
          builder: (context, active, _) => !active
              ? const SizedBox.shrink()
              : Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: AppInsets.all8,
                      child: Material(
                        color: AppColors.kTextMain,
                        borderRadius: AppBorders.kCircular8,
                        child: Padding(
                          padding: AppInsets.all12,
                          child: Row(
                            children: [
                              const SizedBox.square(
                                dimension: AppSizes.kIcon18,
                                child: CircularProgressIndicator(
                                  strokeWidth: AppSizes.kIcon2,
                                  color: Colors.white,
                                ),
                              ),
                              AppBoxes.kWidth12,
                              Expanded(
                                child: Text(
                                  t.printer.reconnecting,
                                  style: RegularTextStyles().regularInter14
                                      .copyWith(color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
