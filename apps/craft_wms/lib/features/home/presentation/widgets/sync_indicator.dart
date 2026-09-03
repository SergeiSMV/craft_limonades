import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';

/// Индикатор обновления справочников в шапке главного меню (ADHOC-10).
///
/// Что: маленький кружок ожидания, видимый только пока идёт обновление.
/// Зачем: до него обновление справочников ничем себя не выдавало — кладовщик видел лишь
///        короткий снэкбар «обновляю» и дальше не знал, идёт ли что-то и стоит ли ждать.
/// Как: подписан на наблюдаемое состояние службы синхронизации, поэтому виден и при
///      обновлении, запущенном автоматически после входа, — а оно идёт ровно тогда, когда
///      главное меню появляется на экране.
///
/// Индикатор стоит **рядом** с иконкой меню, а не вместо неё: «Обновить справочники» —
/// пункт всплывающего меню, и подменив иконку кружком, мы закрыли бы доступ к меню на всё
/// время обновления.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key, required this.running});

  /// Идёт ли обновление справочников.
  final ValueListenable<bool> running;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: running,
      builder: (context, busy, _) => !busy
          ? const SizedBox.shrink()
          : Padding(
              padding: AppInsets.right8,
              child: Tooltip(
                message: t.homeScreen.syncInProgressHint,
                child: const SizedBox(
                  width: AppSizes.kIcon20,
                  height: AppSizes.kIcon20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.kTileText,
                  ),
                ),
              ),
            ),
    );
  }
}
