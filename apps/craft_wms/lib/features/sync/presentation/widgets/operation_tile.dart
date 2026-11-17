import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/outbox/outbox_operation.dart';
import '../../../stock/domain/catalog_repository.dart';

/// Строка операции в списке несинхронизированного (P2-06).
///
/// Что: описание операции по-человечески, её причина отказа и - для отклонённых - разбор.
/// Зачем: в очереди операция лежит типом и телом JSON. Кладовщику нужно понять, что именно
///        не уехало, чтобы решить: повторить или отбросить.
/// Как: описание собирается из тела; для привязки ШК товар подтягивается из кэша справочника
///      по идентификатору - «привязать ШК 48513883» без названия товара решению не помогает.
class OperationTile extends StatefulWidget {
  const OperationTile({
    super.key,
    required this.operation,
    this.onRetry,
    this.onDiscard,
    this.onFix,
  });

  final OutboxOperation operation;

  /// Вернуть операцию в очередь. `null` - операция и так ожидает, разбирать нечего.
  final VoidCallback? onRetry;

  /// Убрать операцию совсем. `null` по той же причине.
  final VoidCallback? onDiscard;

  /// Вернуть отклонённый сеанс в правку (ADHOC-41); `null` - у операции нет сеанса.
  final VoidCallback? onFix;

  @override
  State<OperationTile> createState() => _OperationTileState();
}

class _OperationTileState extends State<OperationTile> {
  /// Запрос названия товара заводится ОДИН раз, а не в `build`.
  ///
  /// Future, созданный в `build`, даёт вечную перерисовку: его завершение перестраивает
  /// виджет, перестройка создаёт новый Future, тот завершается - и так по кругу. На экране
  /// это поток запросов к базе без остановки, в тестах - `pumpAndSettle`, который никогда
  /// не дожидается покоя.
  late final Future<String?> _goodName = _loadGoodName();

  OutboxOperation get operation => widget.operation;

  /// Штрихкод из тела операции; у приёмки его нет, и строка не показывается.
  String get _barcode => operation.payload['barcode'] as String? ?? '';

  /// Название товара из локального справочника; `null` - товара в кэше нет либо операция
  /// его и не называет (отвязка адресуется только кодом).
  Future<String?> _loadGoodName() async {
    final id = operation.payload['good_id'] as String?;
    if (id == null) return null;
    final good = await getIt<CatalogRepository>().goodById(id);
    return good?.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (operation.kind) {
      OutboxKind.bindBarcode => t.syncQueue.opBind(barcode: _barcode),
      OutboxKind.unbindBarcode => t.syncQueue.opUnbind(barcode: _barcode),
      OutboxKind.receiptSubmit => t.syncQueue.opReceipt(
        count:
            (operation.payload['lines'] as List<dynamic>? ?? const []).length,
      ),
      OutboxKind.putawaySubmit => t.syncQueue.opPutaway(
        count:
            (operation.payload['lines'] as List<dynamic>? ?? const []).length,
      ),
      OutboxKind.movementSubmit => t.syncQueue.opMovement(
        count:
            (operation.payload['lines'] as List<dynamic>? ?? const []).length,
      ),
      OutboxKind.problemSubmit => t.syncQueue.opProblem,
      OutboxKind.returnSubmit => t.syncQueue.opReturn(
        count: (operation.payload['problem_ids'] as List<dynamic>? ?? const [])
            .length,
      ),
      OutboxKind.stocktakeCellSubmit => t.syncQueue.opStocktake(
        count:
            (operation.payload['loose'] as List<dynamic>? ?? const []).length,
        boxes:
            (operation.payload['boxes'] as List<dynamic>? ?? const []).length,
      ),
      OutboxKind.pickingPick => t.syncQueue.opPickingPick(
        qty: '${operation.payload['qty'] ?? ''}',
      ),
      OutboxKind.pickingUnpick => t.syncQueue.opPickingUnpick,
      OutboxKind.pickingReturn => t.syncQueue.opPickingReturn(
        qty: '${operation.payload['qty'] ?? ''}',
      ),
    };
    return Card(
      margin: AppInsets.bottom8,
      child: Padding(
        padding: AppInsets.all12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.bodyLarge),
            // Название товара приходит из базы, поэтому строка появляется отдельно и не
            // задерживает отрисовку списка.
            FutureBuilder<String?>(
              future: _goodName,
              builder: (context, snapshot) {
                final name = snapshot.data;
                if (name == null) return const SizedBox.shrink();
                return Text(name, style: theme.textTheme.bodySmall);
              },
            ),
            if (operation.lastError != null) ...[
              AppBoxes.kHeight4,
              // Причина показывается дословно, как её вернул сервер: он знает больше нас,
              // а пересказ своими словами потерял бы подробности разбора.
              Text(
                t.syncQueue.reason(reason: operation.lastError!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (operation.attempts > 0)
              Text(
                t.syncQueue.attempts(count: operation.attempts),
                style: theme.textTheme.bodySmall,
              ),
            if (widget.onRetry != null || widget.onDiscard != null) ...[
              AppBoxes.kHeight8,
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.onDiscard != null)
                    TextButton(
                      onPressed: widget.onDiscard,
                      child: Text(t.syncQueue.discard),
                    ),
                  if (widget.onFix != null) ...[
                    OutlinedButton(
                      onPressed: widget.onFix,
                      child: Text(t.syncQueue.fix),
                    ),
                    AppBoxes.kWidth8,
                  ],
                  if (widget.onRetry != null)
                    FilledButton(
                      onPressed: widget.onRetry,
                      child: Text(t.syncQueue.retry),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
