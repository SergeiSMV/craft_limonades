package service

import (
	"context"
	"encoding/json"
	"testing"
)

// P10-03: подсчёт ячейки разбирается до базы — идентификаторы, дата, количество, одна позиция
// и один короб — один раз, марка — одна на весь подсчёт; работник — из токена.
func TestOperations_stocktakeCellSubmit(t *testing.T) {
	const (
		user = "1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d"
		cell = "2c3d4e5f-6071-4b8c-9d0e-1f2a3b4c5d6e"
		good = "3d4e5f60-7182-4c9d-8e0f-2a3b4c5d6e7f"
		box  = "4e5f6071-8293-4dae-9f10-3b4c5d6e7f80"
	)
	ok := `{"stocktake_cell_id":"` + cell + `","loose":[{"good_id":"` + good + `","production_date":"01-02-2026","qty":2,
		"marks":["0104600000000017215L1","0104600000000017215L2"]}],"boxes":["` + box + `"]}`
	repo := newFakeOpsRepo()
	svc := NewOperationsService(repo)
	res, err := svc.Apply(context.Background(), user, []Operation{{
		OperationID: "8f4c2b1e-0d3a-4c5b-9e6f-1a2b3c4d5e6f", Kind: "stocktake_cell_submit", Payload: json.RawMessage(ok),
	}})
	if err != nil || res[0].Status != StatusAccepted {
		t.Fatalf("корректный подсчёт: %+v, %v", res, err)
	}
	got := repo.counts[0]
	if got.UserID != user || got.Loose[0].ProductionDate != "2026-02-01" || len(got.Loose[0].Marks) != 2 ||
		got.Boxes[0] != box {
		t.Errorf("разобрано не так: %+v", got)
	}

	for name, body := range map[string]string{
		"ячейка не UUID":   `{"stocktake_cell_id":"x"}`,
		"дата не по форме": `{"stocktake_cell_id":"` + cell + `","loose":[{"good_id":"` + good + `","production_date":"2026-02-01","qty":1}]}`,
		"минус":            `{"stocktake_cell_id":"` + cell + `","loose":[{"good_id":"` + good + `","production_date":"01-02-2026","qty":-1}]}`,
		"позиция дважды": `{"stocktake_cell_id":"` + cell + `","loose":[{"good_id":"` + good + `","production_date":"01-02-2026","qty":1},
			{"good_id":"` + good + `","production_date":"01-02-2026","qty":2}]}`,
		"короб дважды": `{"stocktake_cell_id":"` + cell + `","boxes":["` + box + `","` + box + `"]}`,
		"марка дважды": `{"stocktake_cell_id":"` + cell + `","loose":[{"good_id":"` + good + `","production_date":"01-02-2026","qty":2,
			"marks":["0104600000000017215L1","0104600000000017215L1"]}]}`,
	} {
		res, err := svc.Apply(context.Background(), user, []Operation{{
			OperationID: "9a4c2b1e-0d3a-4c5b-9e6f-1a2b3c4d5e6f", Kind: "stocktake_cell_submit", Payload: json.RawMessage(body),
		}})
		if err != nil || res[0].Status != StatusRejected {
			t.Errorf("%s: ожидался отказ, получено %+v, %v", name, res, err)
		}
	}
}
