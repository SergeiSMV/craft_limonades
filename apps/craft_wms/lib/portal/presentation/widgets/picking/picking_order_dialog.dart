import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../domain/picking/picking_order.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_modal.dart';
import 'picking_order_sections.dart';

/// Окно деталей заказа (P8-03): шапка, строки план/факт с партиями и марками, короба отгрузки,
/// правки реестра; старшему смены — «Снять с исполнителя».
///
/// Окно читает заказ само и перечитывает его, когда на сервере меняется сборка (ADHOC-60):
/// кладовщик пикает на ТСД — факт в открытом окне растёт.
Future<void> showPickingOrderDialog(
  BuildContext context, {
  required PickingOrderSummary order,
  required bool canRelease,
}) => showDialog<void>(
  context: context,
  builder: (_) => _PickingOrderDialog(order: order, canRelease: canRelease),
);

class _PickingOrderDialog extends StatefulWidget {
  const _PickingOrderDialog({required this.order, required this.canRelease});

  final PickingOrderSummary order;
  final bool canRelease;

  @override
  State<_PickingOrderDialog> createState() => _PickingOrderDialogState();
}

class _PickingOrderDialogState extends State<_PickingOrderDialog> {
  final _repo = getIt<PickingOrdersRepository>();

  PickingOrderDetail? _detail;
  Failure? _error;
  bool _releasing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Прочитать заказ. Ошибка тихого перечитывания не подменяет уже показанный заказ.
  Future<void> _load() async {
    final res = await _repo.order(widget.order.id);
    if (!mounted || (res.isLeft && _detail != null)) return;
    setState(() {
      res.fold((f) => _error = f, (d) {
        _detail = d;
        _error = null;
      });
    });
  }

  /// Снять заказ с исполнителя — после подтверждения: кладовщик на ТСД потеряет заказ.
  Future<void> _release() async {
    final order = _detail?.order ?? widget.order;
    final ok = await _confirmRelease(order);
    if (!ok || !mounted) return;
    setState(() => _releasing = true);
    final res = await _repo.release(order.id);
    if (!mounted) return;
    setState(() => _releasing = false);
    res.fold(
      (f) => _snack(t.portal.picking.error(message: pickingErrorText(f))),
      (_) {
        _snack(t.portal.picking.released);
        _load();
      },
    );
  }

  /// Подтверждение снятия: `true` — оператор нажал «Снять».
  Future<bool> _confirmRelease(PickingOrderSummary o) async {
    final p = t.portal.picking;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => PortalModal(
        title: p.releaseTitle,
        content: Text(
          p.releaseText(
            number: docNumber(DocKind.picking, o.number),
            name: o.assigneeName,
          ),
          style: RegularTextStyles().regularInter13.copyWith(
            color: AppColors.kTextMain,
          ),
        ),
        actions: [
          portalCancel(ctx, label: t.portal.common.cancel, result: false),
          PortalButton(
            label: p.releaseConfirm,
            kind: PortalButtonKind.primary,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Показать снекбар.
  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final order = _detail?.order ?? widget.order;
    return DataVersionsListener(
      domains: const {DataDomain.picking},
      onChanged: _load,
      child: PortalModal(
        title: p.detailTitle(number: docNumber(DocKind.picking, order.number)),
        content: _content(),
        actions: [
          portalCancel(context, label: t.portal.common.close),
          if (widget.canRelease && order.releasable)
            PortalButton(
              label: p.releaseButton,
              kind: PortalButtonKind.primary,
              busy: _releasing,
              onPressed: _release,
            ),
        ],
      ),
    );
  }

  /// Заказ разделами; до ответа — загрузка, при ошибке — текст.
  Widget _content() {
    final detail = _detail;
    final error = _error;
    if (detail == null && error != null) {
      return AccessError(
        t.portal.picking.error(message: pickingErrorText(error)),
      );
    }
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PickingOrderHeader(order: detail.order),
        AppBoxes.kHeight16,
        PickingLinesSection(lines: detail.lines),
        AppBoxes.kHeight16,
        PickingBoxesSection(boxes: detail.boxes),
        AppBoxes.kHeight16,
        PickingChangesSection(changes: detail.changes),
        AppBoxes.kHeight16,
        PickingEventsSection(events: detail.events),
      ],
    );
  }
}

/// Текст ошибки: отказ по существу сервер объясняет сам.
String pickingErrorText(Failure f) => switch (f) {
  ServerFailure(:final message, :final statusCode) =>
    message ?? 'HTTP $statusCode',
  NetworkFailure() => t.portal.login.errorNetwork,
  _ => t.portal.login.errorUnknown,
};
