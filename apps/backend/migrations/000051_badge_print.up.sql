-- ADHOC-65: печать бейджей сотрудников на ТСД.
--
-- Решение 2026-11-09: бейдж печатается тем же номером, что выдан, - номер хранится. Секрет бейджа
-- (последние 8 цифр) по-прежнему проверяется argon2-хешем (password_hash), а для печати лежит
-- отдельно зашифрованным: AES-256-GCM ключом BADGE_KEY из окружения бэкенда, с логином (первые
-- 8 цифр) как связанными данными - шифртекст другой строки к этой не подойдёт. Ключа в базе нет:
-- дамп без .env.prod номеров не раскрывает.
--
-- Номер записывается, когда сервер его видит: при входе по бейджу и при выдаче бейджа в
-- портале. У заведённых раньше сотрудников номера нет, пока они не войдут один раз. Сменился
-- ключ (или база - снимок прода на стенде) - номер не расшифруется и перезапишется при входе.
ALTER TABLE users ADD COLUMN badge_secret_enc bytea;

COMMENT ON COLUMN users.badge_secret_enc IS
    'ADHOC-65: секрет бейджа (последние 8 цифр), AES-256-GCM ключом BADGE_KEY, связанные данные - '
    'login; nonce в начале. NULL - номер не сохранён (вход по паролю или ещё не входил).';

-- --- Права ---------------------------------------------------------------------------------------
-- «Бейджи» на ТСД - три уровня: свой; всех, кроме администратора; всех. Действует самый
-- широкий из отмеченных. «Администратор» (системная должность) получает все сам.
ALTER TABLE positions DROP CONSTRAINT positions_rights_check;
ALTER TABLE positions ADD CONSTRAINT positions_rights_check CHECK (rights <@ ARRAY[
    'portal.nomenclature.view', 'portal.nomenclature.import',
    'portal.stock.view',
    'portal.receipt.view', 'portal.receipt.download', 'portal.receipt.post',
    'portal.stocktake.view', 'portal.stocktake.manage',
    'portal.stocktake_doc.view', 'portal.stocktake_doc.download', 'portal.stocktake_doc.post',
    'portal.stock_entry_doc.view', 'portal.stock_entry_doc.download', 'portal.stock_entry_doc.post',
    'portal.cells.import', 'portal.cells.labels', 'portal.cells.edit',
    'portal.movement.view', 'portal.movement.download', 'portal.movement.post',
    'portal.problems.view', 'portal.problems.resolve',
    'portal.picking.view', 'portal.picking.load', 'portal.picking.download', 'portal.picking.release',
    'portal.settings.warehouses', 'portal.settings.problem_reasons', 'portal.settings.users',
    'tsd.receipt', 'tsd.movement',
    'tsd.tasks.putaway', 'tsd.tasks.stocktake_count', 'tsd.tasks.stocktake_manage',
    'tsd.tasks.picking_return',
    'tsd.stock.view', 'tsd.stock.cz_marked', 'tsd.stock.regrade', 'tsd.stock_entry',
    'tsd.problems.view', 'tsd.problems.mark',
    'tsd.picking', 'tsd.picking.reprint',
    'tsd.badges.own', 'tsd.badges.staff', 'tsd.badges.all'
]::text[]);
