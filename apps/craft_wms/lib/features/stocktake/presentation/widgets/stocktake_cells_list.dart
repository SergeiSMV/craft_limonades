import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../../core/widgets/section_title.dart';
import '../../domain/stocktake_models.dart';
import '../bloc/stocktake_cells_cubit.dart';
import 'stocktake_format.dart';

/// Список ячеек пересчёта (P10-04): ход, свои, свободные; без связи — начатые подсчёты.
class StocktakeCellsList extends StatelessWidget {
  const StocktakeCellsList({
    super.key,
    required this.state,
    required this.onRetry,
    required this.onTapCell,
    required this.onOpenDraft,
  });

  final StocktakeCellsState state;
  final Future<void> Function() onRetry;
  final ValueChanged<StocktakeCell> onTapCell;
  final ValueChanged<StocktakeCellView> onOpenDraft;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    if (state.status == StocktakeCellsStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final info = state.info;
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView(
        padding: AppInsets.h8,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (state.status == StocktakeCellsStatus.error)
            Padding(
              padding: AppInsets.bottom8,
              child: Text(
                state.failure is NetworkFailure
                    ? t.stocktake.offline
                    : t.stocktake.loadFailed,
                style: muted.copyWith(color: AppColors.kBadgeWarningText),
              ),
            ),
          if (info != null) ...[
            Text(
              t.stocktake.scope(scope: scopeLabel(info.scopeKind)),
              style: muted,
            ),
            Text(
              t.stocktake.progress(
                counted: info.counted,
                total: info.cells.length,
              ),
              style: muted,
            ),
            AppBoxes.kHeight8,
          ],
          if (state.drafts.isNotEmpty &&
              state.status == StocktakeCellsStatus.error) ...[
            SectionTitle(title: t.stocktake.sectionDrafts),
            for (final d in state.drafts)
              _tile(
                title: d.cell.address,
                subtitle: t.stocktake.draftLine(
                  lines: d.lines.length,
                  boxes: d.boxes.length,
                ),
                onTap: () => onOpenDraft(d.view),
              ),
          ],
          if (state.mine.isNotEmpty) ...[
            SectionTitle(title: t.stocktake.sectionMine),
            for (final c in state.mine)
              _tile(
                title: c.address,
                subtitle: myCellStatus(c),
                trailing: t.stocktake.release,
                onTap: () => onTapCell(c),
              ),
          ],
          if (state.status == StocktakeCellsStatus.loaded) ...[
            SectionTitle(title: t.stocktake.sectionFree),
            if (state.free.isEmpty)
              Text(t.stocktake.emptyFree, style: muted)
            else
              for (final c in state.free)
                _tile(
                  title: c.address,
                  trailing: t.stocktake.take,
                  onTap: () => onTapCell(c),
                ),
          ],
          AppBoxes.kHeight8,
        ],
      ),
    );
  }

  Widget _tile({
    required String title,
    String? subtitle,
    String? trailing,
    required VoidCallback onTap,
  }) => Padding(
    padding: AppInsets.bottom8,
    child: NeumorphicLineTile(
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
    ),
  );
}
