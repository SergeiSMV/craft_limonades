package handler_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// Тесты CZ-04, шаг 2: POST /api/v1/cz/scan через настоящий роутер. Ответы по марке и коробу
// обязаны совпасть с эталонами testdata/cz_scan_mark.json и cz_scan_box.json — их же
// разбирает клиент ТСД.

const (
	scanGood   = "11111111-0000-4000-8000-000000000001"
	scanLU     = "22222222-0000-4000-8000-000000000001"
	scanCell   = "33333333-0000-4000-8000-000000000001"
	scanBox    = "00146801691100407293"
	scanMark   = "0104612728200172215AmxPmd"
	scanMark2  = "0104612728200172215:Tf(gc"
	scanBroken = "0104612728200172215broken"
	scanGTIN   = "04612728200172"
	scanName   = `Напиток пивной фильтрованный пастеризованный "Голубые Гавайи" 30 л.`
	scanOwner  = `ООО "ТД "КРАФТОВЫЕ ЛИМОНАДЫ"`
)

// scanCZClient — True API с ответами живого короба пива (CZ-02).
type scanCZClient struct{ czClientStub }

func (scanCZClient) CisesInfo(_ context.Context, codes []string) ([]model.CisInfo, error) {
	unit := func(cis string) model.CisInfo {
		return model.CisInfo{RequestedCis: cis, Cis: cis, Gtin: scanGTIN, ProductName: scanName,
			ProductGroup: "beer", PackageType: "UNIT", PackageLevel: "UNIT", Status: "INTRODUCED",
			OwnerInn: "6234203222", OwnerName: scanOwner, ProducedDate: "2026-10-12T00:00:00.000Z",
			ExpirationDate: "2027-04-10T00:00:00.000Z", Parent: scanBox}
	}
	out := make([]model.CisInfo, 0, len(codes))
	for _, c := range codes {
		switch c {
		case scanBox:
			out = append(out, model.CisInfo{RequestedCis: c, Cis: c, ProductGroup: "beer",
				PackageType: "BOX", PackageLevel: "LEVEL1", Status: "INTRODUCED", OwnerInn: "6234203222",
				OwnerName: scanOwner, Child: []string{scanMark, scanMark2, scanBroken}})
		case scanMark, scanMark2:
			out = append(out, unit(c))
		default:
			out = append(out, model.CisInfo{RequestedCis: c, ErrorMessage: "Код не найден"})
		}
	}
	return out, nil
}

// scanCZMarks — WMS знает товар, марку в коробе и сам короб.
type scanCZMarks struct{}

func (scanCZMarks) GoodByGTIN(context.Context, string) (model.CZGoodRef, error) {
	return model.CZGoodRef{ID: scanGood, Name: "Пиво «Голубые Гавайи», кега 30 л"}, nil
}
func (scanCZMarks) MarkByCIS(_ context.Context, cis string) (model.CZMark, error) {
	if cis != scanMark {
		return model.CZMark{}, model.ErrCZMarkNotFound
	}
	return model.CZMark{CIS: cis, GoodID: scanGood, Status: model.CZMarkInStock, LoadUnitID: scanLU, LoadUnitCellID: scanCell,
		AggregateCode: scanBox, CellAddress: "M1-1-10-1", ReceivedAt: time.Date(2026, 10, 23, 12, 0, 0, 0, time.FixedZone("MSK", 3*3600))}, nil
}
func (scanCZMarks) GoodRef(_ context.Context, id string) (model.CZGoodRef, error) {
	return model.CZGoodRef{ID: id, Name: "Пиво «Голубые Гавайи», кега 30 л"}, nil
}
func (scanCZMarks) LoadUnitByCZCode(context.Context, string) (string, error) { return scanLU, nil }
func (scanCZMarks) SetGoodCZMarked(_ context.Context, id string, _ bool) error {
	if id != scanGood {
		return model.ErrCZGoodNotFound
	}
	return nil
}

func scanBody(code string) string {
	b, _ := json.Marshal(map[string]string{"code": code})
	return string(b)
}

func TestCZScan_wireFormat(t *testing.T) {
	router, _, worker := czRouter(t, service.NewCZService(scanCZClient{}, scanCZMarks{}))
	cases := []struct{ golden, code string }{
		{"cz_scan_mark.json", "]d2\x1d" + scanMark + "\x1d93dGVz"}, // как со сканера DT50S
		{"cz_scan_box.json", "]C1" + scanBox},
	}
	for _, tc := range cases {
		t.Run(tc.golden, func(t *testing.T) {
			rec := czCall(router, worker, http.MethodPost, "/api/v1/cz/scan", scanBody(tc.code))
			if rec.Code != http.StatusOK {
				t.Fatalf("код %d: %s", rec.Code, rec.Body)
			}
			var want, got map[string]any
			if err := json.Unmarshal(readFixture(t, tc.golden), &want); err != nil {
				t.Fatalf("эталон не разбирается: %v", err)
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("ответ не разбирается: %v", err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("ответ разошёлся с эталоном testdata/%s — сверьте формат с тем, что "+
					"разбирает клиент.\nПолучено: %s", tc.golden, rec.Body)
			}
		})
	}
}

func TestCZScan_access(t *testing.T) {
	router, _, _ := czRouter(t, service.NewCZService(scanCZClient{}, scanCZMarks{}))
	if rec := czCall(router, "", http.MethodPost, "/api/v1/cz/scan", scanBody(scanMark)); rec.Code != http.StatusUnauthorized {
		t.Fatalf("без токена: %d", rec.Code)
	}
}

func TestCZScan_errors(t *testing.T) {
	cases := []struct {
		name string
		svc  *service.CZService
		body string
		code int
		msg  string
	}{
		{"bad json", service.NewCZService(scanCZClient{}, scanCZMarks{}), `code`, 400, "ожидается"},
		{"обычный ШК", service.NewCZService(scanCZClient{}, scanCZMarks{}), scanBody("4612728200172"), 400, "не марка"},
		{"не настроено", service.NewCZService(nil, nil), scanBody(scanMark), 503, "не настроен"},
		{"марки нет в ЧЗ", service.NewCZService(scanCZClient{}, scanCZMarks{}), scanBody("0104612728200172215unknown"), 404, "не найден"},
		{"нет договора", service.NewCZService(czClientStub{infoErr: fmt.Errorf("%w: water", model.ErrCZNoContract)}, nil), scanBody(scanMark), 422, "договора"},
		{"ЧЗ недоступен", service.NewCZService(czClientStub{infoErr: model.ErrCZUnavailable}, nil), scanBody(scanMark), 502, "True API"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, _, worker := czRouter(t, tc.svc)
			rec := czCall(router, worker, http.MethodPost, "/api/v1/cz/scan", tc.body)
			if rec.Code != tc.code || !strings.Contains(rec.Body.String(), tc.msg) {
				t.Fatalf("got %d %s, want %d with %q", rec.Code, rec.Body, tc.code, tc.msg)
			}
		})
	}
}

// CZ-05: признак «маркируемый» правит только admin.
func TestCZSetGoodMarked(t *testing.T) {
	router, admin, worker := czRouter(t, service.NewCZService(nil, scanCZMarks{}))
	path := "/api/v1/goods/" + scanGood + "/cz-marked"
	cases := []struct {
		name, token, path, body string
		code                    int
	}{
		{"admin ставит", admin, path, `{"cz_marked":true}`, 200},
		{"кладовщику нельзя", worker, path, `{"cz_marked":true}`, 403},
		{"нет товара", admin, "/api/v1/goods/00000000-0000-4000-8000-000000000999/cz-marked", `{"cz_marked":false}`, 404},
		{"нет значения", admin, path, `{}`, 400},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := czCall(router, tc.token, http.MethodPatch, tc.path, tc.body)
			if rec.Code != tc.code {
				t.Fatalf("got %d %s, want %d", rec.Code, rec.Body, tc.code)
			}
		})
	}
}

// Расхождение уходит клиенту полем discrepancy; без расхождения поля нет (эталоны выше).
func TestCZScan_discrepancy(t *testing.T) {
	svc := service.NewCZService(scanCZClient{}, scanCZMarks{}).WithOwnerINN("7700000000")
	router, _, worker := czRouter(t, svc)
	rec := czCall(router, worker, http.MethodPost, "/api/v1/cz/scan", scanBody(scanMark))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"discrepancy":"foreign_mark"`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body)
	}
}
