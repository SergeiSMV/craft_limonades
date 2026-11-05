import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../data/problems_repository.dart';
import '../settings/access_common.dart';
import '../ui/portal_button.dart';
import '../ui/portal_choice.dart';
import '../ui/portal_date_picker.dart';
import '../ui/portal_input.dart';
import '../ui/portal_modal.dart';
import 'supplier_picker.dart';

/// Диалог «Решение по проблеме» (P6-07-3, плоский стиль — ADHOC-56): выбор варианта решения из допустимых при причине
/// (справочник, ADHOC-55) и поля его действия — документ списания 1С (номер и дата) или
/// поставщик возврата. Возвращает
/// собранное решение; `null` — оператор передумал. Проводит решение вкладка.
Future<ProblemResolution?> showProblemResolveDialog(
  BuildContext context,
  PortalProblem problem,
) => showDialog<ProblemResolution>(
  context: context,
  builder: (_) => _ResolveDialog(problem: problem),
);

class _ResolveDialog extends StatefulWidget {
  const _ResolveDialog({required this.problem});

  final PortalProblem problem;

  @override
  State<_ResolveDialog> createState() => _ResolveDialogState();
}

class _ResolveDialogState extends State<_ResolveDialog> {
  final _docNumber = TextEditingController();

  /// Выбранный вариант; единственный допустимый выбран сразу.
  late ResolutionVariant? _variant = widget.problem.resolutions.length == 1
      ? widget.problem.resolutions.first
      : null;

  /// Действие выбранного варианта — от него зависят поля.
  String? get _decision => _variant?.action;

  /// Дата документа списания; по умолчанию — сегодня.
  DateTime _docDate = DateTime.now();

  /// Поставщики для возврата — грузятся, только если возврат допустим.
  List<PortalSupplier>? _suppliers;
  late String _supplierId = widget.problem.suggestedSupplierId;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.problem.resolutions.any(
      (r) => r.action == ProblemDecision.supplierReturn,
    )) {
      loadSuppliers();
    }
  }

  @override
  void dispose() {
    _docNumber.dispose();
    super.dispose();
  }

  /// Загрузить справочник поставщиков для выбора возврата.
  Future<void> loadSuppliers() async {
    final res = await getIt<ProblemsRepository>().suppliers();
    if (!mounted) return;
    setState(() {
      res.fold(
        (f) => _error = t.portal.problems.suppliersError(
          message: switch (f) {
            ServerFailure(:final message, :final statusCode) =>
              message ?? 'HTTP $statusCode',
            NetworkFailure() => t.portal.login.errorNetwork,
            _ => t.portal.login.errorUnknown,
          },
        ),
        (list) => _suppliers = list,
      );
    });
  }

  /// Выбрать вариант решения.
  void choose(ResolutionVariant variant) => setState(() {
    _variant = variant;
    _error = null;
  });

  /// Выбрать дату документа списания.
  Future<void> pickDate() async {
    final now = DateTime.now();
    final picked = await showPortalDatePicker(
      context,
      title: t.portal.problems.docDateTitle,
      initial: _docDate,
      first: DateTime(now.year - 1),
      last: now,
    );
    if (picked != null && mounted) setState(() => _docDate = picked);
  }

  /// «Провести»: решение собрано полностью — вернуть его вкладке; иначе — подсказка.
  void submit() {
    final variant = _variant;
    final decision = variant?.action;
    final number = _docNumber.text.trim();
    final error = switch (decision) {
      null => t.portal.problems.needDecision,
      ProblemDecision.writeOff when number.isEmpty => t.portal.problems.needDoc,
      ProblemDecision.regrade when number.isEmpty =>
        t.portal.problems.needDocRegrade,
      ProblemDecision.supplierReturn when _supplierId.isEmpty =>
        t.portal.problems.needSupplier,
      _ => null,
    };
    if (error != null || variant == null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop((
      resolutionId: variant.id,
      decision: variant.action,
      docNumber: number,
      docDate: _iso(_docDate),
      supplierId: _supplierId,
    ));
  }

  String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return PortalModal(
      title: t.portal.problems.dialogTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PortalFieldLabel(t.portal.problems.dialogDecision),
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final r in widget.problem.resolutions)
                PortalChoice(
                  label: r.name,
                  selected: _variant?.id == r.id,
                  onTap: () => choose(r),
                ),
            ],
          ),
          if (_decision != null) ...[portalFieldGap, ..._fields()],
          if (_error case final e?) ...[portalFieldGap, AccessError(e)],
        ],
      ),
      actions: [
        portalCancel(context, label: t.portal.problems.cancel),
        PortalButton(
          label: t.portal.problems.post,
          kind: PortalButtonKind.primary,
          onPressed: submit,
        ),
      ],
    );
  }

  /// Поля выбранного решения.
  List<Widget> _fields() {
    final muted = RegularTextStyles().regularInter13.copyWith(
      color: AppColors.kTextMuted,
    );
    return switch (_decision) {
      // Пересорт (ADHOC-53) проводится документом пересортицы 1С — те же поля, что у списания.
      ProblemDecision.writeOff || ProblemDecision.regrade => [
        PortalFieldLabel(
          _decision == ProblemDecision.regrade
              ? t.portal.problems.docNumberRegrade
              : t.portal.problems.docNumber,
        ),
        PortalInput(
          controller: _docNumber,
          hint: '',
          autofocus: true,
          onSubmitted: (_) => submit(),
        ),
        AppBoxes.kHeight8,
        Row(
          children: [
            Expanded(
              child: Text(
                t.portal.problems.docDate(date: fullDate(_docDate)),
                style: RegularTextStyles().regularInter13.copyWith(
                  color: AppColors.kTextMain,
                ),
              ),
            ),
            PortalButton(
              label: t.portal.problems.docDatePick,
              icon: Icons.calendar_today_outlined,
              onPressed: pickDate,
            ),
          ],
        ),
      ],
      ProblemDecision.place => [
        Text(t.portal.problems.placeHint, style: muted),
      ],
      ProblemDecision.supplierReturn => [
        Text(t.portal.problems.returnHint, style: muted),
        AppBoxes.kHeight12,
        if (_suppliers == null && _error == null)
          const Center(
            child: SizedBox.square(
              dimension: AppSizes.kIcon20,
              child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
            ),
          )
        else if (_suppliers != null)
          SupplierPicker(
            suppliers: _suppliers!,
            selectedId: _supplierId,
            onSelected: (id) => setState(() {
              _supplierId = id;
              _error = null;
            }),
          ),
      ],
      _ => const [],
    };
  }
}
