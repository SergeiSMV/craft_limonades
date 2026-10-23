-- CZ-03: марки Честного знака и агрегаты ЧЗ на складе.
--
-- Решения (2026-10-23, ADR-0017). WMS только читает ЧЗ, но учитывает, где лежит каждая марка:
-- в каком коробе или ячейке, какого она товара и партии, в какой упаковке ЧЗ пришла и вскрыта
-- ли эта упаковка. Транспортный короб ЧЗ (GS1-128, `00`+SSCC) и есть грузовая единица WMS:
-- его узнают по SSCC, свой QR-ярлык на него не печатают; размещение, перенос и история — те же,
-- что у любой ГЕ. Свой короб с QR остаётся для россыпи и в ЧЗ не регистрируется.

-- Агрегаты ЧЗ: транспортные короба и групповые упаковки. Код агрегата хранится только здесь:
-- связь «короб ЧЗ ↔ ГЕ» — load_unit_id, а не колонка в load_units, — так код, вид и признак
-- «вскрыт» не расходятся между двумя таблицами.
CREATE TABLE cz_aggregates (
    -- Код в ЧЗ: у короба — `00`+SSCC (без `00` True API его не находит), у групповой
    -- упаковки — КИ того же вида, что у марки единицы (`01`+GTIN+`21`+серийный, до GS).
    code         text        PRIMARY KEY,
    -- Вид — `generalPackageType` ответа ЧЗ. Поле `packageType` там — уровень (LEVEL1…), не вид:
    -- сверено на проде в CZ-02.
    kind         text        NOT NULL CHECK (kind IN ('BOX','GROUP')),
    -- Вложенность в ЧЗ: групповая упаковка внутри короба. Удалить короб, пока в нём числятся
    -- упаковки, нельзя — FK без каскада.
    parent_code  text        REFERENCES cz_aggregates(code)
                             CHECK (parent_code IS NULL OR parent_code <> code),
    -- Короб ЧЗ как ГЕ WMS: место, перенос и история — у ГЕ. Один короб — одна ГЕ.
    load_unit_id uuid        UNIQUE REFERENCES load_units(id),
    -- Вскрыт: из упаковки изъята марка (CZ-06). Целый невскрытый короб уходит в отгрузку
    -- одной строкой со своим кодом, вскрытый — марками (CZ-07).
    opened_at    timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),

    -- Формат кода по виду: опечатку или код с криптохвостом база не примет.
    CONSTRAINT cz_aggregates_code_format CHECK (
        (kind = 'BOX'   AND code ~ '^00[0-9]{18}$') OR
        (kind = 'GROUP' AND code ~ '^01[0-9]{14}21[^\x1d]+$')
    ),
    -- ГЕ бывает только у короба: групповая упаковка лежит в коробе или россыпью.
    CONSTRAINT cz_aggregates_load_unit_box CHECK (load_unit_id IS NULL OR kind = 'BOX')
);

CREATE INDEX cz_aggregates_parent_idx ON cz_aggregates (parent_code) WHERE parent_code IS NOT NULL;

CREATE TRIGGER cz_aggregates_set_updated_at
    BEFORE UPDATE ON cz_aggregates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE cz_aggregates IS
    'CZ-03: агрегаты ЧЗ — транспортные короба (они же ГЕ) и групповые упаковки, признак «вскрыт».';

-- Марки ЧЗ на складе. Марка всегда единица остатка: товар и партия обязательны.
CREATE TABLE cz_marks (
    -- КИ: `01`+GTIN+`21`+серийный — часть кода до GS. Криптохвост не хранится: True API ищет
    -- марку только по КИ (ADR-0017). Марка уникальна — повторный приход той же марки упрётся
    -- в первичный ключ.
    cis           text        PRIMARY KEY
                              CHECK (cis ~ '^01[0-9]{14}21[^\x1d]+$'),
    -- GTIN вычисляется из КИ, вторым экземпляром не хранится. Индекс — под «марки товара».
    gtin          text        GENERATED ALWAYS AS (substring(cis FROM 3 FOR 14)) STORED,
    -- Товар денормализован, как в stock и lu_content; составной FK ниже держит его в паре с
    -- партией. Товар по GTIN находится через barcodes: GTIN-14 — EAN-13 с ведущим нулём.
    good_id       uuid        NOT NULL,
    -- Партия — дата производства ЕДИНИЦЫ: у упаковки дата ЧЗ — время агрегации (ADR-0017).
    batch_id      uuid        NOT NULL,
    status        text        NOT NULL DEFAULT 'in_stock'
                              CHECK (status IN ('in_stock','shipped','written_off','returned')),
    -- in_stock    — на складе;
    -- shipped     — отгружена клиенту (P9, CZ-07);
    -- written_off — списана по решению офиса (P6-07-3);
    -- returned    — возвращена поставщику (ADHOC-31).

    -- Место — ровно одно, пока марка на складе (CHECK ниже):
    --   в ГЕ   — load_unit_id; место ГЕ хранится только в load_units.cell_id, здесь не дублируется;
    --   россыпь — cell_id + internal_warehouse_id: та же грань, что у строки остатка (ADR-0016).
    load_unit_id          uuid REFERENCES load_units(id),
    cell_id               uuid REFERENCES cells(id),
    internal_warehouse_id uuid REFERENCES internal_warehouses(id),
    -- Упаковка ЧЗ, в которой марка пришла (`parent` в ответе ЧЗ). Это не место: марку
    -- изымают из короба, а в ЧЗ она числится в нём до расформирования. Место — поля выше.
    aggregate_code text       REFERENCES cz_aggregates(code),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    -- Партия существует и принадлежит тому же товару (приём из stock).
    CONSTRAINT cz_marks_batch_fk FOREIGN KEY (batch_id, good_id) REFERENCES batches(id, good_id),

    -- На складе — ровно одно место; ушла со склада — места нет. Марка без места или в двух
    -- местах сразу означала бы, что ответ «где лежит марка» неоднозначен (CZ-06).
    CONSTRAINT cz_marks_place CHECK (
        (status = 'in_stock' AND (
            (load_unit_id IS NOT NULL AND cell_id IS NULL AND internal_warehouse_id IS NULL) OR
            (load_unit_id IS NULL AND cell_id IS NOT NULL AND internal_warehouse_id IS NOT NULL)
        )) OR
        (status <> 'in_stock' AND load_unit_id IS NULL AND cell_id IS NULL
                              AND internal_warehouse_id IS NULL)
    )
);

-- «Марки этого короба», «марки россыпью в ячейке», «состав упаковки ЧЗ» — частичные индексы:
-- у большинства марок одно из полей пустое.
CREATE INDEX cz_marks_load_unit_idx ON cz_marks (load_unit_id) WHERE load_unit_id IS NOT NULL;
CREATE INDEX cz_marks_cell_idx      ON cz_marks (cell_id) WHERE cell_id IS NOT NULL;
CREATE INDEX cz_marks_aggregate_idx ON cz_marks (aggregate_code) WHERE aggregate_code IS NOT NULL;
CREATE INDEX cz_marks_good_batch_idx ON cz_marks (good_id, batch_id);

CREATE TRIGGER cz_marks_set_updated_at
    BEFORE UPDATE ON cz_marks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE cz_marks IS
    'CZ-03: марки ЧЗ на складе — товар и партия, место (ГЕ или ячейка), упаковка ЧЗ, статус.';
