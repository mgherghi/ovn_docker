
SHELL := /bin/bash
ROOT  := $(shell pwd)
ENV_LINK := $(ROOT)/env/current.env

.PHONY: env build up down restart ps logs status check nbstatus sbstatus ovs clean-state

env:
	@./scripts/make-host-env.sh
	@echo "Using env file -> $(ENV_LINK)"
	@echo "NODE_NAME=$$(grep '^NODE_NAME=' $(ENV_LINK) | cut -d= -f2)"

build: env
	docker compose --env-file $(ENV_LINK) build

up: env
	docker compose --env-file $(ENV_LINK) up -d

down: env
	docker compose --env-file $(ENV_LINK) down

restart: env
	docker compose --env-file $(ENV_LINK) restart

ps:
	docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

logs: env
	docker compose --env-file $(ENV_LINK) logs -f ovn

status:
	@echo "Health:" ; docker inspect --format '{{.State.Health.Status}}' ovn 2>/dev/null || echo "no container"
	@echo "Compose ps:" ; docker compose --env-file $(ENV_LINK) ps

check:
	docker exec -it ovn /bin/bash -lc "/scripts/checks.sh || true"

nbstatus:
	docker exec -it ovn ovn-appctl -t nbdb/ovsdb-server cluster/status OVN_Northbound || true

sbstatus:
	docker exec -it ovn ovn-appctl -t sbdb/ovsdb-server cluster/status OVN_Southbound || true

ovs:
	docker exec -it ovn ovs-vsctl show

clean-state:
	@read -p "This will DELETE ./state/ovn and ./state/openvswitch. Type 'yes' to continue: " ans; \
	if [[ $$ans == "yes" ]]; then \
	  rm -rf ./state/ovn/* ./state/openvswitch/* ; \
	  echo "State wiped."; \
	else \
	  echo "Aborted."; \
	fi
