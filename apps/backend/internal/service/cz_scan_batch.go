package service

import (
	"context"
	"fmt"

	"craftwms/internal/model"
)

// CZScanItem - ответ пачки по одному коду: скан или причина, почему код не прочитан.
// Requested - код, как его прислал ТСД: по нему клиент сопоставляет ответ со сканом.
type CZScanItem struct {
	Requested string
	Scan      model.CZScan
	Err       error
}

// ScanMany - скан пачки марок и кодов коробов одним запросом в ЧЗ (ADHOC-70).
//
// Зачем: на приёмке и вводе остатков марки сканируются подряд, по бутылке, а один запрос в
// True API идёт 0,5-1,3 с. Пачка читает все коды одним `cises/info` (до czMaxCodes), так что
// время скана на ТСД не складывается из запросов по каждой марке.
// Как: коды приводятся к ключу ЧЗ; отказ по одному коду (не марка, ЧЗ не знает код) - ответ
// этого кода, остальные читаются. Отказ всего чтения (ЧЗ недоступен, не настроен) - ошибка
// пачки. Ответ - по одному на присланный код, в том же порядке; повтор кода читается один раз.
func (s *CZService) ScanMany(ctx context.Context, raws []string) ([]CZScanItem, error) {
	if len(raws) == 0 {
		return nil, ErrCZNoCodes
	}
	if len(raws) > czMaxCodes {
		return nil, fmt.Errorf("%w: %d, не больше %d", ErrCZTooManyCodes, len(raws), czMaxCodes)
	}
	if s.client == nil {
		return nil, s.notConfigured()
	}

	items := make([]CZScanItem, len(raws))
	var codes []string
	seen := map[string]bool{}
	for i, raw := range raws {
		items[i].Requested = raw
		code, err := NormalizeCZCode(raw)
		if err != nil {
			items[i].Err = err
			continue
		}
		items[i].Scan.Code = code
		if !seen[code] {
			seen[code] = true
			codes = append(codes, code)
		}
	}
	if len(codes) == 0 {
		return items, nil
	}

	infos, err := s.client.CisesInfo(ctx, codes)
	if err != nil {
		return nil, err
	}
	byCode := make(map[string]model.CisInfo, len(infos))
	for _, it := range infos {
		byCode[it.RequestedCis] = it
	}

	goods := gtinGoods{}
	for i := range items {
		if items[i].Err != nil {
			continue
		}
		code := items[i].Scan.Code
		info, ok := byCode[code]
		switch {
		case !ok:
			items[i].Err = fmt.Errorf("%w: %s", model.ErrCZNotFound, code)
		case info.Cis == "":
			items[i].Err = fmt.Errorf("%w: %s %s", model.ErrCZNotFound, code, info.ErrorMessage)
		default:
			items[i].Scan, items[i].Err = s.scanInfo(ctx, code, info, goods)
		}
	}
	return items, nil
}
