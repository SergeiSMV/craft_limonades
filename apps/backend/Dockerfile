# --- Стадия сборки: компилируем статический бинарь из исходников Go ---
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Сначала копируем только манифесты зависимостей: слой кешируется отдельно от кода,
# пересборка зависимостей происходит только при их изменении.
# go.su[m] — glob: go.sum может отсутствовать, пока нет внешних зависимостей (P0-01).
COPY go.mod go.su[m] ./
RUN go mod download

# Затем исходники и сборка. CGO выключен → статические бинари без внешних зависимостей,
# что позволяет запускать их в минимальном образе.
# Собираем четыре бинаря: server (сервис), migrate и seed. Последние два нужны в проде,
# чтобы накатывать миграции и заводить админа БЕЗ Go/исходников на сервере
# (миграции .sql встроены в бинарь migrate через embed.go). cz-signer (CZ-02) в контейнере
# не запускается: update.sh достаёт его на хост, где стоят КриптоПро и ключ.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/server  ./cmd/server && \
    CGO_ENABLED=0 GOOS=linux go build -o /out/migrate ./cmd/migrate && \
    CGO_ENABLED=0 GOOS=linux go build -o /out/seed    ./cmd/seed && \
    CGO_ENABLED=0 GOOS=linux go build -o /out/cz-signer ./cmd/cz-signer

# --- Финальная стадия: минимальный образ только с бинарём ---
FROM alpine:3.20

# ca-certificates — для будущих исходящих TLS-запросов (SMTP и т.п.).
# wget для healthcheck уже есть в alpine (BusyBox), отдельно ставить не нужно.
RUN apk add --no-cache ca-certificates

# Запуск от непривилегированного пользователя — не держим root в контейнере.
RUN adduser -D -H app
USER app

COPY --from=builder /out/server  /usr/local/bin/server
COPY --from=builder /out/migrate /usr/local/bin/migrate
COPY --from=builder /out/seed    /usr/local/bin/seed
COPY --from=builder /out/cz-signer /usr/local/bin/cz-signer

EXPOSE 8080
# По умолчанию запускается сервис. migrate/seed выполняются разово через
# `docker compose run --rm --entrypoint /usr/local/bin/migrate backend up` (см. deploy/20-deploy.sh).
ENTRYPOINT ["/usr/local/bin/server"]
