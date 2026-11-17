-- ADHOC-45: фото к проблеме склада.
--
-- Решения (2026-10-24). Фото хранятся в базе (bytea), а не файлами на сервере: проблем на складе
-- единицы в день, снимок, сжатый на ТСД, - 200-400 КБ, это десятки мегабайт в год. Зато фото
-- сами попадают в ежедневный зашифрованный бэкап, проверку восстановления и обнуление базы перед
-- пилотом; каталог файлов пришлось бы бэкапить, шифровать и чистить отдельно.
-- До трёх фото на проблему, добавлять - пока проблема открыта (держит сервис под блокировкой
-- проблемы: CHECK одной строки соседей не видит).
CREATE TABLE problem_photos (
    -- Идентификатор ВЫДАЁТ УСТРОЙСТВО, как у самой проблемы: фото снимают без связи и грузят
    -- своей очередью; повтор загрузки упирается в первичный ключ и не задваивает снимок.
    id           uuid        PRIMARY KEY,
    -- Удалить проблему с фото нельзя - проблемы и так не удаляются; каскада нет.
    problem_id   uuid        NOT NULL REFERENCES warehouse_problems(id),
    content      bytea       NOT NULL,
    -- Тип снимка: ТСД шлёт JPEG; поле - чтобы отдавать снимок с верным Content-Type.
    content_type text        NOT NULL DEFAULT 'image/jpeg'
                             CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),
    -- Размер - до 1 МБ: ТСД сжимает до ~1600 px, больше - не снимок склада, а ошибка клиента.
    size_bytes   integer     NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 1048576),
    created_by   uuid        NOT NULL REFERENCES users(id),
    created_at   timestamptz NOT NULL DEFAULT now(),

    CHECK (octet_length(content) = size_bytes)
);

-- «Фото проблемы» - в порядке съёмки.
CREATE INDEX problem_photos_problem_idx ON problem_photos (problem_id, created_at);

COMMENT ON TABLE problem_photos IS
    'ADHOC-45: фото к проблеме склада - до трёх, снимает ТСД, хранится в базе (bytea).';
