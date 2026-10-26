-- ADHOC-50: откат дерева прав к девяти кодам ADHOC-49.
--
-- Действие возвращает свой прежний код; «вход в портал» получает тот, у кого был любой раздел
-- портала. Частично отмеченный раздел откат расширяет до всего прежнего кода.
ALTER TABLE positions DROP CONSTRAINT positions_rights_check;

UPDATE positions p SET rights = COALESCE((
    SELECT array_agg(DISTINCT old ORDER BY old) FROM (
        SELECT CASE
            WHEN r IN ('tsd.tasks.stocktake_manage', 'portal.stocktake.view', 'portal.stocktake.manage') THEN 'stocktake'
            WHEN r = 'tsd.stock.cz_marked' THEN 'cz'
            WHEN r LIKE 'tsd.%' THEN 'tsd'
            WHEN r IN ('portal.nomenclature.import', 'portal.cells.import', 'portal.cells.labels') THEN 'catalog'
            WHEN r LIKE 'portal.problems.%' THEN 'problems'
            WHEN r = 'portal.settings.warehouses' THEN 'warehouses'
            WHEN r = 'portal.settings.users' THEN 'users'
            ELSE 'documents'
        END AS old
        FROM unnest(p.rights) AS r
        UNION
        SELECT 'portal' FROM unnest(p.rights) AS r WHERE r LIKE 'portal.%'
    ) x
), '{}');

ALTER TABLE positions ADD CONSTRAINT positions_rights_check
    CHECK (rights <@ ARRAY['tsd','portal','catalog','documents','problems','stocktake',
                           'warehouses','cz','users']::text[]);
