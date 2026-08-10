package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"craftwms/internal/model"
)

// Ошибки привязки штрихкодов.
var (
	// ErrBarcodeConflict — ШК уже привязан к ДРУГОМУ товару (один ШК → один товар).
	ErrBarcodeConflict = errors.New("barcode bound to another good")
	// ErrGoodNotFound — привязка к несуществующему товару (FK).
	ErrGoodNotFound = errors.New("good not found")
)

// BarcodeRepository — доступ к таблице barcodes: товар 1→N ШК, сам ШК глобально уникален.
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
		       g.group_id::text, ng.name, g.supplier_id::text, s.name, g.is_active
		FROM barcodes b
		JOIN goods g                     ON g.id = b.good_id
		LEFT JOIN nomenclature_groups ng ON ng.id = g.group_id
		LEFT JOIN suppliers s            ON s.id = g.supplier_id
		WHERE b.barcode = $1`, code).
		Scan(&g.ID, &g.Code, &g.Name, &g.FullName, &g.UOM,
			&g.GroupID, &g.GroupName, &g.SupplierID, &g.SupplierName, &g.IsActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return model.Good{}, ErrNotFound
	}
	if err != nil {
		return model.Good{}, fmt.Errorf("get good by barcode %q: %w", code, err)
	}
	return g, nil
}

// Bind привязывает ШК к товару. Аддитивно — у товара может быть много ШК. Идемпотентно:
// повторная привязка того же ШК к тому же товару — ок; занятый ШК другим товаром →
// ErrBarcodeConflict; несуществующий товар → ErrGoodNotFound; пустая symbology → NULL.
func (r *BarcodeRepository) Bind(ctx context.Context, goodID, barcode, symbology string) error {
	return bindBarcode(ctx, r.pool, goodID, barcode, symbology)
}

// bindBarcode — низкоуровневая привязка на Querier (пул или tx), чтобы checkpoint сессии ввода
// (P-FS-04) коммитил новые привязки в той же транзакции, что и строки ячейки.
func bindBarcode(ctx context.Context, q Querier, goodID, barcode, symbology string) error {
	// Вставляем; конфликт по UNIQUE(barcode) не роняем — разберём ниже (идемпотентность vs конфликт).
	tag, err := q.Exec(ctx, `
		INSERT INTO barcodes (good_id, barcode, symbology)
		VALUES ($1, $2, NULLIF($3,''))
		ON CONFLICT (barcode) DO NOTHING`,
		goodID, barcode, symbology)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23503" { // FK violation → нет такого товара
			return ErrGoodNotFound
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
		return ErrBarcodeConflict
	}
	return nil // тот же товар → идемпотентно
}
