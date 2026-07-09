# Craft WMS

Система управления складом (WMS) для терминала сбора данных (ТСД). Пилот на одном складе.

**Стек:** Flutter (Android 11+, Urovo DT50) · Go · PostgreSQL · Docker · nginx · SMTP · Excel (XLSX).
Ключевые свойства: **offline-first** на устройстве, идемпотентность операций по `operation_id`,
авторизация по бейджу сотрудника, роли `employee`/`admin`. Обмен с 1С — без прямой интеграции: по завершении
операции бэкенд формирует Excel-отчёт и отправляет на e-mail, загрузку в 1С делает человек.

## Структура репозитория

```
apps/craft_wms/     # Flutter-приложение для ТСД
apps/backend/       # Go-сервис (cmd/server, internal/*, migrations)
infra/              # docker-compose, nginx
docs/               # документация
```

Подробнее — [docs/architecture.md](docs/architecture.md).

## Локальный запуск

Требуется Docker (локально — через Colima). Первый запуск:

```bash
colima start                        # поднять docker-демон (macOS)
cp .env.example .env                # настройки окружения
make up                             # собрать и поднять стек: postgres + backend + nginx
make migrate-up                     # накатить миграции схемы БД
make ps                             # статус контейнеров (ждём healthy)
curl http://localhost:8080/health   # liveness: {"status":"ok"}
curl http://localhost:8080/ready    # readiness (БД доступна): {"status":"ready"}
make down                           # остановить
```

Детали и проверка критериев по задачам — в [docs/](docs/) (`p0-01.md`, `p0-02.md`, `p0-03.md`).

## Документация

| Файл | Содержание |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Архитектура: структура, слои, обмен, соответствие фазам |
| [docs/p0-01.md](docs/p0-01.md) | Инфраструктура P0-01: запуск, остановка, проверка критериев |
| [docs/plan_v3.docx](docs/plan_v3.docx) | План разработки v3 (исходный документ) |

## Разработка

Ведётся по фазам плана (P0…P7), см. [docs/plan_v3.docx](docs/plan_v3.docx). Стандарты кода:
чистая архитектура, SOLID, обязательные комментарии «что / зачем / как». Git-workflow:
ветка на задачу `p0-XX` → PR в `dev`, периодически `dev` → `main`.
