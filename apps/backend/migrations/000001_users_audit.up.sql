-- Схема v0: учётные записи (users) и журнал действий (audit_log).

-- Учётные записи для аутентификации по бейджу (P0-04). Ролей нет.
CREATE TABLE users (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),          -- в Postgres 16 функция встроена
    login         varchar(8)  NOT NULL UNIQUE CHECK (login ~ '^[0-9]{8}$'),   -- первые 8 цифр бейджа
    password_hash text        NOT NULL,                                       -- argon2 в PHC-формате (соль/параметры внутри)
    full_name     text        NOT NULL,                                       -- ФИО → «исполнитель» в отчётах
    role          text        NOT NULL DEFAULT 'employee'
                              CHECK (role IN ('employee','admin')),           -- права: employee (кладовщик) / admin (управление пользователями)
    is_active     boolean     NOT NULL DEFAULT true,                          -- активность; блокировка и «удаление» = is_active=false
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Функция-триггер: обновляет updated_at при любом UPDATE строки.
-- Зачем: держим «когда менялось» на стороне БД, не полагаясь на приложение.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Журнал действий: кто / что / когда. По нему разбирают спорные движения товара.
CREATE TABLE audit_log (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- порядковый, дешёвый для append-only
    user_id     uuid        REFERENCES users(id),                      -- кто; NULL для системных/неавторизованных событий
    action      text        NOT NULL,                                  -- 'auth.login', 'stock.move', ...
    entity_type text,                                                  -- 'user', 'load_unit', 'stock', ...
    entity_id   text,                                                  -- id объекта (uuid/int/qr как текст)
    details     jsonb,                                                 -- произвольный контекст: было/стало, кол-во, ячейка, партия
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Индексы под типовые запросы аудита.
CREATE INDEX audit_log_user_id_idx    ON audit_log (user_id);              -- «что делал юзер Y»
CREATE INDEX audit_log_created_at_idx ON audit_log (created_at);          -- выборка по времени
CREATE INDEX audit_log_entity_idx     ON audit_log (entity_type, entity_id); -- «кто трогал объект X»
