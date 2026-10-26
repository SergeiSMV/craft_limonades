-- ADHOC-49: должности с настраиваемыми правами вместо ролей employee/admin.
--
-- Решение 2026-10-26. Состав людей и полномочий на складе меняется (кладовщик, старший смены,
-- оператор офиса), и две жёсткие роли этого не выражают. Пользователь получает должность, у
-- должности — набор прав-галочек; функции проверяют право, а не роль. Права — фиксированный
-- список кодов: их знает код, должность лишь выбирает подмножество.

-- --- Должности ---------------------------------------------------------------------------------
--
-- Системная должность одна — «Администратор»: у неё все права, в том числе появившиеся позже
-- (код не смотрит на её список), её нельзя изменить и удалить. Так из системы нельзя выпасть,
-- раздав права неудачно.
CREATE TABLE positions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 1 AND 64),
    rights     text[]      NOT NULL DEFAULT '{}'
               CHECK (rights <@ ARRAY['tsd','portal','catalog','documents','problems','stocktake',
                                      'warehouses','cz','users']::text[]),
    is_system  boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX positions_one_system ON positions (is_system) WHERE is_system;

CREATE TRIGGER positions_set_updated_at
    BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE positions IS
    'ADHOC-49: должность пользователя и её права. Системная («Администратор») — все права.';
COMMENT ON COLUMN positions.rights IS
    'ADHOC-49: коды прав: tsd — работа на ТСД, portal — вход в портал, catalog — справочники и '
    'этикетки, documents — документы для 1С, problems — решения по проблемам склада, '
    'stocktake — заводить и закрывать пересчёт, warehouses — внутренние склады, '
    'cz — Честный знак, users — пользователи, должности и мониторинг.';

-- Стартовые должности — с постоянными id: на «Кладовщика» ссылается значение по умолчанию
-- users.position_id (сидер, тесты и прежние вставки без должности).
INSERT INTO positions (id, name, rights, is_system) VALUES
    ('7a000000-0000-4000-8000-000000000001', 'Администратор',
     ARRAY['tsd','portal','catalog','documents','problems','stocktake','warehouses','cz','users'], true),
    ('7a000000-0000-4000-8000-000000000002', 'Кладовщик', ARRAY['tsd'], false);

-- --- Должность пользователя --------------------------------------------------------------------
--
-- Роль переносится один к одному: admin — «Администратор», employee — «Кладовщик».
ALTER TABLE users ADD COLUMN position_id uuid NOT NULL
    DEFAULT '7a000000-0000-4000-8000-000000000002' REFERENCES positions(id);
UPDATE users SET position_id = '7a000000-0000-4000-8000-000000000001' WHERE role = 'admin';
ALTER TABLE users DROP COLUMN role;

CREATE INDEX users_position_id_idx ON users (position_id);

COMMENT ON COLUMN users.position_id IS
    'ADHOC-49: должность; права пользователя — права должности.';
