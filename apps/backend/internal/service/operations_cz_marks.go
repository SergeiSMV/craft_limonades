package service

import (
	"fmt"
	"strings"

	"craftwms/internal/model"
)

// lineMarks проверяет КИ марок строки движения товара (CZ-06): форма КИ (часть до GS) и без
// повторов в строке. Одна марка в двух строках документа законна - её можно перенести
// A → B → C, как короб; проверяет это сервер по месту марки на каждом шаге.
func lineMarks(in []string) ([]string, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(in))
	seen := make(map[string]bool, len(in))
	for _, raw := range in {
		cis := strings.TrimSpace(raw)
		if !czCISCode.MatchString(cis) || strings.Contains(cis, gs) {
			return nil, fmt.Errorf("%w: %q", model.ErrCZBadCode, raw)
		}
		if seen[cis] {
			return nil, model.ErrInvalidPayload
		}
		seen[cis] = true
		out = append(out, cis)
	}
	return out, nil
}
