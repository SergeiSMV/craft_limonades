package service

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"craftwms/internal/model"
)

// Тесты CZ-04, шаг 1: скан марки и короба над подставными ЧЗ и хранилищем марок.
// Коды — по образцу живого короба пива, прочитанного на проде в CZ-02.

const (
	beerGTIN = "04612728200172"
	beerBox  = "00146801691100407293"
	beerMark = "0104612728200172215AmxPmd"
)

// scanClient — фальшивый True API: ответы по кодам и журнал запросов.
type scanClient struct {
	infos map[string]model.CisInfo
	calls [][]string
}

func (c *scanClient) CisesInfo(_ context.Context, codes []string) ([]model.CisInfo, error) {
	c.calls = append(c.calls, codes)
	out := make([]model.CisInfo, 0, len(codes))
	for _, code := range codes {
		if it, ok := c.infos[code]; ok {
			out = append(out, it)
			continue
		}
		out = append(out, model.CisInfo{RequestedCis: code, ErrorMessage: "Код не найден"})
	}
	return out, nil
}
func (c *scanClient) TokenExpiry() (time.Time, bool)     { return time.Time{}, false }
func (c *scanClient) SignerHealth(context.Context) error { return nil }

// unit — ответ ЧЗ по единице.
func unit(cis, gtin, name, produced string) model.CisInfo {
	return model.CisInfo{RequestedCis: cis, Cis: cis, Gtin: gtin, ProductName: name,
		PackageType: "UNIT", PackageLevel: "UNIT", ProducedDate: produced + "T00:00:00.000Z"}
}

// scanMarks — хранилище марок в памяти; goodCalls — сколько раз искали товар по GTIN.
type scanMarks struct {
	goods     map[string]model.CZGoodRef
	marks     map[string]model.CZMark
	boxes     map[string]string
	goodCalls int
}

func (m *scanMarks) GoodByGTIN(_ context.Context, gtin string) (model.CZGoodRef, error) {
	m.goodCalls++
	if g, ok := m.goods[gtin]; ok {
		return g, nil
	}
	return model.CZGoodRef{}, fmt.Errorf("%w: %s", model.ErrCZUnknownGTIN, gtin)
}
func (m *scanMarks) MarkByCIS(_ context.Context, cis string) (model.CZMark, error) {
	if mk, ok := m.marks[cis]; ok {
		return mk, nil
	}
	return model.CZMark{}, model.ErrCZMarkNotFound
}
func (m *scanMarks) LoadUnitByCZCode(_ context.Context, code string) (string, error) {
	if id, ok := m.boxes[code]; ok {
		return id, nil
	}
	return "", model.ErrCZAggregateNotFound
}

func TestNormalizeCZCode(t *testing.T) {
	cases := []struct{ name, raw, want string }{
		{"марка со сканера: AIM, FNC1, криптохвост", "]d2\x1d" + beerMark + "\x1d93dGVz", beerMark},
		{"марка без префикса", "  " + beerMark + "\x1d", beerMark},
		{"короб GS1-128 с AIM", "]C1" + beerBox, beerBox},
		{"короб без префикса", beerBox, beerBox},
	}
	for _, tc := range cases {
		if got, err := NormalizeCZCode(tc.raw); err != nil || got != tc.want {
			t.Errorf("%s: %q, %v; want %q", tc.name, got, err, tc.want)
		}
	}
	for _, bad := range []string{"", "4612728200172", "0014680169110040729", "A-1-1", "]d2"} {
		if _, err := NormalizeCZCode(bad); !errors.Is(err, model.ErrCZBadCode) {
			t.Errorf("%q: err = %v, want ErrCZBadCode", bad, err)
		}
	}
}

func TestScanMark(t *testing.T) {
	client := &scanClient{infos: map[string]model.CisInfo{
		beerMark: unit(beerMark, beerGTIN, "Голубые Гавайи 30 л", "2026-10-12"),
	}}
	received := time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)

	t.Run("товар известен, марка в WMS", func(t *testing.T) {
		marks := &scanMarks{
			goods: map[string]model.CZGoodRef{beerGTIN: {ID: "g1", Name: "Пиво Голубые Гавайи, кега"}},
			marks: map[string]model.CZMark{beerMark: {CIS: beerMark, LoadUnitID: "lu1", ReceivedAt: received}},
		}
		got, err := NewCZService(client, marks).Scan(context.Background(), "]d2"+beerMark+"\x1d93tail")
		if err != nil {
			t.Fatal(err)
		}
		// Наименование ЧЗ и товар справочника — разные поля и могут не совпадать.
		if got.Code != beerMark || got.Info.ProductName != "Голубые Гавайи 30 л" ||
			got.Good == nil || got.Good.ID != "g1" || got.BindBarcode != "" ||
			got.Mark == nil || got.Mark.LoadUnitID != "lu1" || !got.Mark.ReceivedAt.Equal(received) ||
			len(got.Composition) != 0 {
			t.Fatalf("скан = %+v", got)
		}
	})

	t.Run("GTIN незнаком — привязать EAN-13", func(t *testing.T) {
		got, err := NewCZService(client, &scanMarks{}).Scan(context.Background(), beerMark)
		if err != nil {
			t.Fatal(err)
		}
		if got.Good != nil || got.BindBarcode != "4612728200172" || got.Mark != nil {
			t.Fatalf("скан = %+v", got)
		}
	})
}

func TestScanBox(t *testing.T) {
	const group = "0104612728200189215grp001"
	infos := map[string]model.CisInfo{
		beerBox: {RequestedCis: beerBox, Cis: beerBox, PackageType: "BOX", PackageLevel: "LEVEL1",
			Child: []string{group, "0104612728200172215u1", "0104612728200172215broken"}},
		group: {RequestedCis: group, Cis: group, Gtin: "04612728200189", PackageType: "GROUP",
			PackageLevel: "LEVEL1", ProducedDate: "2026-10-14T07:19:00.000Z",
			Child: []string{"0104612728200172215u2", "0104612728200172215u3"}},
		// Партия — дата производства единицы, а не упаковки: u3 из другой партии.
		"0104612728200172215u1": unit("0104612728200172215u1", beerGTIN, "Голубые Гавайи 30 л", "2026-10-12"),
		"0104612728200172215u2": unit("0104612728200172215u2", beerGTIN, "Голубые Гавайи 30 л", "2026-10-12"),
		"0104612728200172215u3": unit("0104612728200172215u3", beerGTIN, "Голубые Гавайи 30 л", "2026-10-13"),
	}
	client := &scanClient{infos: infos}
	marks := &scanMarks{
		goods: map[string]model.CZGoodRef{beerGTIN: {ID: "g1", Name: "Пиво"}},
		boxes: map[string]string{beerBox: "lu-box"},
	}

	got, err := NewCZService(client, marks).Scan(context.Background(), "]C1"+beerBox)
	if err != nil {
		t.Fatal(err)
	}
	if got.LoadUnitID != "lu-box" || got.Units != 3 || len(got.Composition) != 2 ||
		len(got.Unreadable) != 1 || got.Unreadable[0] != "0104612728200172215broken" {
		t.Fatalf("скан короба = %+v", got)
	}
	first, second := got.Composition[0], got.Composition[1]
	if first.ProducedDate != "2026-10-12" || first.Count != 2 || first.Good == nil || first.Good.ID != "g1" ||
		second.ProducedDate != "2026-10-13" || second.Count != 1 {
		t.Fatalf("состав = %+v", got.Composition)
	}
	// Товар по GTIN ищется один раз на GTIN, а не на каждую единицу.
	if marks.goodCalls != 1 {
		t.Fatalf("поиск товара по GTIN: %d раз", marks.goodCalls)
	}
	// Запросы к ЧЗ: сам короб, его вложенные, вложенные упаковки.
	if len(client.calls) != 3 {
		t.Fatalf("запросов к ЧЗ: %d", len(client.calls))
	}
}

func TestScanBoxChunks(t *testing.T) {
	infos := map[string]model.CisInfo{}
	var children []string
	for i := range 150 {
		cis := fmt.Sprintf("0104612728200172215n%03d", i)
		children = append(children, cis)
		infos[cis] = unit(cis, beerGTIN, "Пиво", "2026-10-12")
	}
	infos[beerBox] = model.CisInfo{RequestedCis: beerBox, Cis: beerBox, PackageType: "BOX", Child: children}
	client := &scanClient{infos: infos}

	got, err := NewCZService(client, &scanMarks{}).Scan(context.Background(), beerBox)
	if err != nil {
		t.Fatal(err)
	}
	if got.Units != 150 || len(got.Composition) != 1 || got.Composition[0].Good != nil || got.LoadUnitID != "" {
		t.Fatalf("скан = %d единиц, %+v", got.Units, got.Composition)
	}
	for _, call := range client.calls {
		if len(call) > czMaxCodes {
			t.Fatalf("запрос к ЧЗ на %d кодов, предел %d", len(call), czMaxCodes)
		}
	}
	if len(client.calls) != 3 { // короб + 100 + 50
		t.Fatalf("запросов к ЧЗ: %d", len(client.calls))
	}
}

func TestScanErrors(t *testing.T) {
	if _, err := NewCZService(nil, nil).Scan(context.Background(), beerMark); !errors.Is(err, model.ErrCZNotConfigured) {
		t.Fatalf("не настроено: %v", err)
	}
	s := NewCZService(&scanClient{}, &scanMarks{})
	if _, err := s.Scan(context.Background(), "4612728200172"); !errors.Is(err, model.ErrCZBadCode) {
		t.Fatalf("ШК вместо марки: %v", err)
	}
	if _, err := s.Scan(context.Background(), beerMark); !errors.Is(err, model.ErrCZNotFound) {
		t.Fatalf("марки нет в ЧЗ: %v", err)
	}
	// Без хранилища марок (нет БД) — только данные ЧЗ.
	client := &scanClient{infos: map[string]model.CisInfo{beerMark: unit(beerMark, beerGTIN, "Пиво", "2026-10-12")}}
	got, err := NewCZService(client, nil).Scan(context.Background(), beerMark)
	if err != nil || got.Good != nil || got.Mark != nil || got.BindBarcode != "" {
		t.Fatalf("без БД: %+v, %v", got, err)
	}
}
