-- CZ-05: приёмка маркированного товара.
--
-- Решения (2026-10-23, долги 16 и 17). Какой товар маркируемый, WMS узнаёт по факту: флаг
-- ставится сам, когда к товару привязан ШК из марки или принята его марка; правит его admin.
-- Марки принимаются только со связью - данные ЧЗ читаются при скане. Расхождение с ЧЗ (чужой
-- владелец, марка не в обороте) не останавливает приёмку: товар принимается и в той же
-- транзакции уходит «Проблемой склада» в «Изолятор».

-- Маркируемый товар: на приёмке и отгрузке требует скан марки, а не ШК. Выгрузка номенклатуры
-- 1С такого признака не несёт, поэтому импорт колонку не трогает - её значение живёт в WMS.
ALTER TABLE goods ADD COLUMN cz_marked boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN goods.cz_marked IS
    'CZ-05: товар маркируемый - ставится по факту (ШК из марки, принятая марка), правит admin.';

-- Причина «выбыла из оборота» (retired): марка в ЧЗ не в обороте - продана, списана, выведена.
-- Принимать такую бутылку на остаток как обычную нельзя. Допустимые решения офиса - в коде
-- (model.problemDecisions): списать или вернуть поставщику.
ALTER TABLE warehouse_problems DROP CONSTRAINT warehouse_problems_reason_check;
ALTER TABLE warehouse_problems ADD CONSTRAINT warehouse_problems_reason_check
    CHECK (reason IN ('breakage','spoilage','expired','foreign_mark','retired','other'));

-- Какие марки ушли с проблемой в «Изолятор». У проблемы поле mark - одна строка, а у короба ЧЗ
-- с чужим владельцем расходятся все его марки; связь в обратную сторону держит их все.
ALTER TABLE cz_marks ADD COLUMN problem_id uuid REFERENCES warehouse_problems(id);

CREATE INDEX cz_marks_problem_idx ON cz_marks (problem_id) WHERE problem_id IS NOT NULL;
