import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../data/problems_repository.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_date_picker.dart';
import '../common/portal_dialog.dart';
import '../common/portal_filter_chip.dart';
import '../common/portal_text_field.dart';
import 'supplier_picker.dart';

/// Диалог «Решение по проблеме» (P6-07-3): выбор варианта решения из допустимых при причине
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
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return PortalDialog(
      title: t.portal.problems.dialogTitle,
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppSizes.kContentMaxWidth / 2,
        ),
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.portal.problems.dialogDecision,
                style: SemiboldTextStyles().semiboldInter14.copyWith(
                  color: AppColors.kTextMain,
                ),
              ),
              AppBoxes.kHeight8,
              Wrap(
                spacing: AppSizes.kChipSpacing,
                runSpacing: AppSizes.kChipSpacing,
                children: [
                  for (final r in widget.problem.resolutions)
                    PortalFilterChip(
                      label: r.name,
                      selected: _variant?.id == r.id,
                      onTap: () => choose(r),
                    ),
                ],
              ),
              AppBoxes.kHeight16,
              ..._fields(muted),
              if (_error != null) ...[
                AppBoxes.kHeight12,
                Text(
                  _error!,
                  style: RegularTextStyles().regularInter14.copyWith(
                    color: AppColors.kDanger,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.portal.problems.cancel),
        ),
        NeumorphicTextButton(
          label: t.portal.problems.post,
          accent: true,
          onPressed: submit,
        ),
      ],
    );
  }

  /// Поля выбранного решения.
  List<Widget> _fields(TextStyle muted) => switch (_decision) {
    // Пересорт (ADHOC-53) проводится документом пересортицы 1С — те же поля, что у списания.
    ProblemDecision.writeOff || ProblemDecision.regrade => [
      PortalTextField(
        controller: _docNumber,
        hint: _decision == ProblemDecision.regrade
            ? t.portal.problems.docNumberRegrade
            : t.portal.problems.docNumber,
        autofocus: true,
        onSubmitted: (_) => submit(),
      ),
      AppBoxes.kHeight8,
      Row(
        children: [
          Expanded(
            child: Text(
              t.portal.problems.docDate(date: fullDate(_docDate)),
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ),
          TextButton(
            onPressed: pickDate,
            child: Text(t.portal.problems.docDatePick),
          ),
        ],
      ),
    ],
    ProblemDecision.place => [Text(t.portal.problems.placeHint, style: muted)],
    ProblemDecision.supplierReturn => [
      Text(t.portal.problems.returnHint, style: muted),
      AppBoxes.kHeight12,
      if (_suppliers == null && _error == null)
        const Center(child: CircularProgressIndicator())
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
