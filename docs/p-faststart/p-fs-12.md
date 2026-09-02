# P-FS-12 · Отвязка/перепривязка ШК: инлайн в потоке ввода + секция в карточке товара

**Статус:** готово (ветка `p-fs-12-barcode-unbind`); ⚠ сквозной тест на DT50 ещё не прогонял.
**Фаза:** P-FastStart (доработка модели ШК, продолжает [P-FS-11](p-fs-11.md)).

## Задача

После P-FS-11 можно привязать несколько ШК на товар, но **нельзя отвязать** ошибочный. Ошибка
обнаруживается прямо в операции (пересчёт/ввод остатков), а выход из неё теряет прогресс (вариант A).
Нужна коррекция привязки, не завязанная на операцию.

## Принцип (решение обсуждено с пользователем)

- **Привязка/отвязка ШК — операция над справочником, не над сессией.** Коррекция сохраняется на сервер
  **сразу (online)**, отдельно от финала пересчёта → брошенный проход её не теряет.
- **Асимметрия осознанная:** новая привязка копится до финала (данные пересчёта), а **отвязка** —
  немедленно (исправление уже существующего факта; отложить = потерять при отмене прохода).
- **Количество — вариант A** (из P-FS-11): ШК только идентифицирует, множителя упаковки нет.
- **Доступ — `employee`** (и admin автоматически): инлайн-коррекция нужна оператору мид-пересчёт.

## Что сделано

### Backend (без миграций — таблица `barcodes` уже мульти-ШК)
- `DELETE /api/v1/barcodes/{code}` — отвязать (идемпотентно: нет привязки → не ошибка, 204). Перепривязка
  = unbind + существующий `POST /barcodes` (оба идемпотентны, отдельный `PUT` не нужен).
- `GET /api/v1/goods/{id}/barcodes` — все ШК товара (для секции карточки); пустой список — `[]`, не null.
- Слои: `repository.BarcodeRepository.{ListByGood,Unbind}` → `service.BarcodeService.{ListByGood,Unbind}`
  (валидация пустых) → `handler.BarcodeHandler.{ListByGood,Unbind}`; роуты в группе ШК (employee).
  Модель `model.Barcode{barcode, symbology}`.

### Flutter — инлайн «неверный товар» (поток ввода остатков)
- Кнопка **«Неверный товар»** в диалоге даты/кол-ва (`_DateQtyDialog.allowWrongGood` — только в скан-потоке,
  когда товар опознан по ШК; при ручном добавлении и правке строки её нет).
- Обработчик `_handleWrongGood(code)`: привязка **этой сессии** (в копилке) → снимаем локально
  (`StockEntryCubit.removeLocalBarcode`, откатывается Undo); уже **в БД** → немедленный `DELETE`
  (`CatalogRepository.unbindBarcode`). Затем предложение выбрать правильный товар → перепривязка
  (`newBarcode` → копилка). Бросят проход после отвязки — ШК останется неприкреплённым (лучше, чем неверный).
- `_DateQtyResult` (add | wrongGood) вместо `_DateQty`; `_failureText` вынесен в топ-левел (нужен и инлайну).

### Flutter — секция «Штрихкоды» в карточке товара (стабильный «дом» вне операций)
- `StockDetailCubit`: грузит ШК товара вместе с остатком (`listGoodBarcodes`; ошибка ШК не валит карточку),
  `unbindBarcode(code)` → `DELETE` → перезагрузка карточки.
- `StockDetailScreen._BarcodesSection`: чипы ШК с «×»; удаление — с подтверждением (AlertDialog).
- Модель клиента `Barcode`, `ApiConst.goodBarcodes(id)` + DELETE на `barcodeByCode`.
- i18n: `stock_entry.{wrong_good, barcode_unbound}`, `stock_detail_screen.{barcodes_title, barcodes_empty,
  barcode_delete_title, barcode_delete_body, unbind, cancel}`.

## Проверка

- **Backend:** `gofmt`/`go build`/`go vet`/`golangci-lint` — 0. Integration (testcontainers):
  `TestBarcode_listByGood` (сортировка, пустой не-nil, symbology NULL/значение), `TestBarcode_unbind`
  (резолв→404 после отвязки, идемпотентность, перепривязка на другой товар, соседний ШК жив),
  `TestBarcode_unbind_validation`. **Runtime E2E через стек** (`make up`+seed): unauth `DELETE`/`GET
  goods/{id}/barcodes`→401; авторизованно — bind→201, list→2 ШК, `DELETE`→204, resolve после→404,
  повторный `DELETE`→204 (идемпотентно), rebind (del+bind)→новый владелец, пустой list→`[]`.
- **Flutter:** `flutter analyze` — No issues; тесты — `catalog_repository` (listGoodBarcodes парс/[]/401,
  unbindBarcode 204/маршрут/401), `stock_entry_cubit` (removeLocalBarcode + undo, no-op на отсутствующем),
  `stock_detail_cubit` (грузит ШК+остаток, ошибка ШК не валит, unbind→перезагрузка, ошибка→failure).
  Полный прогон — **76 тестов зелёных**. **APK-сборка** `flutter build apk --release -t lib/main.dart
  --dart-define-from-file=.env` — зелёная.
- ⚠ **Сквозной тест на реальном DT50** (скан → «неверный товар» → перепривязка; карточка → удаление ШК) —
  ещё не прогонял.

```bash
cd apps/backend && gofmt -l internal && go build ./... && go vet ./...
# integration: DOCKER_HOST=<colima sock> TESTCONTAINERS_RYUK_DISABLED=true go test ./internal/service/ -run TestBarcode
cd apps/craft_wms && flutter analyze && flutter test
flutter build apk --release -t lib/main.dart --dart-define-from-file=.env
```

## Границы

- Только отвязка/перепривязка + список ШК товара. Символика при перепривязке — пустая (как в P-FS-11).
- **online-only** (как весь ввод остатков): нет сети при отвязке → ошибка, ретрай; молча не буферизуем
  (буфер вернул бы проблему потери коррекции). Настоящая офлайн-устойчивость коррекций — P2 (Outbox).
- Аудит отвязок (кто/когда) — не делаем на пилоте; на будущее (destructive-операция).
- Портал (Номенклатура) и «identify по ШК» (какому товару принадлежит) — не в этой задаче; следующий шаг
  при необходимости.
