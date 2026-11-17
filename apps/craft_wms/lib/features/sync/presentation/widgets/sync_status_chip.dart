import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../bloc/sync_status_cubit.dart';
import '../bloc/sync_status_state.dart';

/// Индикатор очереди и связи в шапке главного меню (P2-07).
///
/// Что: одним значком - сколько работы ещё не уехало и знаем ли мы о связи с сервером.
/// Зачем: до него неотправленное было видно только тому, кто догадается открыть служебный
///        экран из меню в шапке. Кладовщик, привязавший ШК в мёртвой зоне, уходил со склада,
///        не зная, что операция всё ещё лежит на устройстве.
/// Как: одно состояние из [SyncStatusCubit]; правило «что важнее показать» живёт в
///      [SyncStatusState.badge], а не растаскано по веткам виджета.
///
/// **Значок кликабельный и ведёт на экран разбора.** Показать «3 ждут» и не дать ничего с этим
/// сделать - хуже, чем не показывать: это тревога без выхода.
///
/// При пустой очереди значок остаётся видимым (тихая галочка). Прятать его совсем - значит
/// сделать «всё хорошо» неотличимым от «индикатор сломался»; тихое подтверждение стоит того
/// места, которое занимает.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key, required this.onTap});

  /// Открыть экран несинхронизированного.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SyncStatusCubit, SyncStatusState>(
      builder: (context, state) {
        final look = _lookFor(state);
        return Tooltip(
          message: look.hint,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppSizes.kIcon16),
            child: Padding(
              padding: AppInsets.h8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  look.leading,
                  if (state.total > 0) ...[
                    AppBoxes.kWidth4,
                    // Число - белым во всех состояниях, а не в цвете сигнала: сигнал несёт
                    // иконка, а красный на тёмной шапке даёт для текста 3.9:1 при нужных 4.5.
                    Text(
                      '${state.total}',
                      style: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kTileText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Внешний вид и подпись для текущего состояния.
  _ChipLook _lookFor(SyncStatusState state) {
    final offline = state.showOffline ? ' · ${t.homeScreen.queueOffline}' : '';
    return switch (state.badge) {
      SyncBadge.allSent => _ChipLook(
        leading: const Icon(
          Icons.cloud_done_outlined,
          size: AppSizes.kIcon20,
          color: AppColors.kSidebarMuted,
        ),
        hint: t.homeScreen.queueAllSent,
      ),
      SyncBadge.sending => _ChipLook(
        leading: const SizedBox(
          width: AppSizes.kIcon20,
          height: AppSizes.kIcon20,
          child: CircularProgressIndicator(
            strokeWidth: AppSizes.kIcon2,
            color: AppColors.kTileText,
          ),
        ),
        hint: t.homeScreen.queueSending,
      ),
      SyncBadge.waiting => _ChipLook(
        leading: const Icon(
          Icons.cloud_upload_outlined,
          size: AppSizes.kIcon20,
          color: AppColors.kBadgeWarningBg,
        ),
        hint: t.homeScreen.queueWaiting(count: state.pending) + offline,
      ),
      SyncBadge.needsAttention => _ChipLook(
        leading: const Icon(
          Icons.error_outline,
          size: AppSizes.kIcon20,
          color: AppColors.kDanger,
        ),
        hint: t.homeScreen.queueNeedsAttention(count: state.rejected) + offline,
      ),
    };
  }
}

/// Внешний вид значка для одного состояния.
class _ChipLook {
  const _ChipLook({required this.leading, required this.hint});

  final Widget leading;
  final String hint;
}
