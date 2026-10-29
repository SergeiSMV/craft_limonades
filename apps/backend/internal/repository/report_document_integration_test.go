package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"
	"github.com/testcontainers/testcontainers-go"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	"craftwms/internal/model"
	"craftwms/internal/repository"
	"craftwms/migrations"
)

// Тесты P3-01: документ отчёта — неизменяемый снимок содержимого на момент финала.
// Переиспользуют фикстуру setupStock (склад/ячейки/товар/партия) из stock_integration_test.go.

// mustUser заводит пользователя-исполнителя: сессия ввода остатков ссылается на created_by.
func mustUser(t *testing.T, pool *pgxpool.Pool) string {
	t.Helper()
	var id string
	mustScan(t, pool, `
		INSERT INTO users (login, password_hash, full_name)
		VALUES ('10000000','x','Кладовщик') RETURNING id::text`, &id)
	return id
}

// closedSession проводит сессию до финала: старт → строка по ячейке A → финал.
// Возвращает id закрытой сессии.
func closedSession(t *testing.T, fx *stockFixture, repo *repository.StockEntryRepository) string {
	t.Helper()
	ctx := context.Background()
	user := mustUser(t, fx.pool)

	var wh string
	mustScan(t, fx.pool, `SELECT warehouse_id::text FROM cells WHERE id = $1::uuid`, &wh, fx.cellA)

	sessionID, err := repo.Create(ctx, wh, user)
	if err != nil {
		t.Fatalf("создать сессию: %v", err)
	}
	if err := repo.Checkpoint(ctx, sessionID, repository.StockEntryCellInput{CellID: fx.cellA, Lines: []repository.StockEntryLineInput{{
		GoodID:         fx.good,
		ProductionDate: "2026-01-01",
		Qty:            decimal.RequireFromString("7"),
	}}}); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	if _, err := repo.Finalize(ctx, sessionID); err != nil {
		t.Fatalf("финал: %v", err)
	}
	return sessionID
}

// Главный критерий задачи: документ не меняется вслед за справочником. Переименование товара
// (а на проде это делает каждый импорт номенклатуры апсертом по «Код») не должно трогать отчёт,
// уже выданный оператору.
func TestReportDocument_snapshotSurvivesGoodRename(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewStockEntryRepository(fx.pool)
	sessionID := closedSession(t, fx, repo)

	docs := repository.NewReportDocumentRepository(fx.pool)
	before, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, sessionID)
	if err != nil {
		t.Fatalf("документ до переименования: %v", err)
	}
	if len(before.Snapshot.Rows) != 1 || before.Snapshot.Rows[0].GoodName != "Товар" {
		t.Fatalf("ожидал одну строку с «Товар», получил %+v", before.Snapshot.Rows)
	}

	// Импорт номенклатуры переименовал товар и переехала ячейка.
	if _, err := fx.pool.Exec(ctx, `UPDATE goods SET name = 'Товар (новое имя)' WHERE id = $1::uuid`, fx.good); err != nil {
		t.Fatalf("переименовать товар: %v", err)
	}
	if _, err := fx.pool.Exec(ctx, `UPDATE cells SET address = 'Z-9' WHERE id = $1::uuid`, fx.cellA); err != nil {
		t.Fatalf("сменить адрес ячейки: %v", err)
	}

	after, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, sessionID)
	if err != nil {
		t.Fatalf("документ после переименования: %v", err)
	}
	if after.Snapshot.Rows[0].GoodName != "Товар" {
		t.Errorf("наименование поехало за справочником: было «Товар», стало %q", after.Snapshot.Rows[0].GoodName)
	}
	if after.Snapshot.Rows[0].CellAddress != "A" {
		t.Errorf("адрес ячейки поехал за справочником: было «A», стало %q", after.Snapshot.Rows[0].CellAddress)
	}
	if after.Snapshot.Rows[0].Qty != before.Snapshot.Rows[0].Qty {
		t.Errorf("количество разъехалось: %q → %q", before.Snapshot.Rows[0].Qty, after.Snapshot.Rows[0].Qty)
	}
}

// Документ рождается вместе с закрытием сессии и ровно один на операцию.
func TestReportDocument_oneDocumentPerOperation(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewStockEntryRepository(fx.pool)
	sessionID := closedSession(t, fx, repo)

	var n int
	if err := fx.pool.QueryRow(ctx, `
		SELECT count(*) FROM report_documents
		WHERE source_type = 'stock_entry_session' AND source_id = $1::uuid`, sessionID).Scan(&n); err != nil {
		t.Fatalf("счёт документов: %v", err)
	}
	if n != 1 {
		t.Fatalf("ожидал один документ на операцию, получил %d", n)
	}

	// Грань идемпотентности: повтор (в т.ч. из очереди устройства) не заводит второй документ.
	if _, err := fx.pool.Exec(ctx, `
		INSERT INTO report_documents (kind, source_type, source_id, snapshot)
		VALUES ('stock_entry','stock_entry_session',$1::uuid,'{}'::jsonb)
		ON CONFLICT (source_type, source_id) DO NOTHING`, sessionID); err != nil {
		t.Fatalf("повторная вставка: %v", err)
	}
	if err := fx.pool.QueryRow(ctx, `
		SELECT count(*) FROM report_documents WHERE source_id = $1::uuid`, sessionID).Scan(&n); err != nil {
		t.Fatalf("счёт после повтора: %v", err)
	}
	if n != 1 {
		t.Errorf("повтор завёл лишний документ: %d", n)
	}
}

// Документ существует только у ЗАВЕРШЁННОЙ операции: по несуществующей и по ещё идущей сессии
// его нет. Раньше эти случаи различал отчёт по сессии (404/409); теперь документ адресуется
// сам по себе, и обе ситуации сводятся к «документа нет».
func TestReportDocument_noDocumentForUnfinishedWork(t *testing.T) {
	fx := setupStock(t)
	ctx := context.Background()
	repo := repository.NewStockEntryRepository(fx.pool)
	docs := repository.NewReportDocumentRepository(fx.pool)

	_, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, "00000000-0000-0000-0000-000000000000")
	if !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("нет сессии: ожидал ErrDocumentNotFound, получил %v", err)
	}

	user := mustUser(t, fx.pool)
	var wh string
	mustScan(t, fx.pool, `SELECT warehouse_id::text FROM cells WHERE id = $1::uuid`, &wh, fx.cellA)
	draft, err := repo.Create(ctx, wh, user)
	if err != nil {
		t.Fatalf("создать сессию: %v", err)
	}
	if _, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, draft); !errors.Is(err, repository.ErrDocumentNotFound) {
		t.Errorf("сессия в работе: ожидал ErrDocumentNotFound, получил %v", err)
	}
}

// Бэкофилл миграции 000009: сессии, закрытые ДО появления снимков, документ всё же получают.
// Без него список в портале показывал бы записи, которые невозможно скачать. На проде эта ветка
// выполнится ровно один раз, поэтому проверяется отдельно — накатом схемы по версиям.
func TestReportDocument_migrationBackfillsClosedSessions(t *testing.T) {
	testcontainers.SkipIfProviderIsNotHealthy(t)

	ctx := context.Background()
	ctr, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithDatabase("wms"),
		tcpostgres.WithUsername("wms"),
		tcpostgres.WithPassword("wms"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr)
	if err != nil {
		t.Fatalf("запуск postgres-контейнера: %v", err)
	}
	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("источник миграций: %v", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, strings.Replace(dsn, "postgres://", "pgx5://", 1))
	if err != nil {
		t.Fatalf("init migrate: %v", err)
	}

	// Схема состояния «до P3-01».
	if err := m.Migrate(8); err != nil {
		t.Fatalf("migrate to 8: %v", err)
	}
	pool, err := repository.NewPool(ctx, dsn)
	if err != nil {
		t.Fatalf("пул: %v", err)
	}
	t.Cleanup(pool.Close)

	// Закрытая сессия с одной строкой — как она выглядела бы на проде до миграции.
	var wh, cell, good, user, session string
	mustScan(t, pool, `INSERT INTO warehouses (code, name) VALUES ('WH9','старый') RETURNING id::text`, &wh)
	mustScan(t, pool, `INSERT INTO cells (warehouse_id, address) VALUES ($1::uuid,'K-1') RETURNING id::text`, &cell, wh)
	mustScan(t, pool, `INSERT INTO goods (name, uom) VALUES ('Старое имя','шт') RETURNING id::text`, &good)
	mustScan(t, pool, `INSERT INTO users (login, password_hash, full_name) VALUES ('10000001','x','К') RETURNING id::text`, &user)
	mustScan(t, pool, `
		INSERT INTO stock_entry_sessions (warehouse_id, created_by, status, closed_at)
		VALUES ($1::uuid,$2::uuid,'closed',now()) RETURNING id::text`, &session, wh, user)
	if _, err := pool.Exec(ctx, `
		INSERT INTO stock_entry_lines (session_id, cell_id, good_id, production_date, qty)
		VALUES ($1::uuid,$2::uuid,$3::uuid,'2026-02-02',3)`, session, cell, good); err != nil {
		t.Fatalf("строка сессии: %v", err)
	}

	// Собственно миграция P3-01 вместе с бэкофиллом.
	if err := m.Migrate(9); err != nil {
		t.Fatalf("migrate to 9: %v", err)
	}
	// Читает документ репозиторий текущей схемы — доводим схему до конца: бэкофилл 9 уже
	// лёг, последующие миграции снимок не меняют, а только дописывают номера (ADHOC-55).
	if err := m.Up(); err != nil {
		t.Fatalf("migrate up: %v", err)
	}

	docs := repository.NewReportDocumentRepository(pool)
	doc, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, session)
	if err != nil {
		t.Fatalf("документ по добэкофилленной сессии: %v", err)
	}
	if doc.Snapshot.WarehouseCode != "WH9" || len(doc.Snapshot.Rows) != 1 {
		t.Fatalf("бэкофилл собрал не то: %+v", doc.Snapshot)
	}
	row := doc.Snapshot.Rows[0]
	if row.CellAddress != "K-1" || row.GoodName != "Старое имя" || row.ProductionDate != "2026-02-02" {
		t.Errorf("строка бэкофилла: %+v", row)
	}
	if !strings.HasPrefix(row.Qty, "3") {
		t.Errorf("количество бэкофилла: %q", row.Qty)
	}

	// Снимок заморожен и здесь: после бэкофилла справочник больше на документ не влияет.
	if _, err := pool.Exec(ctx, `UPDATE goods SET name='Другое' WHERE id=$1::uuid`, good); err != nil {
		t.Fatalf("переименовать товар: %v", err)
	}
	after, err := docs.BySource(ctx, model.SourceTypeStockEntrySession, session)
	if err != nil {
		t.Fatalf("повторное чтение документа: %v", err)
	}
	if after.Snapshot.Rows[0].GoodName != "Старое имя" {
		t.Errorf("снимок бэкофилла поехал за справочником: %q", after.Snapshot.Rows[0].GoodName)
	}
}

// Бэкофилл миграции 000011: документы, существовавшие до журнала, получают историю задним числом.
// Иначе она начиналась бы с середины, хотя время создания и отметок известно из колонок состояния.
func TestReportDocument_migrationBackfillsJournal(t *testing.T) {
	testcontainers.SkipIfProviderIsNotHealthy(t)

	ctx := context.Background()
	ctr, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithDatabase("wms"),
		tcpostgres.WithUsername("wms"),
		tcpostgres.WithPassword("wms"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	testcontainers.CleanupContainer(t, ctr)
	if err != nil {
		t.Fatalf("запуск postgres-контейнера: %v", err)
	}
	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		t.Fatalf("источник миграций: %v", err)
	}
	m, err := migrate.NewWithSourceInstance("iofs", src, strings.Replace(dsn, "postgres://", "pgx5://", 1))
	if err != nil {
		t.Fatalf("init migrate: %v", err)
	}

	// Схема состояния «до P3-03»: документы и статусы уже есть, журнала ещё нет.
	if err := m.Migrate(10); err != nil {
		t.Fatalf("migrate to 10: %v", err)
	}
	pool, err := repository.NewPool(ctx, dsn)
	if err != nil {
		t.Fatalf("пул: %v", err)
	}
	t.Cleanup(pool.Close)

	var wh, user, session, docID string
	mustScan(t, pool, `INSERT INTO warehouses (code, name) VALUES ('WH8','до журнала') RETURNING id::text`, &wh)
	mustScan(t, pool, `INSERT INTO users (login, password_hash, full_name) VALUES ('10000002','x','Прошлый') RETURNING id::text`, &user)
	mustScan(t, pool, `
		INSERT INTO stock_entry_sessions (warehouse_id, created_by, status, closed_at)
		VALUES ($1::uuid,$2::uuid,'closed',now()) RETURNING id::text`, &session, wh, user)
	// Документ, который успели скачать и отметить выполненным до появления журнала.
	mustScan(t, pool, `
		INSERT INTO report_documents (kind, source_type, source_id, snapshot, status, downloaded_at, done_at)
		VALUES ('stock_entry','stock_entry_session',$1::uuid,'{"rows":[]}'::jsonb,'done',now(),now())
		RETURNING id::text`, &docID, session)

	if err := m.Migrate(11); err != nil {
		t.Fatalf("migrate to 11: %v", err)
	}

	events, err := repository.NewReportDocumentRepository(pool).Events(ctx, docID)
	if err != nil {
		t.Fatalf("журнал после бэкофилла: %v", err)
	}
	if len(events) != 3 {
		t.Fatalf("ожидалось 3 события (created/downloaded/done), получено %d: %+v", len(events), events)
	}
	if events[0].Event != model.DocEventCreated || events[0].UserName != "Прошлый" {
		t.Errorf("создание: %+v — автора берём из операции-источника", events[0])
	}
	// У скачивания и отметки автор неизвестен: тогда его не записывали, и выдумывать нельзя.
	for _, e := range events[1:] {
		if e.UserID != nil || e.UserName != "" {
			t.Errorf("событие %q получило автора из ниоткуда: %+v", e.Event, e)
		}
	}
}
