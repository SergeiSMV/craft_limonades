# P-FS-05 · PDF-этикетки ячеек

**Статус:** готово (ветка `p-fs-05-cell-labels-pdf`); ⚠ ожидается визуальная сверка PDF с образцом.
**Фаза:** P-FastStart (волна 1a). ТЗ — [`docs/p-faststart-1.md`](p-faststart-1.md).

## Задача

Бэкенд формирует PDF-этикеток ячеек склада для печати и наклейки (идентификация ячейки сканом).

## Критерий готовности

`GET /cells/labels.pdf` (admin) отдаёт A4-PDF: 1 колонка × 8 этикеток на лист, на этикетке
Code128(адрес) + крупный адрес, стрелка вниз при `is_floor`; натуральная сортировка по адресу;
пунктирные линии реза; штрихкод читается сканером ТСД. Соответствует согласованному образцу.

## Что сделано

- **`internal/labels/pdf.go` — `Render([]model.CellLabel) ([]byte, error)`:** A4 портрет, **1 колонка
  × 8 этикеток** (полосы во всю ширину), пунктир реза по нижней границе. На этикетке: **Code128(адрес)**
  (`boombuler/barcode` → PNG → изображение в fpdf) слева + **крупный адрес** (Helvetica Bold 30, адрес —
  латиница/цифры, core-шрифт достаточно) + **стрелка вниз вектором** при `is_floor` (fpdf-примитивы,
  без завязки на глиф шрифта). Библиотеки: `go-pdf/fpdf` + `boombuler/barcode`.
- **`repository`:** `WarehouseRepository.IDByCode(code)` → id/`ErrNotFound`; `CellRepository.
  LabelsByWarehouse(warehouseID)` → активные ячейки склада (`address`,`is_floor`), без пагинации.
- **`service/labels.go` — `LabelService.CellLabelsPDF(warehouseCode)`:** резолв склада (404 если нет)
  → ячейки → **натуральная сортировка** (`naturalLess`: цифровые сегменты по значению, чтобы
  `M1-1-2-1` шёл раньше `M1-1-10-1`) → `labels.Render`.
- **`handler/labels.go`:** `GET /api/v1/cells/labels.pdf?warehouse=SHB` → 200 `application/pdf`
  (`Content-Disposition: attachment`) / 404. Пустой `warehouse` → дефолт `SHB`.
- **Проводка:** `NewRouter(…, labelSvc)` в admin-группе (`RequireRole(admin)`, как импорт);
  `cmd/server/main.go`. Deps `go-pdf/fpdf`, `boombuler/barcode` (в `go.mod`, direct).

## Решения

- **Штрихкод — изображением (PNG)**, а не векторными штрихами: `boombuler` рендерит Code128 в
  `image`, масштабируем (600×200 px) и вставляем через `RegisterImageOptionsReader`.
- **Стрелка — вектором**, не символом шрифта: надёжнее (core-шрифты могут не иметь глифа стрелки).
- **Натуральная сортировка на сервисе** (не в SQL): SQL `ORDER BY address` дал бы лексикографику
  (`M1-1-10-1` перед `M1-1-2-1`); сегментное сравнение — на Go.
- **Только admin** — печать этикеток из портала; поток на ТСД этот PDF не дёргает.
- **Кириллица не нужна** — на этикетке только адрес (латиница); TTF-юникод-шрифт не подключаем.

## Проверка

- Статика: `gofmt`/`go vet`/`go build`/`golangci-lint run ./...` — **0 issues**. Полный `go test ./...`
  зелёный (регрессий после смены сигнатуры `NewRouter` нет).
- Юнит (без Docker): `labels.Render` (пустой список → валидный `%PDF`; 10 ячеек → 2 страницы,
  непустой PDF); `naturalLess` (порядок `…-1-1 < …-2-1 < …-10-1 < M2-…`).
- Integration (testcontainers): `CellLabelsPDF("SHB")` по засеянным ячейкам → `%PDF`, непустой;
  неизвестный склад → `ErrNotFound`.
- **Runtime E2E через стек:** admin `GET …/cells/labels.pdf?warehouse=SHB` → **200** `application/pdf`
  (`attachment; filename="cell-labels-SHB.pdf"`, `%PDF`, ~13 КБ, 2 стр. на 10 ячеек); без токена →
  **401**; неизвестный склад → **404**. Реальный PDF выгружен и отправлен на визуальную сверку
  (10 ячеек, первые 4 напольные — стрелки; порядок подтверждает натур. сортировку `M1-1-2-10` после
  `M1-1-2-2`).

```bash
cd apps/backend && gofmt -l internal/ cmd/ && go vet ./... && go build ./... && golangci-lint run
go test ./internal/labels/ -count=1                      # юнит генератора (без Docker)
# integration (colima): DOCKER_HOST=unix://~/.colima/default/docker.sock TESTCONTAINERS_RYUK_DISABLED=true
go test ./internal/service/ -run TestCellLabelsPDF -count=1
# runtime: make up && make migrate-up && make seed → curl -H "Bearer <admin>" .../cells/labels.pdf?warehouse=SHB
```

## Границы

- Кнопка скачивания PDF в портале — **P-FS-06**. Поток ввода на ТСД (скан ячейки этим ШК) — **P-FS-07**.
- Размер этикетки/шрифта — по образцу; при необходимости точной подгонки под конкретный принтер
  правится в константах раскладки `internal/labels/pdf.go`.
