package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"craftwms/internal/model"
	"craftwms/internal/service"
)

// czMaxBody — предел тела info: сотня кодов марок с запасом.
const czMaxBody = 64 << 10

// czReader — что обработчику нужно от сервиса Честного знака.
type czReader interface {
	Status(ctx context.Context) model.CZStatus
	CisesInfo(ctx context.Context, codes []string) ([]model.CisInfo, error)
	Scan(ctx context.Context, code string) (model.CZScan, error)
	SetGoodCZMarked(ctx context.Context, goodID string, marked bool) error
}

// CZHandler — Честный знак: проверка подписанта и чтение марок администратором (CZ-02),
// скан марки или короба кладовщиком на ТСД (CZ-04).
type CZHandler struct {
	svc czReader
}

// NewCZHandler создаёт обработчик ЧЗ.
func NewCZHandler(svc czReader) *CZHandler {
	return &CZHandler{svc: svc}
}

type czStatusResponse struct {
	Configured     bool       `json:"configured"`
	SignerOK       bool       `json:"signer_ok"`
	SignerError    string     `json:"signer_error,omitempty"`
	TokenValid     bool       `json:"token_valid"`
	TokenExpiresAt *time.Time `json:"token_expires_at,omitempty"`
}

// Status: GET /api/v1/admin/cz/status — подписант подписывает, токен есть, когда истекает.
// Всегда 200: «не настроено» и «подписант лежит» — ответ, а не сбой запроса.
func (h *CZHandler) Status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, czStatusResponse(h.svc.Status(r.Context())))
}

type czInfoResponse struct {
	RequestedCis   string          `json:"requested_cis"`
	Cis            string          `json:"cis"`
	Gtin           string          `json:"gtin,omitempty"`
	ProductName    string          `json:"product_name,omitempty"`
	ProductGroup   string          `json:"product_group,omitempty"`
	PackageType    string          `json:"package_type,omitempty"`
	PackageLevel   string          `json:"package_level,omitempty"`
	Status         string          `json:"status,omitempty"`
	OwnerInn       string          `json:"owner_inn,omitempty"`
	OwnerName      string          `json:"owner_name,omitempty"`
	ProducedDate   string          `json:"produced_date,omitempty"`
	ExpirationDate string          `json:"expiration_date,omitempty"`
	Parent         string          `json:"parent,omitempty"`
	Child          []string        `json:"child,omitempty"`
	ErrorMessage   string          `json:"error_message,omitempty"`
	Raw            json.RawMessage `json:"raw,omitempty"`
}

// Info: POST /api/v1/admin/cz/info {codes: [...]} — данные марок и упаковок из True API.
//
// Коды — как со сканера: криптохвост сервис отрежет сам. Ответ по коду включает `raw` —
// ответ ЧЗ целиком, чтобы видеть и поля, которых WMS ещё не знает.
func (h *CZHandler) Info(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Codes []string `json:"codes"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, czMaxBody)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "ожидается {\"codes\": [...]}")
		return
	}
	items, err := h.svc.CisesInfo(r.Context(), req.Codes)
	if err != nil {
		code, msg := czErrorResponse(err)
		if code >= http.StatusInternalServerError {
			slog.ErrorContext(r.Context(), "chestny znak info failed", "error", err)
		}
		writeError(w, code, msg)
		return
	}
	out := make([]czInfoResponse, 0, len(items))
	for _, it := range items {
		out = append(out, czInfoResponse(it))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

// czErrorResponse — код и текст ответа по ошибке чтения ЧЗ.
//
// Текст ЧЗ (причина отказа во входе, «нет договора») добавляется к сообщению: администратору
// по нему чинить, а секретов в нём нет — токен в текст ошибок клиента не попадает.
// Сбой на нашей стороне или в ЧЗ — 5xx (и в Bugsink), отказ по самим кодам — 4xx.
func czErrorResponse(err error) (int, string) {
	switch {
	case errors.Is(err, model.ErrCZBadCode):
		return http.StatusBadRequest, "это не марка Честного знака и не код короба"
	case errors.Is(err, service.ErrCZNoCodes):
		return http.StatusBadRequest, "не передано ни одного кода"
	case errors.Is(err, service.ErrCZTooManyCodes):
		return http.StatusBadRequest, "слишком много кодов за раз: " + err.Error()
	case errors.Is(err, model.ErrCZGoodNotFound):
		return http.StatusNotFound, "товар не найден"
	case errors.Is(err, model.ErrCZNotConfigured):
		return http.StatusServiceUnavailable, "Честный знак на этом сервере не настроен"
	case errors.Is(err, model.ErrCZSignerUnavailable):
		return http.StatusServiceUnavailable, "подписант Честного знака недоступен"
	case errors.Is(err, model.ErrCZAuthFailed):
		return http.StatusBadGateway, "Честный знак отказал во входе: " + err.Error()
	case errors.Is(err, model.ErrCZUnavailable):
		return http.StatusBadGateway, "True API недоступен"
	case errors.Is(err, model.ErrCZNoContract):
		return http.StatusUnprocessableEntity, "нет договора с ЧЗ по товарной группе: " + err.Error()
	case errors.Is(err, model.ErrCZNotFound):
		return http.StatusNotFound, "код не найден в Честном знаке"
	default:
		return http.StatusInternalServerError, "внутренняя ошибка"
	}
}
