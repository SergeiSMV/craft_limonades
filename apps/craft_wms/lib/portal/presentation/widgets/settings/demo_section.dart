import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../domain/demo/demo_repository.dart';
import '../ui/portal_annotated_section.dart';
import '../ui/portal_button.dart';
import '../ui/portal_modal.dart';

/// Раздел «Демо-данные» в настройках портала демо-сервера (ADHOC-67).
///
/// Что: объяснение, что это демо, и кнопка сброса данных к исходным.
/// Зачем: показ может уйти далеко от исходного склада (закрыты задания, отгружены заказы), и
///        ждать ночного сброса незачем.
/// Как: сброс стирает базу демо и заполняет заново — сеанс тоже пропадает, поэтому после
///      успеха портал выходит на экран входа. Отказ сервера («недавно сбрасывали») — текстом.
class DemoSection extends StatefulWidget {
  const DemoSection({super.key});

  @override
  State<DemoSection> createState() => _DemoSectionState();
}

class _DemoSectionState extends State<DemoSection> {
  final _repo = getIt<DemoRepository>();

  bool _busy = false;
  String? _error;

  /// Сбросить демо после подтверждения; успех — выход на экран входа.
  Future<void> reset() async {
    if (!await _confirm() || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await _repo.reset();
    if (!mounted) return;
    if (res.isRight) {
      await context.read<AuthCubit>().logout();
      return;
    }
    setState(() {
      _busy = false;
      _error = switch (res.left) {
        ServerFailure(:final message?) => message,
        NetworkFailure() => t.portal.login.errorNetwork,
        _ => t.portal.login.errorUnknown,
      };
    });
  }

  /// Подтверждение сброса.
  Future<bool> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => PortalModal(
        title: t.portal.demo.resetTitle,
        content: Text(
          t.portal.demo.resetBody,
          style: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kTextMain,
          ),
        ),
        actions: [
          portalCancel(ctx, label: t.portal.demo.cancel, result: false),
          PortalButton(
            label: t.portal.demo.resetConfirm,
            kind: PortalButtonKind.primary,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return PortalAnnotatedSection(
      title: t.portal.demo.title,
      description: t.portal.demo.description,
      action: PortalButton(
        label: t.portal.demo.reset,
        icon: Icons.restart_alt,
        busy: _busy,
        onPressed: reset,
      ),
      child: error == null
          ? const SizedBox.shrink()
          : Text(
              error,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kDanger,
              ),
            ),
    );
  }
}
