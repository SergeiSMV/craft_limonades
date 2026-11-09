import '../gen/strings.g.dart';

/// Права должности — действия по разделам (ADHOC-50): код «приложение.раздел.действие», тот же,
/// что проверяет сервер. Группы дерева (приложение, раздел) не хранятся — они только для
/// показа: галочка раздела ставит все его действия.
abstract final class Rights {
  static const portal = 'portal.'; // префикс: любое право портала
  static const tsd = 'tsd.'; // префикс: любое право ТСД

  static const nomenclatureView = 'portal.nomenclature.view'; // ADHOC-56
  static const nomenclatureImport = 'portal.nomenclature.import';
  static const stockView = 'portal.stock.view'; // ADHOC-56
  static const receiptView = 'portal.receipt.view';
  static const receiptDownload = 'portal.receipt.download';
  static const receiptPost = 'portal.receipt.post';
  static const stocktakeView = 'portal.stocktake.view';
  static const stocktakeManage = 'portal.stocktake.manage';
  static const stocktakeDocView = 'portal.stocktake_doc.view';
  static const stocktakeDocDownload = 'portal.stocktake_doc.download';
  static const stocktakeDocPost = 'portal.stocktake_doc.post';
  static const stockEntryDocView = 'portal.stock_entry_doc.view';
  static const stockEntryDocDownload = 'portal.stock_entry_doc.download';
  static const stockEntryDocPost = 'portal.stock_entry_doc.post';
  static const cellsImport = 'portal.cells.import';
  static const cellsLabels = 'portal.cells.labels';
  static const cellsEdit = 'portal.cells.edit'; // ADHOC-57: галочки этикеток
  static const movementView = 'portal.movement.view';
  static const movementDownload = 'portal.movement.download';
  static const movementPost = 'portal.movement.post';
  static const problemsView = 'portal.problems.view';
  static const problemsResolve = 'portal.problems.resolve';
  static const pickingView = 'portal.picking.view'; // P8-02: Сборка-отгрузка
  static const pickingLoad = 'portal.picking.load';
  static const pickingDownload = 'portal.picking.download';
  static const pickingRelease =
      'portal.picking.release'; // P8-03: снять с исполнителя
  static const settingsWarehouses = 'portal.settings.warehouses';
  static const settingsProblemReasons = 'portal.settings.problem_reasons';
  static const settingsUsers = 'portal.settings.users';

  static const tsdReceipt = 'tsd.receipt';
  static const tsdMovement = 'tsd.movement';
  static const tsdPutaway = 'tsd.tasks.putaway';
  static const tsdStocktakeCount = 'tsd.tasks.stocktake_count';
  static const tsdStocktakeManage = 'tsd.tasks.stocktake_manage';
  static const tsdPickingReturn =
      'tsd.tasks.picking_return'; // P9-07-1: вернуть на места
  static const tsdStockView = 'tsd.stock.view';
  static const tsdStockCzMarked = 'tsd.stock.cz_marked';
  static const tsdStockRegrade = 'tsd.stock.regrade';
  static const tsdStockEntry = 'tsd.stock_entry';
  static const tsdProblemsView = 'tsd.problems.view';
  static const tsdProblemsMark = 'tsd.problems.mark';
  static const tsdPicking = 'tsd.picking'; // P8-02: собирать и отгружать
  static const tsdPickingReprint = 'tsd.picking.reprint';
  // ADHOC-65: «Бейджи» - три уровня, действует самый широкий из отмеченных.
  static const tsdBadgesOwn = 'tsd.badges.own';
  static const tsdBadgesStaff = 'tsd.badges.staff';
  static const tsdBadgesAll = 'tsd.badges.all';

  /// Любое из прав «Бейджи» - пункт меню виден.
  static const tsdBadges = [tsdBadgesOwn, tsdBadgesStaff, tsdBadgesAll];
}

/// Узел дерева прав: группа ([children]) или действие ([code]).
class RightNode {
  const RightNode(this.label, {this.code, this.children = const []});

  final String label;
  final String? code;
  final List<RightNode> children;

  /// Коды действий узла — его собственный или всех действий внутри.
  List<String> get codes =>
      code != null ? [code!] : [for (final c in children) ...c.codes];
}

/// Дерево прав в порядке показа: портал по разделам меню, ТСД — по плиткам главного экрана.
List<RightNode> rightsTree() {
  final r = t.rights;
  List<RightNode> docActions(String view, String download, String post) => [
    RightNode(r.docView, code: view),
    RightNode(r.docDownload, code: download),
    RightNode(r.docPost, code: post),
  ];
  return [
    RightNode(
      r.portal,
      children: [
        RightNode(
          r.nomenclature,
          children: [
            RightNode(r.nomenclatureView, code: Rights.nomenclatureView),
            RightNode(r.nomenclatureImport, code: Rights.nomenclatureImport),
          ],
        ),
        RightNode(
          r.stock,
          children: [RightNode(r.stockView, code: Rights.stockView)],
        ),
        RightNode(
          r.receipt,
          children: docActions(
            Rights.receiptView,
            Rights.receiptDownload,
            Rights.receiptPost,
          ),
        ),
        RightNode(
          r.inventory,
          children: [
            RightNode(
              r.stocktakes,
              children: [
                RightNode(r.stocktakeView, code: Rights.stocktakeView),
                RightNode(r.stocktakeManage, code: Rights.stocktakeManage),
              ],
            ),
            RightNode(
              r.stocktakeDocs,
              children: docActions(
                Rights.stocktakeDocView,
                Rights.stocktakeDocDownload,
                Rights.stocktakeDocPost,
              ),
            ),
            RightNode(
              r.stockEntryDocs,
              children: docActions(
                Rights.stockEntryDocView,
                Rights.stockEntryDocDownload,
                Rights.stockEntryDocPost,
              ),
            ),
          ],
        ),
        RightNode(
          r.cells,
          children: [
            RightNode(r.cellsImport, code: Rights.cellsImport),
            RightNode(r.cellsLabels, code: Rights.cellsLabels),
            RightNode(r.cellsEdit, code: Rights.cellsEdit),
          ],
        ),
        RightNode(
          r.movement,
          children: docActions(
            Rights.movementView,
            Rights.movementDownload,
            Rights.movementPost,
          ),
        ),
        RightNode(
          r.problems,
          children: [
            RightNode(r.problemsView, code: Rights.problemsView),
            RightNode(r.problemsResolve, code: Rights.problemsResolve),
          ],
        ),
        RightNode(
          r.picking,
          children: [
            RightNode(r.pickingView, code: Rights.pickingView),
            RightNode(r.pickingLoad, code: Rights.pickingLoad),
            RightNode(r.pickingDownload, code: Rights.pickingDownload),
            RightNode(r.pickingRelease, code: Rights.pickingRelease),
          ],
        ),
        RightNode(
          r.settings,
          children: [
            RightNode(r.settingsWarehouses, code: Rights.settingsWarehouses),
            RightNode(
              r.settingsProblemReasons,
              code: Rights.settingsProblemReasons,
            ),
            RightNode(r.settingsUsers, code: Rights.settingsUsers),
          ],
        ),
      ],
    ),
    RightNode(
      r.tsd,
      children: [
        RightNode(r.tsdReceipt, code: Rights.tsdReceipt),
        RightNode(r.tsdMovement, code: Rights.tsdMovement),
        RightNode(
          r.tsdTasks,
          children: [
            RightNode(r.tsdPutaway, code: Rights.tsdPutaway),
            RightNode(r.tsdStocktakeCount, code: Rights.tsdStocktakeCount),
            RightNode(r.tsdStocktakeManage, code: Rights.tsdStocktakeManage),
            RightNode(r.tsdPickingReturn, code: Rights.tsdPickingReturn),
          ],
        ),
        RightNode(
          r.tsdStock,
          children: [
            RightNode(r.tsdStockView, code: Rights.tsdStockView),
            RightNode(r.tsdStockCz, code: Rights.tsdStockCzMarked),
            RightNode(r.tsdStockRegrade, code: Rights.tsdStockRegrade),
          ],
        ),
        RightNode(r.tsdStockEntry, code: Rights.tsdStockEntry),
        RightNode(
          r.tsdProblems,
          children: [
            RightNode(r.tsdProblemsView, code: Rights.tsdProblemsView),
            RightNode(r.tsdProblemsMark, code: Rights.tsdProblemsMark),
          ],
        ),
        RightNode(
          r.tsdPicking,
          children: [
            RightNode(r.tsdPickingWork, code: Rights.tsdPicking),
            RightNode(r.tsdPickingReprint, code: Rights.tsdPickingReprint),
          ],
        ),
        RightNode(
          r.tsdBadges,
          children: [
            RightNode(r.tsdBadgesOwn, code: Rights.tsdBadgesOwn),
            RightNode(r.tsdBadgesStaff, code: Rights.tsdBadgesStaff),
            RightNode(r.tsdBadgesAll, code: Rights.tsdBadgesAll),
          ],
        ),
      ],
    ),
  ];
}
