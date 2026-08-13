# P-FS-09 · Портал: раздел «Инвентаризация» — список документов + скачивание

**Статус:** готово (ветка `p-fs-09-portal-inventory-list`); ⚠ визуал/клиентский E2E — за пользователем.
**Фаза:** P-FastStart (волна 1b — **завершающая**). ТЗ — [`docs/p-faststart-1.md`](p-faststart-1.md).

## Задача

Во вкладке «Инвентаризация» портала — список документов «ввод остатков» (закрытые сессии) со
скачиванием `.xlsx` (отчёт P-FS-08).

## Критерий готовности

Вкладка (была заглушкой) показывает список документов ввода остатков (дата · склад · пометка ·
число строк), по каждому — скачивание `.xlsx`; admin-only.

## Что сделано

### Бэкенд — эндпоинт списка (недостающий)

- **`model.StockEntryDocument`** (id · склад · `closed_at` · число строк).
- **`repository.ListClosedDocuments`**: закрытые сессии (`status='closed'`) JOIN `warehouses` +
  COUNT строк, **свежие сверху** (`ORDER BY closed_at DESC`).
- **`service.ListDocuments`** + **`handler.List`**: `GET /api/v1/stock-entry/sessions` → JSON
  `[{id, warehouse_code, warehouse_name, closed_at(RFC3339), lines_count}]`. **admin-only**
  (в той же группе, что скачивание отчёта P-FS-08).

### Портал (Flutter Web)

- **`ApiConst.stockEntryReport(id)`** — `stock-entry/sessions/{id}/report.xlsx` (список — на
  существующем `stockEntrySessions`).
- **`portal/data/inventory_repository.dart`** (`@lazySingleton`): модель `StockEntryDoc` + `listDocuments()`
  (→ список) + `downloadReport(id)` (`responseType: bytes` → `Uint8List`, как P-FS-06).
- **`portal/presentation/tabs/inventory_tab.dart`**: загрузка списка при открытии; карточка раздела +
  список документов (склад · дата/время · пометка «Ввод остатков» · число позиций) с кнопкой скачивания
  (спиннер на строку) → `downloadBytes` (Blob, P-FS-06). Состояния loading/error(retry)/empty.
- **Проводка**: `PortalShell` — вкладка «Инвентаризация» (`t.portal.tabs.stocktake`) заменена с
  `StubTab(P10)` на `InventoryTab`; i18n-секция `portal.inventory`.

## Решения

- **«Документ» = закрытая сессия** — список строится из `stock_entry_sessions` (`closed`), без отдельной
  таблицы документов (как в P-FS-08).
- **Список — на `GET /stock-entry/sessions`** (тот же путь, что POST-создание на ТСД); admin-only.
- **Скачивание — паттерн P-FS-06** (`responseType: bytes` + `web_download.downloadBytes`).
- **draft-сессии не показываем** — только завершённые проходы.

## Проверка

- Бэкенд: `gofmt`/`go vet`/`go build`/`golangci-lint run ./...` — **0 issues**; integration
  (`ListDocuments`: только закрытая сессия, draft не в списке, склад/число строк) зелёный.
- Портал: `flutter analyze` — **No issues**; тесты `test/portal/inventory_repository_test.dart`
  (список парсится, 401→ServerFailure, download `responseType: bytes`, маршрут без ведущего `/`);
  полный прогон — **56 тестов**; сборка `flutter build web -t lib/main_portal.dart` зелёная.
- **Runtime E2E через стек**: `GET /stock-entry/sessions` — draft **не** в списке; после финала документ
  **сверху** (свежие первыми); без токена → **401**. Скачивание `report.xlsx` — проверено в P-FS-08.

```bash
cd apps/backend && go build ./... && golangci-lint run && go test ./internal/service/ -run TestStockEntryReport
cd apps/craft_wms && flutter analyze && flutter test && \
  flutter build web -t lib/main_portal.dart --dart-define-from-file=.env --release
```

## Границы

- ⚠ Клиентский визуал/скачивание вживую — за пользователем (как P1-08/P-FS-06).
- **Завершает волну 1b и всю фазу P-FastStart** (P-FS-01…09): этикетки → проход склада → остатки в WMS →
  Excel-сверка с 1С в портале. Публикация портала на прод — вручную (P1-09-1).
