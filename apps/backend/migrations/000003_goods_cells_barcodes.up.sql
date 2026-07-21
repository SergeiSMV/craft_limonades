-- P1-01: справочники склада — warehouses, cells, goods, barcodes. Зон нет.
-- Ячейка принадлежит складу напрямую; товар опознаётся суррогатным id (external_id/code — бизнес-ключи из 1С);
-- один товар → много ШК. Триггер updated_at переиспользуем из 000001 (set_updated_at()).

-- Склады. Пилот — один склад, но справочник заводим сразу (адресация ячеек идёт от него).
CREATE TABLE warehouses (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text        NOT NULL UNIQUE,   -- короткий код склада (напр. 'WH1') для адресации/отчётов
    name       text        NOT NULL,          -- человекочитаемое название
    is_active  boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER warehouses_set_updated_at
    BEFORE UPDATE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Ячейки хранения. Без зон: ячейка ссылается на склад напрямую.
CREATE TABLE cells (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id uuid        NOT NULL REFERENCES warehouses(id),  -- склад-владелец ячейки
    address      text        NOT NULL,                            -- адрес ячейки «С-Н-П» (стеллаж-секция-полка) в рамках склада
    type         text        NOT NULL DEFAULT 'storage',          -- тип ячейки «на вырост» (storage/receiving/shipping/...); без CHECK — значения устаканятся к P4/P5
    is_active    boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (warehouse_id, address)                                -- адрес уникален внутри своего склада
);

CREATE INDEX cells_warehouse_id_idx ON cells (warehouse_id);      -- «все ячейки склада»

CREATE TRIGGER cells_set_updated_at
    BEFORE UPDATE ON cells
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Номенклатура (товары). Ключ — внутренний суррогатный id (обмен с 1С через Excel, не REST,
-- поэтому 1С-GUID не гарантирован). external_id и code — бизнес-ключи для сверки/идемпотентного импорта.
CREATE TABLE goods (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),  -- внутренний ключ; на него ссылаются barcodes/stock/операции
    external_id uuid,                                               -- GUID номенклатуры из 1С; NULL, если его нет в файле импорта
    code        text,                                              -- код/артикул из 1С; резервный бизнес-ключ (UNIQUE не ставим — уникальность 1С не гарантирует)
    name        text        NOT NULL,                              -- наименование (в отчёты/на экран)
    uom         text        NOT NULL,                              -- единица измерения строкой ('шт', 'кг')
    is_active   boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- external_id уникален, только когда задан: один 1С-GUID → один товар; строки с NULL не конфликтуют.
CREATE UNIQUE INDEX goods_external_id_key ON goods (external_id) WHERE external_id IS NOT NULL;
CREATE INDEX goods_code_idx ON goods (code);   -- поиск/сверка по коду (без ограничения уникальности)

CREATE TRIGGER goods_set_updated_at
    BEFORE UPDATE ON goods
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Штрихкоды. Один товар имеет 1→N ШК; ШК глобально уникален (первый скан однозначно ведёт к товару).
CREATE TABLE barcodes (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    good_id    uuid        NOT NULL REFERENCES goods(id) ON DELETE CASCADE,  -- товар-владелец; ШК удаляются вместе с товаром
    barcode    text        NOT NULL UNIQUE,                                  -- сам ШК (EAN-13/Code128); один ШК → один товар
    symbology  text,                                                         -- символика ('ean13'/'code128'); NULL, если неизвестна
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX barcodes_good_id_idx ON barcodes (good_id);   -- «все ШК данного товара»

CREATE TRIGGER barcodes_set_updated_at
    BEFORE UPDATE ON barcodes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
