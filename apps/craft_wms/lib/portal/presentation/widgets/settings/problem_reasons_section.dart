import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../data/problem_reasons_repository.dart';
import 'access_common.dart';
import 'problem_reason_dialogs.dart';
import 'problem_reason_rows.dart';
import '../ui/portal_annotated_section.dart';
import '../ui/portal_button.dart';

/// Разделы «Причины проблем» и «Варианты решения» в настройках портала (ADHOC-55).
///
/// Что: причины, которыми кладовщик помечает товар на ТСД, с вариантами решения офиса при
/// каждой, и сами варианты — название и действие программы. Удаления нет: причина и вариант
/// выключаются, старые проблемы подписаны ими как были. Системную причину не выключить.
/// Справочник один на оба раздела: варианты причины подписываются названиями вариантов.
class ProblemReasonsSection extends StatefulWidget {
  const ProblemReasonsSection({super.key});

  @override
  State<ProblemReasonsSection> createState() => _ProblemReasonsSectionState();
}

class _ProblemReasonsSectionState extends State<ProblemReasonsSection> {
  final _repo = getIt<ProblemReasonsRepository>();

  ProblemReasonsDirectory? _dir;
  bool _loading = true;

  /// Строка, с которой идёт действие; `reason:` / `variant:` и пусто — заводится новая.
  String? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Перечитать справочник с сервера.
  Future<void> load() async {
    setState(() => _loading = true);
    final res = await _repo.list();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = _text(f), (dir) {
        _dir = dir;
        _error = null;
      });
    });
  }

  /// Завести причину: название, флаг комментария и варианты — в диалоге.
  Future<void> createReason() async {
    final draft = await showProblemReasonDialog(
      context,
      variants: _dir?.resolutions ?? const [],
    );
    if (draft == null || !mounted) return;
    await _run(
      'reason:',
      () => _repo.createReason(
        name: draft.name,
        commentRequired: draft.commentRequired,
        resolutions: draft.resolutions,
      ),
    );
  }

  /// Изменить причину.
  Future<void> editReason(ProblemReason r) async {
    final draft = await showProblemReasonDialog(
      context,
      current: r,
      variants: _dir?.resolutions ?? const [],
    );
    if (draft == null || !mounted) return;
    await _run(
      'reason:${r.code}',
      () => _repo.updateReason(
        r.code,
        name: draft.name,
        commentRequired: draft.commentRequired,
        resolutions: draft.resolutions,
      ),
    );
  }

  /// Выключить причину или включить её снова.
  Future<void> toggleReason(ProblemReason r) => _run(
    'reason:${r.code}',
    () => _repo.updateReason(r.code, isActive: !r.isActive),
  );

  /// Завести вариант решения: название и действие — в диалоге.
  Future<void> createVariant() async {
    final draft = await showResolutionVariantDialog(context);
    if (draft == null || !mounted) return;
    await _run(
      'variant:',
      () => _repo.createResolution(name: draft.name, action: draft.action),
    );
  }

  /// Переименовать вариант; действие не меняется.
  Future<void> editVariant(ResolutionVariant v) async {
    final draft = await showResolutionVariantDialog(context, current: v);
    if (draft == null || draft.name == v.name || !mounted) return;
    await _run(
      'variant:${v.id}',
      () => _repo.updateResolution(v.id, name: draft.name),
    );
  }

  /// Выключить вариант или включить его снова.
  Future<void> toggleVariant(ResolutionVariant v) => _run(
    'variant:${v.id}',
    () => _repo.updateResolution(v.id, isActive: !v.isActive),
  );

  /// Выполнить действие и перечитать справочник; отказ сервера — текстом под списком.
  Future<void> _run(
    String busy,
    Future<Either<Failure, Object?>> Function() action,
  ) async {
    setState(() {
      _busy = busy;
      _error = null;
    });
    final res = await action();
    if (!mounted) return;
    setState(() => _busy = null);
    if (res.isLeft) {
      setState(() => _error = _text(res.left));
      return;
    }
    await load();
  }

  /// Текст ошибки: отказ по существу сервер объясняет сам.
  String _text(Failure f) => switch (f) {
    ServerFailure(:final message?) => message,
    ServerFailure(:final statusCode) => t.portal.problemReasons.errorCode(
      code: statusCode,
    ),
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  /// Настройки изменились на сервере (ADHOC-60): перечитать список. Пока идёт своё действие,
  /// не перечитывать — оно само перечитает список по завершении. Правка в открытом окне не
  /// страдает: окно держит свою копию данных, а список под ним остаётся на экране до ответа.
  void onDataChanged() {
    if (_busy != null) return;
    load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.portal.problemReasons;
    final dir = _dir;
    final names = {for (final v in dir?.resolutions ?? const []) v.id: v.name};
    final loading = _loading && dir == null;
    return DataVersionsListener(
      domains: const {DataDomain.settings},
      onChanged: onDataChanged,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PortalAnnotatedSection(
            title: tr.title,
            description: tr.description,
            action: PortalButton(
              label: tr.add,
              icon: Icons.add,
              busy: _busy == 'reason:',
              onPressed: createReason,
            ),
            child: SettingsListCard(
              loading: loading,
              error: _error,
              rows: [
                for (final r in dir?.reasons ?? const <ProblemReason>[])
                  ProblemReasonRow(
                    reason: r,
                    variantNames: [for (final id in r.resolutions) ?names[id]],
                    busy: _busy == 'reason:${r.code}',
                    onEdit: () => editReason(r),
                    onToggle: () => toggleReason(r),
                  ),
              ],
            ),
          ),
          AppBoxes.kHeight32,
          PortalAnnotatedSection(
            title: tr.variantsTitle,
            description: tr.variantsDescription,
            action: PortalButton(
              label: tr.variantAdd,
              icon: Icons.add,
              busy: _busy == 'variant:',
              onPressed: createVariant,
            ),
            child: SettingsListCard(
              loading: loading,
              rows: [
                for (final v in dir?.resolutions ?? const <ResolutionVariant>[])
                  ResolutionVariantRow(
                    variant: v,
                    busy: _busy == 'variant:${v.id}',
                    onEdit: () => editVariant(v),
                    onToggle: () => toggleVariant(v),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
