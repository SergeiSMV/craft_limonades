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

## 5. Приложение на ТСД (Flutter)

Адрес бэкенда передаётся при сборке/запуске через `--dart-define=BASE_URL=...`:

- **эмулятор Android:** дефолт `http://10.0.2.2:8080` (localhost хоста из эмулятора);
- **реальный ТСД/смартфон:** LAN-IP хоста, где поднят стек — `http://<IP>:8080`
  (устройство и хост в одной сети).

```bash
cd apps/craft_wms
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # генерённые файлы в .gitignore
flutter build apk --release --dart-define=BASE_URL=http://<IP>:8080
# APK: build/app/outputs/flutter-apk/app-release.apk → установить на ТСД (adb install ...)
```

> Заметка по Urovo DT50: аппаратный сканер должен быть в режиме вывода **«клавиатура»
> (intent→keyboard)**, иначе скан не попадает в поле ввода (см. `docs/p0-07.md`). Нативная
> broadcast-интеграция сканера — P2-01.

Тест-логин (сид по умолчанию): бейдж `1000000012345678` → логин `10000000`, роль `admin`.

---

## 6. Docker-образ бэкенда (CI)

CI (GitHub Actions) на **push в `dev`/`main`** собирает образ `apps/backend/Dockerfile` и публикует в
**GHCR**: `ghcr.io/<owner>/craft-wms-backend` с тегами `:<ветка>` и `:<sha>` (см.
[p0-08.md](p0-08.md), [ADR-0009](adr/0009-ci-github-actions-ghcr.md)). Для прод-развёртывания
берётся образ, прошедший проверки, а не собранный вручную.

---

## 7. Прод / пилотный деплой (P1-D)

Ранний пилотный деплой на сервер со статическим доступом. Топология и обоснования —
[ADR-0011](adr/0011-pilot-deploy-host-nginx-ghcr.md).

### 7.1. Топология

```
интернет → :443 ХОСТОВЫЙ nginx (TLS через certbot/Let's Encrypt)
             └── vhost ${DEPLOY_DOMAIN} → proxy_pass http://127.0.0.1:8080
                                                       │
             docker-стек (infra/docker-compose.prod.yml):
               backend  → публикуется на ${BACKEND_BIND} (loopback, не наружу)
               postgres → только внутренняя сеть compose (порт наружу не публикуется)
```

В проде **нет контейнерного nginx** — reverse-proxy и TLS делает системный nginx сервера
(переиспользуем уже настроенный certbot). Backend берётся **готовым образом из GHCR**.

### 7.2. Всё среда-специфичное — в `infra/.env.prod`

Один и тот же код/скрипты работают на любом сервере (свой сейчас, сервер заказчика позже) —
меняется только `infra/.env.prod` (в `.gitignore`). Шаблон — `infra/.env.prod.example`.
Сгенерировать секрет JWT: `openssl rand -base64 48`.

### 7.3. Предпосылки на сервере/роутере

- DNS: A-запись `${DEPLOY_DOMAIN}` → внешний IP сервера (`dig +short ${DEPLOY_DOMAIN}`).
- Роутер: проброс портов **80 и 443** (и 22 для SSH) на LAN-IP сервера.
- **Прямой выход в интернет** с сервера (GHCR + Let's Encrypt). Если включён shell-прокси
  (`http_proxy`/`https_proxy`) и он недоступен — сбросьте его (`unset http_proxy https_proxy`)
  или почините; в скрипты прокси не зашит. Preflight-проверка встроена в `00-bootstrap`/`20-deploy`.
- Доступ к приватному образу GHCR: разово `docker login ghcr.io -u <github-user>` (пароль = PAT со
  scope `read:packages`).

### 7.4. Порядок первого деплоя

```bash
# на сервере, из корня репозитория (git clone приватного репо по SSH)
bash deploy/make-env.sh                 # создаёт infra/.env.prod: JWT/пароль БД — случайные, остальное — плейсхолдеры
$EDITOR infra/.env.prod                 # заполнить: DEPLOY_DOMAIN, CERTBOT_EMAIL, ADMIN_PASSWORD, тег BACKEND_IMAGE (:dev)

sudo bash deploy/00-bootstrap.sh        # проверка/установка docker, nginx, certbot, ufw + preflight
docker login ghcr.io -u <github-user>   # разово (PAT read:packages), для приватного образа

sudo bash deploy/10-nginx-vhost.sh      # vhost ${DEPLOY_DOMAIN} + выпуск TLS (certbot --nginx)
bash deploy/20-deploy.sh --seed         # pull → up → миграции → завести админа (--seed только 1-й раз)

# файрвол: открыть только нужное
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw enable

# проверка
curl -s https://${DEPLOY_DOMAIN}/health   # 200
curl -s https://${DEPLOY_DOMAIN}/ready    # 200 при живой БД
```

### 7.5. Обновление (каждый релиз)

```bash
git pull                       # свежие compose/скрипты (если менялись)
bash deploy/20-deploy.sh       # pull нового образа → up -d → миграции (без --seed)
```

Данные переживают обновление (том `db_data`). **Не запускать** на проде `migrate down` (откат всех
миграций) и `compose down -v` (снос тома). Схему двигаем только вперёд аддитивными миграциями.

### 7.6. Бэкапы

```bash
bash deploy/pg-backup.sh       # разовый дамп в ./backups (gzip)
# по расписанию (ежедневно 03:30) — в crontab пользователя с доступом к docker:
#   30 3 * * * /bin/bash /path/to/repo/deploy/pg-backup.sh >> /var/log/craft-wms-backup.log 2>&1
```

### 7.7. Осталось на P7

Ресурсный мониторинг, ротация логов контейнеров, автоматизированный CD (деплой прошедшего CI образа),
секрет-менеджер вместо файла `.env.prod`. Финализируется при выходе на полноценный прод.
