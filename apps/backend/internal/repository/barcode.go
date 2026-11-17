package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/barcode"
	"craftwms/internal/model"
)

// BarcodeRepository - доступ к таблице barcodes: товар 1→N ШК, сам ШК глобально уникален.
type BarcodeRepository struct {
	pool *pgxpool.Pool
}

// NewBarcodeRepository создаёт репозиторий штрихкодов.
func NewBarcodeRepository(pool *pgxpool.Pool) *BarcodeRepository {
	return &BarcodeRepository{pool: pool}
}

// GetGoodByBarcode резолвит товар по ШК (с именами группы/поставщика, как GoodsRepository.GetByID).
// Нет такого ШК → ErrNotFound: для ввода остатков это сигнал открыть привязку.
func (r *BarcodeRepository) GetGoodByBarcode(ctx context.Context, code string) (model.Good, error) {
	var g model.Good
	err := r.pool.QueryRow(ctx, `
		SELECT g.id::text, g.code, g.name, g.full_name, g.uom,
		       g.group_id::text, ng.name, g.supplier_id::text, s.name, g.is_active, g.cz_marked
		FROM barcodes b
		JOIN goods g                     ON g.id = b.good_id
		LEFT JOIN nomenclature_groups ng ON ng.id = g.group_id
		LEFT JOIN suppliers s            ON s.id = g.supplier_id
		WHERE b.barcode = $1`, code).
		Scan(&g.ID, &g.Code, &g.Name, &g.FullName, &g.UOM,
			&g.GroupID, &g.GroupName, &g.SupplierID, &g.SupplierName, &g.IsActive, &g.CZMarked)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Good{}, model.ErrNotFound
	}
	if err != nil {
		return model.Good{}, fmt.Errorf("get good by barcode %q: %w", code, err)
	}
	return g, nil
}

// ListByGood возвращает все ШК товара (для секции «Штрихкоды» в карточке, P-FS-12).
// Пустой список - норма (у товара нет ШК). Порядок - по строке ШК, стабилен для UI.
func (r *BarcodeRepository) ListByGood(ctx context.Context, goodID string) ([]model.Barcode, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT barcode, symbology FROM barcodes WHERE good_id = $1::uuid ORDER BY barcode`, goodID)
	if err != nil {
		return nil, fmt.Errorf("list barcodes by good %q: %w", goodID, err)
	}
	defer rows.Close()

	out := []model.Barcode{} // всегда не nil → JSON `[]`, а не `null`
	for rows.Next() {
		var b model.Barcode
		if err := rows.Scan(&b.Barcode, &b.Symbology); err != nil {
			return nil, fmt.Errorf("scan barcode: %w", err)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate barcodes: %w", err)
	}
	return out, nil
}

// List возвращает страницу всех привязок ШК - справочник целиком для кэша устройства (P2-02).
//
// Зачем отдельный метод, а не обход товаров: привязок на порядок меньше, чем товаров, и тянуть
// их по одному запросу на товар (780 поездок) для офлайн-кэша неприемлемо.
//
// Total считаем окном COUNT(*) OVER() в том же запросе - одна поездка в БД вместо двух.
// Порядок по ШК стабилен, поэтому страницы не перемешиваются между запросами.
func (r *BarcodeRepository) List(ctx context.Context, limit, offset int) ([]model.BarcodeLink, int, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT barcode, good_id::text, symbology, COUNT(*) OVER() AS total
		   FROM barcodes
		  ORDER BY barcode
		  LIMIT $1 OFFSET $2`, limit, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("list barcodes: %w", err)
	}
	defer rows.Close()

	out := []model.BarcodeLink{} // всегда не nil → JSON `[]`, а не `null`
	total := 0
	for rows.Next() {
		var b model.BarcodeLink
		if err := rows.Scan(&b.Barcode, &b.GoodID, &b.Symbology, &total); err != nil {
			return nil, 0, fmt.Errorf("scan barcode link: %w", err)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("iterate barcode links: %w", err)
	}
	return out, total, nil
}

// Unbind удаляет привязку ШК (отвязка ошибочного ШК, P-FS-12). ШК глобально уникален, поэтому
// удаляем по коду. Идемпотентно: нет такой привязки → не ошибка (коррекция не должна падать,
// если ШК уже отвязали).
func (r *BarcodeRepository) Unbind(ctx context.Context, barcode string) error {
	return unbindBarcode(ctx, r.pool, barcode)
}

// unbindBarcode - низкоуровневая отвязка на Querier (пул или tx), зеркало bindBarcode. Нужна,
// чтобы отвязка коммитилась в одной транзакции с пометкой операции в журнале идемпотентности
// (P2-05): порознь они дали бы момент, в котором ШК уже отвязан, а операция не помечена.
//
// Марки ЧЗ этого ШК на складе отвязку запрещают (ADHOC-53): без ШК их товар не находится сканом,
// а исправить ошибочную привязку - это перепривязка с пересортом ([BarcodeRepository.Regrade]).
func unbindBarcode(ctx context.Context, q Querier, barcode string) error {
	n, err := czStockOfBarcode(ctx, q, barcode)
	if err != nil {
		return err
	}
	if n > 0 {
		return model.ErrBarcodeHasCZStock
	}
	if _, err := q.Exec(ctx, `DELETE FROM barcodes WHERE barcode = $1`, barcode); err != nil {
		return fmt.Errorf("unbind barcode %q: %w", barcode, err)
	}
	return nil
}

// Bind привязывает ШК к товару. Аддитивно - у товара может быть много ШК. Идемпотентно:
// повторная привязка того же ШК к тому же товару - ок; занятый ШК другим товаром →
// ErrBarcodeConflict; несуществующий товар → ErrGoodNotFound; пустая symbology → NULL.
func (r *BarcodeRepository) Bind(ctx context.Context, goodID, barcode, symbology string) error {
	return bindBarcode(ctx, r.pool, goodID, barcode, symbology)
}

// InternalByGood возвращает внутренний ШК товара или ErrNotFound.
//
// Нужен перед генерацией: товару незачем второй внутренний код. Ищем ПО ФЛАГУ, а не по
// префиксу строки - выгрузка 1С может принести внутренний код чужой системы с тем же
// префиксом, и разбор строки выдал бы его за наш.
func (r *BarcodeRepository) InternalByGood(ctx context.Context, goodID string) (string, error) {
	var code string
	err := r.pool.QueryRow(ctx, `
		SELECT barcode FROM barcodes
		WHERE good_id = $1::uuid AND is_internal
		ORDER BY created_at
		LIMIT 1`, goodID).Scan(&code)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", model.ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("внутренний ШК товара: %w", err)
	}
	return code, nil
}

// CreateInternal выдаёт товару новый внутренний ШК и возвращает его.
//
// Номер берётся из последовательности: при двух одновременных генерациях выбор max()+1 выдал бы
// один номер дважды. Код собирается из номера и сразу проверяется контрольной цифрой самим
// построением (P4-07).
//
// Повтор при столкновении нужен не для подстраховки от последовательности - она уникальна,
// - а на случай, когда ровно такой код уже лежит в справочнике как ВНЕШНИЙ: выгрузка 1С могла
// принести внутренний код прежней системы с тем же префиксом. Тогда берём следующий номер.
func (r *BarcodeRepository) CreateInternal(ctx context.Context, goodID string) (string, error) {
	const attempts = 5
	for range attempts {
		var serial int64
		if err := r.pool.QueryRow(ctx,
			`SELECT nextval('internal_barcode_serial')`).Scan(&serial); err != nil {
			return "", fmt.Errorf("номер внутреннего ШК: %w", err)
		}
		code, err := barcode.Internal(barcode.InternalPrefix, serial)
		if err != nil {
			return "", fmt.Errorf("собрать внутренний ШК: %w", err)
		}
		tag, err := r.pool.Exec(ctx, `
			INSERT INTO barcodes (good_id, barcode, symbology, is_internal)
			VALUES ($1::uuid, $2, 'ean13', true)
			ON CONFLICT (barcode) DO NOTHING`, goodID, code)
		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23503" { // нет такого товара
				return "", model.ErrGoodNotFound
			}
			return "", fmt.Errorf("выдать внутренний ШК: %w", err)
		}
		if tag.RowsAffected() == 1 {
			return code, nil
		}
		// Код занят внешней привязкой - берём следующий номер.
	}
	return "", fmt.Errorf("не удалось выдать внутренний ШК за %d попыток", attempts)
}

// bindBarcode - низкоуровневая привязка на Querier (пул или tx), чтобы checkpoint сессии ввода
// (P-FS-04) коммитил новые привязки в той же транзакции, что и строки ячейки.
func bindBarcode(ctx context.Context, q Querier, goodID, barcode, symbology string) error {
	if err := guardBindMarks(ctx, q, goodID, barcode); err != nil {
		return err
	}
	// Вставляем; конфликт по UNIQUE(barcode) не роняем - разберём ниже (идемпотентность vs конфликт).
	tag, err := q.Exec(ctx, `
		INSERT INTO barcodes (good_id, barcode, symbology)
		VALUES ($1, $2, NULLIF($3,''))
		ON CONFLICT (barcode) DO NOTHING`,
		goodID, barcode, symbology)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23503" { // FK violation → нет такого товара
			return model.ErrGoodNotFound
		}
		return fmt.Errorf("bind barcode: %w", err)
	}
	if tag.RowsAffected() == 1 {
		return nil // новая привязка создана
	}
	// Вставки не было → ШК уже существует. Идемпотентно, если он за ЭТИМ же товаром, иначе конфликт.
	var existingGood string
	if err := q.QueryRow(ctx,
		`SELECT good_id::text FROM barcodes WHERE barcode = $1`, barcode).Scan(&existingGood); err != nil {
		return fmt.Errorf("check existing barcode: %w", err)
	}
	if existingGood != goodID {
		return model.ErrBarcodeConflict
	}
	return nil // тот же товар → идемпотентно
}
