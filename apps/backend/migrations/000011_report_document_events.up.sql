-- P3-03: журнал документа — что с ним происходило, когда и по чьей воле.
--
-- Зачем. Статус (000010) отвечает на вопрос «в каком состоянии документ сейчас», но не на вопрос
-- «что с ним было». Когда данные в 1С разошлись с документом, нужно знать: кто его скачал и когда,
-- скачивали ли повторно, кто отметил выполненным. Ни один из этих вопросов колонки состояния
-- не закрывают: они хранят ПОСЛЕДНЕЕ значение, а спор всегда про историю.
--
-- Почему таблица, а не колонки downloaded_by/done_by. Документ скачивают многократно и разные
-- люди — колонка сохранит одного и сотрёт остальных. Сюда же ложатся события, которым в колонках
-- места нет вовсе: неудачная сборка файла (оператор видит ошибку, а в базе не остаётся следа).
CREATE TABLE report_document_events (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- порядковый: журнал только дописывается
    document_id uuid        NOT NULL REFERENCES report_documents(id) ON DELETE CASCADE,
    event       text        NOT NULL
                            CHECK (event IN ('created','downloaded','done','generation_failed')),
    user_id     uuid        REFERENCES users(id),   -- кто; NULL — событие системное
    details     jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- контекст: текст ошибки и т.п.
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Единственный способ чтения журнала: история одного документа по времени.
CREATE INDEX report_document_events_document_idx ON report_document_events (document_id, created_at);

COMMENT ON TABLE report_document_events IS
    'P3-03: журнал документа — created (сформирован), downloaded (скачан), done (занесён в 1С), '
    'generation_failed (файл не собрался). Только дописывается, строки не меняются.';
COMMENT ON COLUMN report_document_events.user_id IS
    'Кто вызвал событие. NULL допустим: created рождается в транзакции завершения операции, '
    'а не по нажатию человека.';

-- Документы, существующие до этой миграции, получают событие «сформирован» задним числом:
-- иначе их история начиналась бы с середины, а по времени создания оно всё равно известно.
-- Автор — тот, кто вёл операцию-источник (для ввода остатков это кладовщик, закрывший проход).
INSERT INTO report_document_events (document_id, event, user_id, created_at)
SELECT d.id, 'created', s.created_by, d.created_at
FROM report_documents d
LEFT JOIN stock_entry_sessions s
       ON d.source_type = 'stock_entry_session' AND s.id = d.source_id;

-- Скачивания и отметки, случившиеся до журнала, восстанавливаем из колонок состояния.
-- Пользователь неизвестен (его тогда не записывали) — оставляем NULL, а не выдумываем.
INSERT INTO report_document_events (document_id, event, created_at)
SELECT id, 'downloaded', downloaded_at FROM report_documents WHERE downloaded_at IS NOT NULL;

INSERT INTO report_document_events (document_id, event, created_at)
SELECT id, 'done', done_at FROM report_documents WHERE done_at IS NOT NULL;
