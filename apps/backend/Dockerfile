# --- Стадия сборки: компилируем статический бинарь из исходников Go ---
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Сначала копируем только манифесты зависимостей: слой кешируется отдельно от кода,
# пересборка зависимостей происходит только при их изменении.
# go.su[m] — glob: go.sum может отсутствовать, пока нет внешних зависимостей (P0-01).
COPY go.mod go.su[m] ./
RUN go mod download

# Затем исходники и сборка. CGO выключен → статический бинарь без внешних зависимостей,
# что позволяет запускать его в минимальном образе.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/server ./cmd/server

# --- Финальная стадия: минимальный образ только с бинарём ---
FROM alpine:3.20

# ca-certificates — для будущих исходящих TLS-запросов (SMTP и т.п.).
# wget для healthcheck уже есть в alpine (BusyBox), отдельно ставить не нужно.
RUN apk add --no-cache ca-certificates

# Запуск от непривилегированного пользователя — не держим root в контейнере.
RUN adduser -D -H app
USER app

COPY --from=builder /out/server /usr/local/bin/server

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/server"]
