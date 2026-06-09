# YellowPad — local dev & deploy helpers (k3d + Kustomize)
#
# Usage:
#   make all       # one-shot: cluster -> build -> load -> deploy -> wait -> verify
#   make cluster   # create the k3d cluster
#   make build     # build all three images
#   make load      # import images into k3d
#   make deploy    # apply manifests
#   make wait      # block until all rollouts are ready
#   make verify    # run health + upload + process checks
#   make logs      # tail api-gateway logs
#   make clean     # tear down namespace
#   make destroy   # delete the k3d cluster

CLUSTER ?= yellowpad
NAMESPACE ?= yellowpad
REGISTRY ?= yellowpad
TAG ?= dev

IMAGES := api-gateway document-processor web-ui

.PHONY: cluster build load deploy wait verify logs clean destroy all

all: cluster build load deploy wait verify

cluster:
	@k3d cluster list | grep -q "^$(CLUSTER) " || \
	  k3d cluster create $(CLUSTER) \
	    --servers 1 --agents 2 \
	    --port "8080:80@loadbalancer" \
	    --port "8443:443@loadbalancer"
	kubectl cluster-info

build:
	@for img in $(IMAGES); do \
	  echo ">> docker build $$img"; \
	  docker build -t $(REGISTRY)/$$img:$(TAG) src/$$img || exit 1; \
	done

load:
	@for img in $(IMAGES); do \
	  echo ">> k3d image import $$img"; \
	  k3d image import $(REGISTRY)/$$img:$(TAG) -c $(CLUSTER) || exit 1; \
	done

deploy:
	kubectl apply -k k8s

wait:
	kubectl -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	kubectl -n $(NAMESPACE) rollout status statefulset/minio    --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deploy/redis              --timeout=120s
	kubectl -n $(NAMESPACE) rollout status deploy/api-gateway        --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deploy/document-processor --timeout=180s
	kubectl -n $(NAMESPACE) rollout status deploy/web-ui             --timeout=120s

verify:
	@echo ">> pods"
	kubectl -n $(NAMESPACE) get pods
	@echo ">> api /healthz via port-forward"
	@kubectl -n $(NAMESPACE) port-forward svc/api-gateway 18000:8000 >/tmp/pf-api.log 2>&1 & echo $$! > /tmp/pf-api.pid; \
	  sleep 3; \
	  curl -fsS http://localhost:18000/healthz || (cat /tmp/pf-api.log; kill `cat /tmp/pf-api.pid`; exit 1); \
	  echo; \
	  echo ">> upload document"; \
	  curl -fsS -X POST http://localhost:18000/documents -H 'Content-Type: application/json' -d '{"filename":"test.pdf","content":"hello world"}'; \
	  echo; \
	  kill `cat /tmp/pf-api.pid` 2>/dev/null || true
	@echo ">> process document via port-forward"
	@kubectl -n $(NAMESPACE) port-forward svc/document-processor 18001:8001 >/tmp/pf-proc.log 2>&1 & echo $$! > /tmp/pf-proc.pid; \
	  sleep 3; \
	  curl -fsS -X POST http://localhost:18001/process/1 || (cat /tmp/pf-proc.log; kill `cat /tmp/pf-proc.pid`; exit 1); \
	  echo; \
	  kill `cat /tmp/pf-proc.pid` 2>/dev/null || true
	@echo ">> web-ui via Ingress"
	curl -fsS -H 'Host: yellowpad.localtest.me' http://localhost:8080/ | head -n 5

logs:
	kubectl -n $(NAMESPACE) logs -l app.kubernetes.io/name=api-gateway --tail=100

clean:
	kubectl delete -k k8s --ignore-not-found

destroy:
	k3d cluster delete $(CLUSTER)
