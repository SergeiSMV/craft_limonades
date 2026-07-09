# Обёртки над docker compose для локального стека.
# Compose-файл лежит в infra/, а .env — в корне проекта, поэтому оба пути
# передаём явными флагами. Так `make up` работает из корня без лишних cd.

COMPOSE = docker compose --env-file .env -f infra/docker-compose.yml

.PHONY: up down logs ps build restart migrate-up migrate-down

# Раннер миграций с хоста: БД опубликована на localhost:$${POSTGRES_PORT}.
# POSTGRES_* берём из .env (читаем прямо в команде), собираем из них DATABASE_URL.
MIGRATE = cd apps/backend && set -a && . ../../.env && set +a && \
	DATABASE_URL="postgres://$$POSTGRES_USER:$$POSTGRES_PASSWORD@localhost:$$POSTGRES_PORT/$$POSTGRES_DB?sslmode=disable" \
	go run ./cmd/migrate

up: ## Поднять весь стек (postgres + backend + nginx) в фоне, с пересборкой
	$(COMPOSE) up -d --build

down: ## Остановить стек и удалить контейнеры
	$(COMPOSE) down

logs: ## Логи всех сервисов (follow)
	$(COMPOSE) logs -f

ps: ## Статус контейнеров и их healthcheck
	$(COMPOSE) ps

build: ## Пересобрать образы
	$(COMPOSE) build

restart: down up   ## Перезапустить стек

migrate-up: ## Накатить миграции схемы БД (up)
	$(MIGRATE) up

migrate-down: ## Откатить все миграции схемы БД (down)
	$(MIGRATE) down
