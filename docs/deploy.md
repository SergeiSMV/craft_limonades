# Развёртывание Craft WMS

Как поднять и остановить бэкенд-стек (PostgreSQL + Go-сервис + nginx) и как собрать/установить
приложение на ТСД. Архитектура — в [architecture.md](architecture.md), обоснования — в [adr/](adr/).

> Статус: описан **dev/пилотный** контур (одна машина, docker-compose). Прод-специфика
> (`docker-compose.prod.yml`, TLS, бэкапы, CD) — фаза **P7**.

---

## 1. Что разворачиваем

| Контейнер   | Роль                              | Наружу                                                |
|-------------|-----------------------------------|-------------------------------------------------------|
| `nginx`     | reverse proxy, единая точка входа | да — `http://<host>:${HTTP_PORT}` (по умолчанию 8080) |
| `backend`   | Go-сервис (chi, REST, JWT)        | нет (только через nginx)                              |
| `postgres`  | БД (PostgreSQL)                   | порт `${POSTGRES_PORT}` на хост (для psql/GUI)        |

Пробы состояния: `GET /health` (liveness — процесс жив), `GET /ready` (readiness — БД доступна).

---

## 2. Требования

- **Docker** с плагином `docker compose`. На macOS — через **Colima** (`colima start` перед работой).
- **Go 1.25** на хосте — нужен только для запуска миграций и сида (`make migrate-up`, `make seed`);
  сам сервис собирается в контейнере.
- **Flutter 3.41.x** — для сборки приложения ТСД.

---

## 3. Конфигурация (`.env`)

Секреты и параметры — в `.env` в корне проекта (в git не коммитится). Создать из шаблона:

```bash
cp .env.example .env
```

Обязательно заменить перед не-локальным развёртыванием:

| Переменная                                            | Назначение                                                            |
|-------------------------------------------------------|-----------------------------------------------------------------------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | учётка и имя БД                                                       |
| `POSTGRES_PORT`                                       | порт БД на хост (psql/GUI)                                            |
| `HTTP_PORT`                                           | внешний порт стека (nginx)                                            |
| `LOG_LEVEL`                                           | `debug` / `info` / `warn` / `error`                                   |
| `JWT_SECRET`                                          | **секрет подписи JWT — обязательно длинная случайная строка в проде** |
| `ACCESS_TTL` / `REFRESH_TTL`                          | время жизни токенов (дефолт `12h` / `720h` = 30 дней)                 |
| `ADMIN_BADGE`                                         | бейдж стартового админа: 16 цифр = логин(8)+секрет(8) — **сменить**   |
| `ADMIN_FULL_NAME`                                     | ФИО стартового админа (в отчётах)                                     |

---

## 4. Полный цикл развёртывания (dev/пилот)

Все команды — из корня проекта (обёртки `make` над `docker compose`, compose-файл в `infra/`).

```bash
# 1. Поднять docker-демон (macOS/Colima)
colima start

# 2. Поднять стек (postgres + backend + nginx), с пересборкой образов
make up

# 3. Накатить схему БД (миграции golang-migrate)
make migrate-up

# 4. Засеять стартового админа из .env (ADMIN_BADGE)
make seed

# 5. Проверить статус контейнеров и healthcheck
make ps
```

Проверка работоспособности:

```bash
curl -i http://localhost:8080/health     # 200 — процесс жив
curl -i http://localhost:8080/ready      # 200 — БД доступна (иначе 503)
```

Вспомогательное: `make logs` (логи всех сервисов, follow), `make build` (пересобрать образы),
`make restart` (down + up).

### Остановка (возврат к исходному состоянию)

```bash
make down          # остановить стек и удалить контейнеры (данные БД остаются в volume)
colima stop        # остановить docker-демон
```

Откатить схему БД (при необходимости): `make migrate-down` (откатывает все миграции).

---

## 5. Клиенты (Flutter): ТСД-приложение и веб-портал

**Адрес бэкенда — в файле `apps/craft_wms/.env`** (в `.gitignore`, свой на каждой машине;
шаблон — `apps/craft_wms/.env.example`). Сборки читают его флагом `--dart-define-from-file=.env`.
Формат — JSON, ключ `BASE_URL` **с завершающим `/`**, API под префиксом `/api/v1`
([ADR-0015](adr/0015-url-scheme-api-v1-portal-root.md)):

```json
{ "BASE_URL": "https://craft.skogi.ru/api/v1/" }
```

Первый раз: `cp .env.example .env` и вписать нужный адрес. Для локального стека (`make up`) —
`http://<LAN-IP-хоста>:8080/api/v1/` (устройство и хост в одной сети); для прода — как выше.
Один `.env` используется и ТСД-приложением, и порталом.

Ниже — установка ТСД-приложения на подключённый по USB Urovo DT50; веб-портал — в конце раздела.

**Шаг 1. Сгенерировать код.** Файлы `*.freezed.dart`, `*.g.dart`, `*.gr.dart`, `*.config.dart`,
`strings*.g.dart` — в `.gitignore`, в репозитории их нет. Без них сборка падает с
`No such file or directory: *.freezed.dart`.

```bash
cd apps/craft_wms
flutter pub get
dart run build_runner build
```

Если `build_runner` упал с `InvalidOutputException: … Asset already exists` (на диске остались старые
генерённые файлы — флага `--delete-conflicting-outputs`, который их сносил, в новых версиях нет),
удалить конфликтующие и повторить `dart run build_runner build`:

```bash
rm -f lib/_slang_temp.json lib/core/gen/strings.g.dart lib/core/gen/strings_ru.g.dart
```

Если конфликт не только на slang — снести всё генерённое разом (скобки в `find` обязательны, иначе
`-delete` из-за приоритета `-o` сработает лишь на последнем шаблоне) и снова `dart run build_runner build`:

```bash
dart run build_runner clean
find lib \( -name '*.g.dart' -o -name '*.freezed.dart' -o -name '*.gr.dart' -o -name '*.config.dart' \) -delete
```

Если после **ручного удаления** одного из генерённых файлов `build_runner build` пишет `wrote 0 outputs`
и **не** пересоздаёт его (сыплются `Undefined name 't'` / `Target of URI hasn't been generated`) — это
рассинхрон инкрементального кэша с диском (кэш считает вывод актуальным). Сбросить кэш и пересобрать:

```bash
dart run build_runner clean
dart run build_runner build
```

**Шаг 2. Проверить, что ТСД виден по USB.**

```bash
alias adb=~/Library/Android/sdk/platform-tools/adb
adb devices          # ТСД в списке со статусом device (не unauthorized / offline)
```

**Шаг 3. Установить и запустить на ТСД.**

```bash
flutter run --dart-define-from-file=.env -t lib/main.dart
```

**Автономный APK** (поставить на ТСД без Mac/отладчика рядом):

```bash
flutter build apk --dart-define-from-file=.env --release -t lib/main.dart
adb install -r build/app/outputs/flutter-apk/app-release.apk   # -r: переустановка поверх, данные целы
```

> Заметка по Urovo DT50: аппаратный сканер должен быть в режиме вывода **«клавиатура»
> (intent→keyboard)**, иначе скан не попадает в поле ввода (см. `docs/p0-07.md`). Нативная
> broadcast-интеграция сканера — P2-01.

Тест-логин (сид по умолчанию): бейдж `1000000012345678` → логин `10000000`, роль `admin`.

### Веб-портал (Flutter Web)

Тот же `.env`, но точка входа — `lib/main_portal.dart`. Локально (`flutter run`) вход упрётся в CORS —
портал работает на одном origin с API только после публикации (портал на корне `craft.skogi.ru/`,
API на `/api/v1`).

```bash
# запуск в браузере для отладки UI:
flutter run -d chrome --dart-define-from-file=.env -t lib/main_portal.dart

# сборка прод-бандла (статика в build/web):
flutter build web --dart-define-from-file=.env --release -t lib/main_portal.dart
```

---

## 6. Docker-образ бэкенда (CI)

CI (GitHub Actions) на **push в `dev`/`main`** собирает образ `apps/backend/Dockerfile` и публикует в
**GHCR**: `ghcr.io/<owner>/craft-wms-backend` с тегами `:<ветка>` и `:<sha>` (см.
[p0-08.md](p0-08.md), [ADR-0009](adr/0009-ci-github-actions-ghcr.md)). Для прод-развёртывания
берётся образ, прошедший проверки, а не собранный вручную.

---

## 7. Развёртывание на сервере

После установки приложение доступно по **HTTPS** и **само обновляется** при выходе новых версий.
Ставится «в одну команду». Обоснование топологии — [ADR-0011](adr/0011-pilot-deploy-host-nginx-ghcr.md).

### Что нужно от сервера (один раз)

- Linux (Debian/Ubuntu) с доступом `sudo`.
- **Домен**, A-запись которого указывает на внешний IP сервера.
- На роутере — **проброс портов 80 и 443** на сервер (нужно для HTTPS и выпуска сертификата).
- Прямой выход сервера в интернет.

Docker / nginx / certbot заранее ставить **не нужно** — `install.sh` сам доустановит, чего не хватает.

### Установка — 3 шага

**1. Создать рабочую папку и файл настроек `.env.prod`:**
```bash
sudo mkdir -p /opt/craft-wms && cd /opt/craft-wms
sudo nano .env.prod        # вставить содержимое infra/.env.prod.example и заполнить (см. ниже)
```

**2. Скачать код** (репозиторий приватный — GitHub попросит логин и токен PAT со scope `repo`):
```bash
sudo git clone https://github.com/SergeiSMV/craft_limonades.git app
```

**3. Запустить установку — она делает всё остальное** (ПО → nginx+TLS → запуск → миграции → админ → авто-обновление):
```bash
sudo bash app/deploy/install.sh
```

Готово. Проверка: открыть в браузере **`https://<ваш-домен>/health`** — должно вернуть `200`.

### Что заполнить в `.env.prod`

Замените все значения с `CHANGE_ME`. Минимум:
- `DEPLOY_DOMAIN` — ваш домен;
- `CERTBOT_EMAIL` — ваш e-mail (для уведомлений Let's Encrypt);
- `POSTGRES_PASSWORD`, `JWT_SECRET` — секреты;
- `ADMIN_PASSWORD` — пароль администратора.

> ⚠️ Комментарии в `.env.prod` — **только на отдельной строке**, не рядом со значением.

Сгенерировать секреты одной строкой:
```bash
echo "JWT_SECRET=$(openssl rand -base64 48)"
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -dc A-Za-z0-9 | head -c 32)"
```

### Доступ к образу: сделать GHCR-пакет публичным (рекомендуется)

Проще всего один раз сделать docker-образ публичным — тогда серверу **не нужен токен**:
GitHub → аватар → **Packages** → `craft-wms-backend` → **Package settings** → **Change visibility** → **Public**.

Если образ остаётся приватным — заполните `GHCR_USER` и `GHCR_TOKEN` (PAT со scope `read:packages`) в `.env.prod`.

### Обновления — автоматически

При `AUTO_UPDATE=true` сервер сам проверяет новый образ каждые `UPDATE_INTERVAL` (по умолчанию 5 минут)
и обновляется вместе с миграциями. Путь релиза на прод: смержили **`dev → main`** → CI собрал образ
`:main` → сервер подтянул. Делать ничего не нужно.

```bash
systemctl list-timers craft-wms-update      # когда следующая проверка
journalctl -u craft-wms-update -n 30        # что делало авто-обновление
sudo bash /opt/craft-wms/app/deploy/update.sh   # обновить прямо сейчас, вручную
```

### Бэкапы БД

```bash
bash /opt/craft-wms/app/deploy/pg-backup.sh     # разовый дамп в /opt/craft-wms/backups (gzip, ротация 14 дней)
```
Ежедневно по расписанию — в `crontab` (пользователь с доступом к docker):
```
30 3 * * * /bin/bash /opt/craft-wms/app/deploy/pg-backup.sh >> /var/log/craft-wms-backup.log 2>&1
```

### Файрвол (по желанию)

`install.sh` файрвол **не трогает** (сервер может обслуживать и другие сайты). Если нужен:
```bash
sudo ufw allow 22,80,443/tcp && sudo ufw enable
```

### Если что-то не так

- **`/health` не отвечает** — логи backend:
  `docker compose --env-file /opt/craft-wms/.env.prod -f /opt/craft-wms/app/infra/docker-compose.prod.yml logs backend`
- **Сертификат не выпустился** — проверьте, что домен резолвится и порт 80 проброшен: `dig +short <домен>`.
- **Никогда на проде:** `migrate down` и `docker compose down -v` — сотрут данные. Схема двигается только вперёд.

### Разница dev / prod

Локальный dev-стек (разделы 1–5) поднимает и **контейнерный** nginx (`make up`). На проде reverse-proxy
и TLS делает **хостовый** nginx сервера, а `docker-compose.prod.yml` содержит только `postgres` + `backend`
(backend слушает loopback). Это осознанная разница — см. [ADR-0011](adr/0011-pilot-deploy-host-nginx-ghcr.md).
