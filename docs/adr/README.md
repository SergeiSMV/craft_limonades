# Architecture Decision Records (ADR)

Короткие записи «почему выбрали X» — чтобы архитектурные решения и их причины не терялись.
Формат — облегчённый [Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):
**Контекст → Решение → Последствия**, плюс статус.

Статусы: **Принято** (действует), **Планируется** (решение принято, реализация в будущей фазе),
**Заменено** (перекрыто более новым ADR).

## Реестр

| № | Решение | Статус |
|---|---|---|
| [0001](0001-monorepo.md) | Монорепозиторий (`apps/` + `infra/`) | Принято |
| [0002](0002-go-chi.md) | Бэкенд на Go + chi (vs echo/gin) | Принято |
| [0003](0003-postgres-pgx-migrate.md) | PostgreSQL + pgx v5 + golang-migrate (embedded SQL) | Принято |
| [0004](0004-obmen-1c-excel-email.md) | Обмен с 1С через Excel+SMTP вместо прямой интеграции | Принято |
| [0005](0005-auth-badge-argon2-roles.md) | Авторизация по бейджу (16→8/8) + argon2id + роли | Принято |
| [0006](0006-jwt-two-token-secure-storage.md) | Двухтокенный JWT (access/refresh) + secure storage | Принято |
| [0007](0007-offline-first-outbox.md) | Offline-first + Outbox + идемпотентность по `operation_id` | Планируется (P2) |
| [0008](0008-flutter-clean-arch-stack.md) | Flutter: чистая архитектура и стек | Принято |
| [0009](0009-ci-github-actions-ghcr.md) | CI на GitHub Actions + образы в GHCR | Принято |
| [0010](0010-dual-login-by-device.md) | Двойной вход по типу устройства (бейдж vs логин/пароль) | Планируется (P1/P2) |

Новый ADR — следующий свободный номер, добавить строку в реестр.
