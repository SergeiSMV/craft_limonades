-- ADHOC-60: откат версий данных - триггеры со всех таблиц, функции, таблица версий.
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN
        SELECT tgrelid::regclass AS tbl, tgname
        FROM pg_trigger
        WHERE tgname IN ('data_version_ins', 'data_version_upd', 'data_version_del')
    LOOP
        EXECUTE format('DROP TRIGGER %I ON %s', t.tgname, t.tbl);
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS add_data_version_triggers(regclass, text[]);
DROP FUNCTION IF EXISTS bump_data_version();
DROP TABLE IF EXISTS data_versions;
