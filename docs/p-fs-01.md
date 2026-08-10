# P-FS-01 · Слим-схема сессии ввода остатков

**Статус:** готово (ветка `p-fs-01-session-schema`).
**Фаза:** P-FastStart (волна 1a). ТЗ — [`docs/p-faststart-1.md`](p-faststart-1.md).

## Задача

Завести схему БД под документ «ввод остатков»: шапку сессии и её строки. На них строится API сессии
(P-FS-04) и поток ввода на ТСД (P-FS-07). В `stock` строки переносятся SET-семантикой в финале
(P-FS-04) — сама схема остатка/партий не меняется.

## Критерий готовности

Миграция применяется (up/down); `stock_entry_sessions` хранит склад · автора · статус
(черновик→закрыта · время), `stock_entry_lines` — ячейка · товар · партия(дата) · количество;
связи и грань строки на месте.

## Что сделано

Миграция **`000007_stock_entry_sessions`** (up/down):

- **`stock_entry_sessions`** — шапка документа: `id` · `warehouse_id`→`warehouses` ·
  `created_by`→`users` · `status` (`draft`/`closed`, CHECK, дефолт `draft`) · `created_at` ·
  `updated_at` · `closed_at` (NULL пока draft). Индекс `warehouse_id` (список документов склада в
  портале, 1b). Триггер `set_updated_at()`.
- **`stock_entry_lines`** — строка: `id` · `session_id`→`stock_entry_sessions` **ON DELETE CASCADE** ·
  `cell_id`→`cells` · `good_id`→`goods` · `production_date NOT NULL` (партия, решение C) ·
  `qty numeric(20,3) CHECK (qty>=0)` (итог по строке, SET — решение B) · тайм-штампы. Грань
  **`UNIQUE(session_id, cell_id, good_id, production_date)`** (повторный checkpoint грани → upsert-SET
  внутри сессии; ведущий `session_id` = «строки сессии»). Триггер `set_updated_at()`.

Схема остатка/партий (`stock`, `batches`) и внутренний склад (ADR-0016) — **не трогались**.

## Решения

- **Только новая схема, ноль изменений существующих таблиц** — сессия «наложена» поверх готовых
  `warehouses`/`users`/`cells`/`goods`; в `stock` данные попадут в финале (P-FS-04).
- **Грань строки в рамках сессии уникальна** — под upsert-SET на checkpoint'е (а не накопление
  дублей): одна строка на `(сессия, ячейка, товар, дата)`.
- **`qty numeric(20,3)`** — как в `stock` (дробное для `uom='кг'`), `CHECK (qty>=0)` — backstop.
- **Триггер `updated_at`** — общий `set_updated_at()` из `000001`, как во всех таблицах.
- Индекс только `warehouse_id` на шапке (список в портале); грань-UNIQUE уже ведёт по `session_id`,
  отдельный индекс на строки не нужен.

## Проверка

Полный цикл на реальном Postgres (Colima), затем окружение возвращено (`make down`, `colima stop`):

```bash
colima start && docker compose --env-file .env -f infra/docker-compose.yml up -d db
make migrate-up      # ok, созданы stock_entry_sessions/_lines (структура/индексы/триггеры сверены \d)
# смоук инвариантов в одной транзакции с ROLLBACK:
#   status по умолчанию 'draft'; qty=10.5 вставляется; CHECK qty>=0 отклоняет -1;
#   UNIQUE-грань отклоняет дубль; CHECK status отклоняет 'foo'; CASCADE (удалили сессию → строк 0)
# триггер updated_at проверен в РАЗНЫХ транзакциях (now() константна в одной) → updated_at>created_at = t
make migrate-down    # ok, обе таблицы удалены (0)
make migrate-up      # ok, обе воссозданы (2) — обратимость/идемпотентность
make down && colima stop
```

`go build ./...` — чисто. Кода Go в задаче нет (только SQL-миграции).

## Границы

- Только схема. API сессии (старт/checkpoint/финал) — **P-FS-04**; атомарный SET остатка + batch
  GetOrCreate — **P-FS-02**; поток ТСД — **P-FS-07**.
- Внутренний склад на `stock` (ADR-0016) — вне FastStart (P4).
