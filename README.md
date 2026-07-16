# Craft WMS

Система управления складом (WMS) для терминала сбора данных (ТСД). Пилот на одном складе.

**Стек:** Flutter (Android 11+, Urovo DT50) · Go (chi, pgx) · PostgreSQL · Docker · nginx · SMTP · Excel (XLSX).
Ключевые свойства: **offline-first** на устройстве, идемпотентность операций по `operation_id`,
авторизация по бейджу сотрудника, роли `employee`/`admin`. Обмен с 1С — без прямой интеграции: по завершении
операции бэкенд формирует Excel-отчёт и отправляет на e-mail, загрузку в 1С делает человек.

## Структура репозитория

```
apps/craft_wms/     # Flutter-приложение для ТСД
apps/backend/       # Go-сервис (cmd/server, cmd/migrate, cmd/seed, internal/*, migrations)
infra/              # docker-compose, nginx
docs/               # документация
```

Подробнее — [docs/architecture.md](docs/architecture.md).

## Локальный запуск — бэкенд (полный цикл)

Требуется Docker (локально — через Colima).

```bash
colima start                        # docker-демон (macOS), если не запущен
cp .env.example .env                # окружение (первый раз)
make up                             # стек: postgres + backend + nginx
make migrate-up                     # миграции схемы БД
make seed                           # стартовый админ из .env (ADMIN_BADGE)
make ps                             # статус контейнеров (ждём healthy)
curl http://localhost:8080/health   # liveness → {"status":"ok"}
curl http://localhost:8080/ready    # readiness (БД доступна) → {"status":"ready"}
# остановка / возврат к исходному:
make down                           # погасить стек (данные БД сохранятся в volume)
colima stop                         # остановить docker-демон
```

## Мобильное приложение (Flutter)

```bash
cd apps/craft_wms
flutter pub get
dart run build_runner build         # кодогенерация (freezed, auto_route, injectable, slang)
flutter build apk --debug           # сборка APK под Android 11+
flutter run                         # запуск на эмуляторе (бэкенд должен быть поднят)
```

Полный сценарий запуска на эмуляторе/устройстве с входом по скану бейджа, персистентностью сессии и остановкой — в [docs/p0-06.md](docs/p0-06.md).

## Документация

| Файл | Содержание |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Архитектура: структура, слои (backend/Flutter), обмен |
| [docs/p0-01.md](docs/p0-01.md) … [p0-06.md](docs/p0-06.md) | Задачи фазы P0: инфраструктура, Go-скелет, БД+миграции, auth, Flutter-скелет, вход по скану + secure storage |
| [docs/plan_v3.docx](docs/plan_v3.docx) | План разработки v3 |

## Разработка

Ведётся по фазам плана (P0…P7). Стандарты кода: чистая архитектура, SOLID, обязательные комментарии
«что / зачем / как». Git-workflow: ветка на задачу `p0-XX` → PR в `dev`, периодически `dev` → `main`.
