import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/auth/session_rights.dart';
import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/picking_shipment.dart';
import '../bloc/picking_shipment_cubit.dart';
import '../widgets/picking_format.dart';

/// Собранный заказ (P9-07): ярлыки «короб N из M» и отгрузка сканом ярлыка каждого короба.
///
/// Сразу после «Завершить сборку» экран открывается с ответом сервера ([shipment]) и печатает
/// ярлыки сам ([printNow]); из списка «СБОРКА» - загружает заказ. Когда отсканированы все
/// короба, заказ отгружается - со связью.
@RoutePage()
class PickingShipmentPage extends StatelessWidget {
  const PickingShipmentPage({
    super.key,
    required this.orderId,
    this.number,
    this.shipment,
    this.printNow = false,
  });

  final String orderId;

  /// Номер сборки для заголовка, пока заказ не загружен.
  final int? number;
  final PickingShipment? shipment;
  final bool printNow;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final cubit = getIt<PickingShipmentCubit>(param1: orderId);
        cubit.load(shipment: shipment).then((_) {
          if (printNow) cubit.printLabels();
        });
        return cubit;
      },
      child: _ShipmentView(number: number),
    );
  }
}

class _ShipmentView extends StatefulWidget {
  const _ShipmentView({this.number});

  final int? number;

  @override
  State<_ShipmentView> createState() => _ShipmentViewState();
}

class _ShipmentViewState extends State<_ShipmentView>
    with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();

  PickingShipmentCubit get cubit => context.read<PickingShipmentCubit>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Скан ярлыка короба - из сканера или поля ввода.
  void onScan(String raw) {
    _scanController.clear();
    if (raw.trim().isEmpty) return;
    cubit.scan(raw.trim());
  }

  /// Напечатать ярлык одного короба: первый раз - без права, повтор - по праву.
  Future<void> printBox(PickingShipmentBox box) async {
    if (box.labelsPrinted > 0 &&
        !sessionCan(context, Rights.tsdPickingReprint)) {
      snack(t.picking.reprintDenied);
      return;
    }
    await cubit.printBox(box);
  }

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Подсказки по итогу действий - один раз.
  void onNotice(BuildContext context, PickingShipmentState state) {
    final n = state.notice;
    if (n == null) return;
    cubit.clearNotice();
    final p = t.picking;
    switch (n) {
      case ShipmentNoticeFailed(:final failure):
        snack(
          failure is NetworkFailure
              ? p.needsConnection
              : p.actionFailed(reason: failureReason(failure)),
        );
      case ShipmentNoticePrinted(:final count):
        snack(p.printed(count: count));
      case ShipmentNoticePrintFailed(:final reason):
        snack(p.printFailed(reason: reason));
      case ShipmentNoticeScanned(:final seq, :final again):
        snack(
          seq == null
              ? p.boxForeign
              : again
              ? p.boxAgain(seq: seq)
              : p.boxScanned(seq: seq),
        );
      case ShipmentNoticeReturnLeft(:final qty):
        snack(p.returnLeft(qty: fmtQty(qty)));
      case ShipmentNoticeShipped():
        snack(p.shipped);
        context.router.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PickingShipmentCubit, PickingShipmentState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) {
        final number = state.shipment?.number ?? widget.number;
        return SystemUiWrapper(
          style: StatusBarStyle.light,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: AppColors.kNeumorphicBg,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: Colors.transparent,
              elevation: 0,
              toolbarHeight: AppSizes.kIcon60,
              flexibleSpace: ClipRRect(
                borderRadius: AppBorders.kBottom10,
                child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
              ),
              title: PageHeader(
                title: number == null
                    ? t.picking.title
                    : docNumber(DocKind.picking, number),
                goBack: () => context.router.maybePop(),
              ),
            ),
            body: SafeArea(top: false, child: _body(state)),
          ),
        );
      },
    );
  }

  Widget _body(PickingShipmentState state) {
    final s = state.shipment;
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    if (s == null) {
      if (state.status == PickingShipmentStatus.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      final f = state.failure;
      return Padding(
        padding: AppInsets.h8 + AppInsets.v16,
        child: Text(
          f is NetworkFailure
              ? t.picking.needsConnection
              : t.picking.actionFailed(
                  reason: f == null ? '' : failureReason(f),
                ),
          style: muted.copyWith(color: AppColors.kBadgeWarningText),
        ),
      );
    }
    final p = t.picking;
    // Повторная печать - по праву: без него испорченный ярлык перепечатывает старший смены.
    final canPrint =
        s.unprinted.isNotEmpty || sessionCan(context, Rights.tsdPickingReprint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!s.shipped)
          Padding(
            padding: AppInsets.h8 + AppInsets.v16,
            child: ScanField(
              controller: _scanController,
              focusNode: _scanFocus,
              hint: p.shipmentScanHint,
              onSubmitted: onScan,
            ),
          )
        else
          AppBoxes.kHeight16,
        Expanded(
          child: ListView(
            padding: AppInsets.h8,
            children: [
              for (final line in orderLines(
                invoiceNumber: s.invoiceNumber,
                orderNumber: s.orderNumber,
                client: s.client,
                direction: s.direction,
                registryDate: s.registryDate,
              ))
                Text(line, style: muted),
              Text(
                s.shipped
                    ? p.alreadyShipped
                    : s.isPartial
                    ? p.statusPartial
                    : p.statusPicked,
                style: muted,
              ),
              if (!s.shipped && s.returnLeft > 0)
                Text(p.returnLeft(qty: fmtQty(s.returnLeft)), style: muted),
              if (!s.shipped && s.boxes.isEmpty)
                Text(p.nothingToShip, style: muted)
              else if (!s.shipped)
                Text(
                  p.shipmentProgress(
                    done: state.scanned.length,
                    count: s.boxes.length,
                  ),
                  style: muted,
                ),
              SectionTitle(title: p.sectionBoxes),
              for (final b in s.boxes)
                Padding(
                  padding: AppInsets.bottom8,
                  child: NeumorphicLineTile(
                    title: p.labelBox(seq: b.seq, count: s.boxes.length),
                    subtitle: shipmentBoxLines(
                      b,
                      scanned: state.scanned.contains(b.loadUnitId),
                    ).join('\n'),
                    trailing: state.scanned.contains(b.loadUnitId)
                        ? p.doneMark
                        : null,
                    // Касание - ярлык этого короба: испорченный перепечатать.
                    onTap: () => printBox(b),
                  ),
                ),
              AppBoxes.kHeight8,
            ],
          ),
        ),
        // Коробов нет - по всем позициям «не хватает»: заказ закрывается без отгрузки товара.
        if (!s.shipped && s.boxes.isEmpty)
          Padding(
            padding: AppInsets.all16,
            child: NeumorphicActionStack(
              buttons: [
                NeumorphicActionButton(
                  label: p.closeEmpty,
                  icon: MdiIcons.checkAll,
                  onPressed: state.busy ? () {} : cubit.closeEmpty,
                ),
              ],
            ),
          )
        else if (!s.shipped && canPrint)
          Padding(
            padding: AppInsets.all16,
            child: NeumorphicActionStack(
              buttons: [
                NeumorphicActionButton(
                  label: s.unprinted.isEmpty ? p.reprintLabels : p.printLabels,
                  icon: MdiIcons.printerOutline,
                  onPressed: state.busy ? () {} : cubit.printLabels,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
