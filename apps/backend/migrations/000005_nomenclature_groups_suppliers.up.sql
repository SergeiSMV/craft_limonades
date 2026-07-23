-- P1-04: справочники под импорт номенклатуры из 1С.
-- Группы номенклатуры (дерево произвольной глубины) + поставщики; расширение goods:
-- code = «Код» из 1С становится ключом апсерта, плюс полное имя и ссылки на группу/поставщика.

-- Группы номенклатуры — дерево (parent_id самоссылка). code = «Код» группы из 1С (стабильный ключ дедупа).
CREATE TABLE nomenclature_groups (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text        NOT NULL UNIQUE,                      -- Код группы из 1С
    name       text        NOT NULL,
    parent_id  uuid        REFERENCES nomenclature_groups(id),   -- NULL = корень дерева
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX nomenclature_groups_parent_id_idx ON nomenclature_groups (parent_id);

CREATE TRIGGER nomenclature_groups_set_updated_at
    BEFORE UPDATE ON nomenclature_groups
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Поставщики. В выгрузке 1С — строкой; дедуп по имени (без дублей).
CREATE TABLE suppliers (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER suppliers_set_updated_at
    BEFORE UPDATE ON suppliers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Расширение goods. code (заведён в P1-01 как индекс) теперь — ключ апсерта из 1С «Код»:
-- заменяем обычный индекс на UNIQUE, чтобы работал ON CONFLICT (code). NULL допускается
-- (ручной товар без кода), но непустые коды уникальны.
DROP INDEX IF EXISTS goods_code_idx;
ALTER TABLE goods ADD CONSTRAINT goods_code_key UNIQUE (code);
ALTER TABLE goods ADD COLUMN full_name   text;                                     -- «Полное наименование»
ALTER TABLE goods ADD COLUMN group_id    uuid REFERENCES nomenclature_groups(id); -- группа (самая глубокая в пути)
ALTER TABLE goods ADD COLUMN supplier_id uuid REFERENCES suppliers(id);           -- поставщик
CREATE INDEX goods_group_id_idx    ON goods (group_id);
CREATE INDEX goods_supplier_id_idx ON goods (supplier_id);
