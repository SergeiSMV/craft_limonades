import 'package:flutter/material.dart';

import '../../../../core/gen/strings.g.dart';

/// Подтверждения экрана ячеек пересчёта (P10-04).

/// Отказаться от ячейки: начатый подсчёт отбросится. `true` - отказаться.
Future<bool> confirmRelease(BuildContext context) => _confirm(
  context,
  title: t.stocktake.releaseTitle,
  body: t.stocktake.releaseBody,
  yes: t.stocktake.releaseYes,
  no: t.stocktake.releaseNo,
);

/// Закрыть пересчёт; [uncounted] - сколько ячеек не подсчитано. `true` - закрыть.
Future<bool> confirmClose(BuildContext context, {required int uncounted}) =>
    _confirm(
      context,
      title: t.stocktake.closeTitle,
      body: uncounted == 0
          ? t.stocktake.closeBodyAll
          : t.stocktake.closeBodyUncounted(count: uncounted),
      yes: t.stocktake.closeYes,
      no: t.stocktake.closeNo,
    );

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String yes,
  required String no,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(no),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(yes),
        ),
      ],
    ),
  );
  return ok ?? false;
}
