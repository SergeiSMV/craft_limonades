import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/neumorphic_choice.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_view.dart';
import '../bloc/picking_order_cubit.dart';
import '../widgets/picking_format.dart';
import '../widgets/picking_scan_actions.dart';
import '../widgets/picking_sheets.dart';

/// Заказ сборки (P9-06): строки с подсказкой источника, короба отгрузки, пик сканом.
///
/// Взять, отказаться, новый короб и «не хватает» - со связью; пик и возврат пика - очередью,
/// без связи заказ открывается из слепка терминала.
@RoutePage()
class PickingOrderPage extends StatelessWidget {
  const PickingOrderPage({super.key, required this.orderId, this.number});

  final String orderId;

  /// Номер сборки для заголовка, пока заказ не загружен.
  final int? number;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<PickingOrderCubit>(param1: orderId)..load(),
      child: _OrderView(number: number),
    );
  }
}

class _OrderView extends StatefulWidget {
  const _OrderView({this.number});

  final int? number;

  @override
  State<_OrderView> createState() => _OrderViewState();
}

class _OrderViewState extends State<_OrderView>
    with HardwareScanListener, PickingScanActions {
  @override
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void goBack() => context.router.maybePop();

  /// Подсказки по итогу действий - один раз.
  void onNotice(BuildContext context, PickingOrderState state) {
    final n = state.notice;
    if (n == null) return;
    cubit.clearNotice();
    final p = t.picking;
    switch (n) {
      case OrderNoticeFailed(:final failure):
        snack(
          failure is NetworkFailure
              ? p.needsConnection
              : p.actionFailed(reason: failureReason(failure)),
        );
      case OrderNoticeTaken():
        snack(p.takenMine);
      case OrderNoticeReleased():
        snack(p.released);
        goBack();
      case OrderNoticeBoxAdded(:final seq):
        snack(p.boxAdded(seq: seq));
      case OrderNoticeBoxDropped(:final seq):
        snack(p.boxDropped(seq: seq));
      case OrderNoticeDone(:final unpick, :final queued):
        snack(switch ((unpick, queued)) {
          (false, false) => p.picked,
          (false, true) => p.pickedQueued,
          (true, false) => p.unpicked,
          (true, true) => p.unpickedQueued,
        });
      case OrderNoticeRejected(:final reason):
        snack(p.rejected(reason: reason));
      case OrderNoticeCompleted(:final shipment):
        snack(p.completed);
        context.router.replace(
          PickingShipmentRoute(
            orderId: shipment.id,
            number: shipment.number,
            shipment: shipment,
            printNow: true,
          ),
        );
      case OrderNoticeShortage(:final set, :final result):
        final number = result.stocktakeNumber;
        snack(
          !set
              ? p.shortageCleared
              : number == null
              ? p.shortageNoCount
              : result.created
              ? p.shortageCreated(number: docNumber(DocKind.stocktake, number))
              : p.shortageExists(number: docNumber(DocKind.stocktake, number)),
        );
    }
  }

  /// Отказаться от заказа - с подтверждением: собранное остаётся в коробах.
  Future<void> release() async {
    final ok = await confirmPicking(
      context,
      title: t.picking.releaseTitle,
      body: t.picking.releaseBody,
      yes: t.picking.releaseYes,
      no: t.picking.releaseNo,
    );
    if (ok && mounted) await cubit.release();
    refocusScan();
  }

  /// Долгое нажатие на короб: убрать пустой, заведённый по ошибке, - с подтверждением. Короб с
  /// товаром (и своими пиками в очереди) не убирается: сначала вернуть пики.
  Future<void> dropBox(PickingOrderView view, PickingBox box) async {
    if (view.picksIn(box.loadUnitId).isNotEmpty) {
      snack(t.picking.boxNotEmpty(seq: box.seq));
      return;
    }
    final ok = await confirmPicking(
      context,
      title: t.picking.dropBoxTitle(seq: box.seq),
      body: t.picking.dropBoxBody,
      yes: t.picking.dropBoxYes,
      no: t.picking.dropBoxNo,
    );
    if (ok && mounted) await cubit.dropBox(box);
    refocusScan();
  }

  /// «Завершить сборку» - с подтверждением: товар уходит из ячеек в короба отгрузки.
  Future<void> complete() async {
    final ok = await confirmPicking(
      context,
      title: t.picking.completeTitle,
      body: t.picking.completeBody,
      yes: t.picking.completeYes,
      no: t.picking.completeNo,
    );
    if (ok && mounted) await cubit.complete();
    refocusScan();
  }

  /// Вернуть пик - с подтверждением.
  Future<void> unpick(PickingPick pick) async {
    final ok = await confirmPicking(
      context,
      title: t.picking.unpickTitle,
      body: t.picking.unpickBody,
      yes: t.picking.unpickYes,
      no: t.picking.unpickNo,
    );
    if (ok && mounted) await cubit.unpick(pick);
    refocusScan();
  }

  Future<void> openLine(PickingOrderView view, PickingLine line) async {
    await showLineSheet(
      context,
      view: view,
      line: line,
      canAct: view.order.mine,
      canShortage: view.order.mine && !view.fromCache,
      onUnpick: unpick,
      onShortage: () => cubit.shortage(line, set: !line.shortage),
    );
    refocusScan();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PickingOrderCubit, PickingOrderState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) {
        final number = state.view?.order.number ?? widget.number;
        return SystemUiWrapper(
          style: StatusBarStyle.light,
          child: Scaffold(
            // Текст здесь вводит только сканер - под клавиатуру экран не сжимается.
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
                goBack: goBack,
                trailing: _menu(state),
              ),
            ),
            body: SafeArea(top: false, child: _body(state)),
          ),
        );
      },
    );
  }

  Widget _body(PickingOrderState state) {
    final view = state.view;
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    if (view == null) {
      if (state.status == PickingOrderStatus.loading) {
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
    final order = view.order;
    final mine = order.mine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mine)
          Padding(
            padding: AppInsets.h8 + AppInsets.v16,
            child: ScanField(
              controller: scanController,
              focusNode: scanFocus,
              hint: t.picking.scanHint,
              onSubmitted: onScan,
            ),
          )
        else
          AppBoxes.kHeight16,
        Expanded(
          child: ListView(
            padding: AppInsets.h8,
            children: [
              if (view.fromCache)
                Padding(
                  padding: AppInsets.bottom8,
                  child: Text(
                    t.picking.fromCache,
                    style: muted.copyWith(color: AppColors.kBadgeWarningText),
                  ),
                ),
              for (final s in orderLines(
                invoiceNumber: order.invoiceNumber,
                orderNumber: order.orderNumber,
                client: order.client,
                direction: order.direction,
                registryDate: order.registryDate,
              ))
                Text(s, style: muted),
              if (!mine) Text(t.picking.notMine, style: muted),
              if (mine) ...[
                SectionTitle(title: t.picking.sectionBoxes),
                if (order.boxes.isEmpty)
                  Text(t.picking.noBoxes, style: muted)
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final b in order.boxes)
                        // Долгое нажатие - убрать короб, заведённый по ошибке (без связи - нет).
                        GestureDetector(
                          onLongPress: view.fromCache || state.busy
                              ? null
                              : () => dropBox(view, b),
                          child: NeumorphicChoice(
                            label: t.picking.boxLabel(
                              seq: b.seq,
                              count: view.picksIn(b.loadUnitId).length,
                            ),
                            selected: b.loadUnitId == view.currentBoxId,
                            onPressed: () => cubit.selectBox(b.loadUnitId),
                          ),
                        ),
                    ],
                  ),
              ],
              SectionTitle(title: t.picking.sectionLines),
              for (final l in view.activeLines)
                Padding(
                  padding: AppInsets.bottom8,
                  child: NeumorphicLineTile(
                    title: l.goodName,
                    subtitle: lineLines(view, l).join('\n'),
                    // «Не хватает» - отметкой цветом, чтобы строка выделялась в списке.
                    note: l.shortage ? t.picking.shortageMark : null,
                    noteColor: AppColors.kBadgeCriticalText,
                    trailing: view.done(l)
                        ? t.picking.doneMark
                        : l.shortage
                        ? t.picking.shortageTrailing
                        : null,
                    onTap: () => openLine(view, l),
                  ),
                ),
              AppBoxes.kHeight8,
            ],
          ),
        ),
        Padding(
          padding: AppInsets.all16,
          child: NeumorphicActionStack(
            buttons: [
              if (!mine)
                NeumorphicActionButton(
                  label: t.picking.take,
                  icon: MdiIcons.handBackRightOutline,
                  onPressed: state.busy ? () {} : cubit.take,
                )
              else
                NeumorphicActionButton(
                  label: t.picking.newBox,
                  icon: MdiIcons.packageVariantPlus,
                  onPressed: state.busy ? () {} : cubit.addBox,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Меню шапки своего заказа: «Завершить сборку» и «Отказаться» - редкие действия, на экране
  /// остаётся только «Новый короб».
  Widget? _menu(PickingOrderState state) {
    final view = state.view;
    if (view == null || !view.order.mine) return null;
    return PopupMenuButton<void>(
      enabled: !state.busy,
      icon: const Icon(Icons.more_vert, color: AppColors.kNeumorphicBg),
      itemBuilder: (context) => [
        // Завершить - только со связью: без неё сервер не знает всего взятого.
        if (!view.fromCache)
          PopupMenuItem<void>(onTap: complete, child: Text(t.picking.complete)),
        PopupMenuItem<void>(onTap: release, child: Text(t.picking.release)),
      ],
    );
  }
}
