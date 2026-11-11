package service

import (
	"context"
	"errors"
	"testing"

	"craftwms/internal/model"
)

// ADHOC-70: пачка марок читается одним запросом в ЧЗ, товар по GTIN ищется один раз, отказ по
// коду остаётся в его ответе и пачку не роняет.
func TestScanMany(t *testing.T) {
	mark2 := "0104612728200172215Bq7Lmz"
	foreign := "0104600000000017215Zx9Kq1"
	client := &scanClient{infos: map[string]model.CisInfo{
		beerMark: unit(beerMark, beerGTIN, "Голубые Гавайи 30 л", "2026-10-12"),
		mark2:    unit(mark2, beerGTIN, "Голубые Гавайи 30 л", "2026-10-12"),
		foreign:  unit(foreign, "04600000000017", "Нектар", "2026-09-01"),
	}}
	marks := &scanMarks{goods: map[string]model.CZGoodRef{beerGTIN: {ID: "g1", Name: "Пиво"}}}
	raws := []string{"]d2" + beerMark + "\x1d93tail", mark2, "4612728200172", beerMark,
		"0104612728200172215unknown", foreign}

	items, err := NewCZService(client, marks).ScanMany(context.Background(), raws)
	if err != nil {
		t.Fatal(err)
	}
	if len(client.calls) != 1 || len(client.calls[0]) != 4 {
		t.Fatalf("запросы в ЧЗ: %v; ждали один запрос на 4 разных кода", client.calls)
	}
	if marks.goodCalls != 2 {
		t.Fatalf("поиск товара по GTIN: %d раз, ждали по разу на GTIN", marks.goodCalls)
	}
	if len(items) != len(raws) {
		t.Fatalf("ответов %d, кодов %d", len(items), len(raws))
	}
	for i, raw := range raws {
		if items[i].Requested != raw {
			t.Fatalf("ответ %d: requested %q, ждали %q", i, items[i].Requested, raw)
		}
	}
	for _, i := range []int{0, 1, 3} {
		if items[i].Err != nil || items[i].Scan.Good == nil || items[i].Scan.Good.ID != "g1" {
			t.Fatalf("марка %d: %+v", i, items[i])
		}
	}
	if !errors.Is(items[2].Err, model.ErrCZBadCode) {
		t.Fatalf("ШК: %v", items[2].Err)
	}
	if !errors.Is(items[4].Err, model.ErrCZNotFound) {
		t.Fatalf("нет в ЧЗ: %v", items[4].Err)
	}
	if items[5].Err != nil || items[5].Scan.Good != nil || items[5].Scan.BindBarcode != "4600000000017" {
		t.Fatalf("незнакомый GTIN: %+v", items[5])
	}
}

func TestScanMany_limits(t *testing.T) {
	svc := NewCZService(&scanClient{}, nil)
	if _, err := svc.ScanMany(context.Background(), nil); !errors.Is(err, ErrCZNoCodes) {
		t.Fatalf("пусто: %v", err)
	}
	if _, err := svc.ScanMany(context.Background(), make([]string, czMaxCodes+1)); !errors.Is(err, ErrCZTooManyCodes) {
		t.Fatalf("сверх предела: %v", err)
	}
	if _, err := NewCZService(nil, nil).ScanMany(context.Background(), []string{beerMark}); !errors.Is(err, model.ErrCZNotConfigured) {
		t.Fatalf("не настроено: %v", err)
	}
	client := &scanClient{}
	items, err := NewCZService(client, nil).ScanMany(context.Background(), []string{"A-1-1"})
	if err != nil || len(client.calls) != 0 || !errors.Is(items[0].Err, model.ErrCZBadCode) {
		t.Fatalf("только неверные коды: %v, %v, запросов %d", items, err, len(client.calls))
	}
}
