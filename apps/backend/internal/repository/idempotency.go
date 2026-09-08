package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Applied — исход попытки применить операцию под ключом идемпотентности.
type Applied struct {
	// Result — ответ операции. У повтора это ответ ПЕРВОЙ попытки, а не заново посчитанный.
	Result json.RawMessage
	// Duplicate — операция с таким operation_id уже применялась; эффект во второй раз не выполнялся.
	Duplicate bool
}

// emptyJSON — значение по умолчанию для операций, которым нечего возвращать.
var emptyJSON = json.RawMessage(`{}`)

// once применяет эффект ровно один раз на operation_id — внутри УЖЕ ОТКРЫТОЙ транзакции q.
//
// Что: помечает операцию в journal `processed_operations` и, если пометка новая, выполняет effect.
// Зачем: очередь устройства повторяет операцию, пока не получит подтверждения (P2-03/P2-04), и
//
//	повтор после успешного, но не дошедшего ответа — штатный случай, а не сбой.
//
// ⚠ Часть эффектов переживает повтор и без журнала (привязка ШК — ON CONFLICT DO NOTHING, строка
// сессии — SET через ON CONFLICT DO UPDATE). Журнал нужен там, где этого нет: финал сессии на
// повторе отдаёт 409 «уже закрыта», и успешная операция приезжает на устройство отказом; будущие
// приёмка и перемещение работают приращением, и повтор их буквально удваивает. Здесь свойство
// даётся один раз для всех эффектов, а не доказывается заново для каждого нового.
//
// Как: `INSERT ... ON CONFLICT DO NOTHING RETURNING` — атомарная заявка на право выполнить эффект.
//
//	Ничего не вернулось → операция уже применена, отдаём сохранённый ответ.
//
// ⚠ Пометка и эффект обязаны быть в ОДНОЙ транзакции. Иначе между ними появляется момент, в
// котором эффект применён, а пометки нет (или наоборот), и падение ровно в нём возвращает нас
// к той самой задаче, которую журнал решает. Поэтому once принимает Querier, а не пул: транзакцией
// владеет вызывающий.
//
// ⚠ Параллельные попытки с одним operation_id сериализует сам Postgres: второй INSERT ждёт на
// уникальном индексе, пока первый не завершится, и после его коммита видит конфликт. Отдельная
// блокировка не нужна.
func once(ctx context.Context, q Querier, operationID, kind string, effect func() (json.RawMessage, error)) (Applied, error) {
	var claimed string
	err := q.QueryRow(ctx, `
		INSERT INTO processed_operations (operation_id, kind)
		VALUES ($1::uuid, $2)
		ON CONFLICT (operation_id) DO NOTHING
		RETURNING operation_id::text`, operationID, kind).Scan(&claimed)

	if errors.Is(err, pgx.ErrNoRows) {
		// Повтор: эффект не трогаем, отдаём ответ первой попытки.
		var stored []byte
		if err := q.QueryRow(ctx,
			`SELECT result FROM processed_operations WHERE operation_id = $1::uuid`,
			operationID).Scan(&stored); err != nil {
			return Applied{}, fmt.Errorf("read stored operation result: %w", err)
		}
		return Applied{Result: stored, Duplicate: true}, nil
	}
	if err != nil {
		return Applied{}, fmt.Errorf("claim operation %s: %w", operationID, err)
	}

	result, err := effect()
	if err != nil {
		// Откат транзакции снимет и пометку — операция останется неприменённой и повторится.
		return Applied{}, err
	}
	if len(result) == 0 {
		result = emptyJSON
	}
	if _, err := q.Exec(ctx,
		`UPDATE processed_operations SET result = $2 WHERE operation_id = $1::uuid`,
		operationID, []byte(result)); err != nil {
		return Applied{}, fmt.Errorf("store operation result: %w", err)
	}
	return Applied{Result: result}, nil
}
