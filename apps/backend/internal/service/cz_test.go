package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"craftwms/internal/model"
)

// Тесты CZ-02, шаг 3: сервис ЧЗ над подставным клиентом True API.

type fakeCZClient struct {
	signerErr error
	expiry    time.Time
	hasToken  bool
	gotCodes  []string
	infoErr   error
}

func (f *fakeCZClient) CisesInfo(_ context.Context, codes []string) ([]model.CisInfo, error) {
	f.gotCodes = codes
	if f.infoErr != nil {
		return nil, f.infoErr
	}
	out := make([]model.CisInfo, 0, len(codes))
	for _, c := range codes {
		out = append(out, model.CisInfo{RequestedCis: c})
	}
	return out, nil
}
func (f *fakeCZClient) TokenExpiry() (time.Time, bool)     { return f.expiry, f.hasToken }
func (f *fakeCZClient) SignerHealth(context.Context) error { return f.signerErr }

func TestCZServiceNotConfigured(t *testing.T) {
	s := NewCZService(nil)
	if st := s.Status(context.Background()); st.Configured || st.SignerOK || st.TokenValid {
		t.Fatalf("status = %+v", st)
	}
	if _, err := s.CisesInfo(context.Background(), []string{"x"}); !errors.Is(err, model.ErrCZNotConfigured) {
		t.Fatalf("err = %v", err)
	}
}

func TestCZServiceStatus(t *testing.T) {
	exp := time.Date(2026, 10, 23, 19, 0, 0, 0, time.UTC)
	ok := NewCZService(&fakeCZClient{expiry: exp, hasToken: true})
	st := ok.Status(context.Background())
	if !st.Configured || !st.SignerOK || st.SignerError != "" || !st.TokenValid || !st.TokenExpiresAt.Equal(exp) {
		t.Fatalf("status = %+v", st)
	}

	down := NewCZService(&fakeCZClient{signerErr: model.ErrCZSignerUnavailable})
	st = down.Status(context.Background())
	if !st.Configured || st.SignerOK || st.SignerError == "" || st.TokenValid || st.TokenExpiresAt != nil {
		t.Fatalf("status = %+v", st)
	}
}

func TestCZServiceCisesInfoNormalizesCodes(t *testing.T) {
	f := &fakeCZClient{}
	s := NewCZService(f)
	// Марка со сканера — с GS и криптохвостом; пустые строки и пробелы — мусор ввода.
	in := []string{" 0104600000000017215abc\x1d93dGVz ", "", "   ", "00146000000000000017"}
	got, err := s.CisesInfo(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	want := "0104600000000017215abc,00146000000000000017"
	if strings.Join(f.gotCodes, ",") != want || len(got) != 2 {
		t.Fatalf("sent %v, want %s", f.gotCodes, want)
	}
}

func TestCZServiceCisesInfoValidation(t *testing.T) {
	s := NewCZService(&fakeCZClient{})
	if _, err := s.CisesInfo(context.Background(), []string{" ", ""}); !errors.Is(err, ErrCZNoCodes) {
		t.Fatalf("err = %v", err)
	}
	many := make([]string, czMaxCodes+1)
	for i := range many {
		many[i] = "c"
	}
	if _, err := s.CisesInfo(context.Background(), many); !errors.Is(err, ErrCZTooManyCodes) {
		t.Fatalf("err = %v", err)
	}
}
