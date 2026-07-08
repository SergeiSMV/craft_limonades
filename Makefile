# Обёртки над docker compose для локального стека.
# Compose-файл лежит в infra/, а .env — в корне проекта, поэтому оба пути
# передаём явными флагами. Так `make up` работает из корня без лишних cd.

COMPOSE = docker compose --env-file .env -f infra/docker-compose.yml

.PHONY: up down logs ps build restart

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
