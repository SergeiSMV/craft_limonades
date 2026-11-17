# Craft WMS

Система управления складом (WMS) для терминала сбора данных (ТСД). Пилот на одном складе.

**Стек:** Flutter (Android 11+, Urovo DT50) · Flutter Web (портал оператора) · Go (chi, pgx) · PostgreSQL · Docker · nginx · Excel (XLSX).
Ключевые свойства: **offline-first** на устройстве, идемпотентность операций по `operation_id`,
авторизация по бейджу сотрудника, роли `employee`/`admin`. Обмен с 1С - без прямой интеграции: по завершении
операции бэкенд формирует Excel-отчёт и выдаёт его в веб-портале, загрузку в 1С делает человек.

## Структура репозитория

```
apps/craft_wms/     # Flutter-приложение для ТСД
apps/backend/       # Go-сервис (cmd/server, cmd/migrate, cmd/seed, cmd/cz-signer, internal/*, migrations)
infra/              # docker-compose, nginx
docs/deploy/        # инструкции по развёртыванию
```

## Локальный запуск - бэкенд (полный цикл)

Требуется Docker (локально - через Colima).

```bash
colima start                        # docker-демон (macOS), если не запущен
cp .env.example .env                # окружение (первый раз)
make up                             # стек: postgres + backend + nginx
make migrate-up                     # миграции схемы БД
make seed                           # стартовый админ (ADMIN_BADGE) + склад и его дефолтная ячейка приёмки
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

## Документация

В репозитории - только инструкции по развёртыванию, **[docs/deploy/](docs/deploy/)**:
[dev-deploy.md](docs/deploy/dev-deploy.md) (локальный стек, `.env`, миграции, сборка APK
и портала), [prod-deploy.md](docs/deploy/prod-deploy.md) (боевой сервер: установка, TLS,
авто-обновление, бэкапы и восстановление), [tsd-setup.md](docs/deploy/tsd-setup.md) (ввод
нового ТСД: установка приложения, первый вход, принтер), [test-stand.md](docs/deploy/test-stand.md)
(тестовый стенд на снимке боевой базы) и [rustore.md](docs/deploy/rustore.md) (публикация в
RuStore). На сервере всё делается из одного меню - `sudo bash deploy/craft.sh`.

## Разработка

Ведётся по фазам плана (P0…P7). Стандарты кода: чистая архитектура, SOLID, обязательные комментарии
«что / зачем / как». Git-workflow: ветка на задачу `p0-XX` → PR в `dev`, периодически `dev` → `main`.
