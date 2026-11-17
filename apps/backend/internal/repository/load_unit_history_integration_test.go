package repository_test

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"craftwms/internal/model"
	"craftwms/internal/repository"
)

// ADHOC-32: история короба видит не только переносы, но и состав - что вынули, что доложили,
// что ушло при пометке части короба и что списано. Фикстуры - movement/problem тестов.
func TestLoadUnitHistory_contentEvents(t *testing.T) {
	mf := setupMove(t)
	defect := mf.iwhByCode(t, "DEFECT")
	lu := newLU(t, mf.stockFixture, model.LoadUnitBox)
	mf.receive(t, []string{lu}, 5) // A: короб 12 + россыпь 5

	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(2, "", lu, mf.cellC, "")); err != nil {
		t.Fatalf("вынуть из короба: %v", err)
	}
	if _, err := mf.move(t, uuid.NewString(), mf.goodsLine(1, mf.cellA, "", "", lu)); err != nil {
		t.Fatalf("доложить в короб: %v", err)
	}
	mf.openProblem(t, defect, model.ProblemReasonSpoilage, mf.goodsProblem(1, "", lu))
	whole := mf.openProblem(t, defect, model.ProblemReasonBreakage, repository.ProblemSubmitInput{LoadUnitID: lu})
	mustNoErr(t, mf.resolve(whole, model.ResolveProblemInput{
		Decision: model.ProblemDecisionWriteOff, DocNumber: "СП-1", DocDate: "2026-10-21",
	}))

	h, err := repository.NewContentsRepository(mf.pool).LoadUnitHistory(context.Background(), lu)
	mustNoErr(t, err)
	var got []string
	for _, e := range h.Contents {
		peer := "-"
		if e.PeerAddress != nil {
			peer = *e.PeerAddress
		}
		got = append(got, e.Kind+":"+e.Qty.String()+":"+peer)
	}
	// 12 − 2 + 1 − 1 = 10 списано вместе с коробом; пометка брака целиком в историю не идёт.
	want := "out:2:C in:1:A problem:1:A write_off:10:-"
	if strings.Join(got, " ") != want {
		t.Errorf("состав в истории: %q, ожидалось %q", strings.Join(got, " "), want)
	}
}
