// Package migrations - SQL-миграции схемы БД, встроенные в бинарь через embed.
//
// Зачем embed: миграции едут вместе с бинарём - их можно применять на любом окружении
// без отдельной раскладки .sql-файлов рядом.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
