-- P1-01-1: учётки логин/пароль для admin/менеджера (вход со смартфона/web, не по бейджу).
-- Работник входит по бейджу (login = 8 цифр); admin/менеджер - по username + паролю.
-- Ровно одно из (login, username) задано у строки.

-- 1. У admin бейджа нет → login становится необязательным.
--    Существующий CHECK (login ~ '^[0-9]{8}$') для NULL проходит (NULL-результат = ок).
ALTER TABLE users ALTER COLUMN login DROP NOT NULL;

-- 2. username для входа по паролю: уникальный, 3-64 символа (у работников - NULL).
ALTER TABLE users
    ADD COLUMN username text UNIQUE
        CHECK (username IS NULL OR length(username) BETWEEN 3 AND 64);

-- 3. Ровно одно из (login, username) непустое (XOR): либо бейдж-работник, либо username-admin.
ALTER TABLE users
    ADD CONSTRAINT users_login_xor_username
        CHECK ((login IS NOT NULL) <> (username IS NOT NULL));
