# Kubernetes Guide

> Spin up SecureBank on a local cluster (kind or minikube), apply an overlay, watch a
> pod, port-forward, scale, and exercise the HPA. Copy-pasteable throughout.

---

## 1. Layout

```
k8s/
├── base/                      # full platform: namespace, config, secret, infra,
│   ├── kustomization.yaml     #   6 services, 3 frontends, ingress, HPAs
│   ├── namespace.yaml
│   ├── configmap.yaml  secret.yaml
│   ├── postgres.yaml  redis.yaml  kafka.yaml  rabbitmq.yaml
│   ├── auth-service.yaml ... gateway.yaml  frontends.yaml
│   ├── ingress.yaml  hpa.yaml
└── overlays/
    ├── dev/                   # single replicas, no HPA — for kind/minikube
    └── prod/                  # registry images, replica floors, SealedSecret note
```

Each Deployment has: actuator probes (`/actuator/health/{readiness,liveness}`,
transaction-service uses `/actuator/health`), CPU/memory requests+limits, env from
the ConfigMap + Secret, and named `grpc` ports where applicable.

---

## 2. Create a local cluster

### Option A — kind

```bash
kind create cluster --name securebank
# Ingress controller (needed for the Ingress):
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=120s
```

### Option B — minikube

```bash
minikube start --cpus=4 --memory=8192
minikube addons enable ingress
minikube addons enable metrics-server      # required for HPA
```

---

## 3. Get the images into the cluster

The manifests reference `securebank/<service>:local`. Build them (from each repo or
via the compose build), then load them in:

```bash
# Build all images once via compose (tags them securebank/<svc>:local):
( cd .. ; docker compose -f securebank-platform/docker-compose.yml build )

# kind: load each image into the node
for img in gateway auth-service account-service transaction-service \
           fraud-service notification-service shell mfe-accounts mfe-payments; do
  kind load docker-image securebank/$img:local --name securebank
done

# minikube: point docker at minikube's daemon BEFORE building, or:
minikube image load securebank/gateway:local   # ...repeat per image
```

> The Deployments use `imagePullPolicy: IfNotPresent`, so loaded local images are used
> without a registry.

---

## 4. Apply an overlay

```bash
# Dev (single replicas, no HPA):
kubectl apply -k k8s/overlays/dev

# Or the raw base:
kubectl apply -k k8s/base

# Watch everything come up:
kubectl -n securebank get pods -w
```

Order is handled by probes + Kubernetes retries (no `depends_on` in k8s): pods that
depend on Postgres/Kafka simply crash-loop briefly until those are ready, then settle.
The `kafka-topics-init` Job waits for the broker, creates topics, and completes.

---

## 5. Get a pod running / inspect

```bash
kubectl -n securebank get pods
kubectl -n securebank describe pod <pod>
kubectl -n securebank logs deploy/gateway -f
kubectl -n securebank logs deploy/transaction-service --tail=100

# Readiness/liveness (probe results show in describe → Conditions/Events)
kubectl -n securebank get deploy
```

---

## 6. Port-forward & reach the app

```bash
# Public API via the gateway:
kubectl -n securebank port-forward svc/gateway 8080:8080
curl -s -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"jsmith","password":"Password123!"}'

# The UI:
kubectl -n securebank port-forward svc/shell 5170:5170   # open http://localhost:5170

# A gRPC port (internal) for grpcurl:
kubectl -n securebank port-forward svc/account-service 9092:9092

# Infra UIs:
kubectl -n securebank port-forward svc/rabbitmq 15672:15672
```

Via the **Ingress** instead (host `securebank.localtest.me` resolves to 127.0.0.1):

```bash
# kind maps ingress to localhost; minikube: use `minikube tunnel` or the node IP.
curl -H 'Host: securebank.localtest.me' http://localhost/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"jsmith","password":"Password123!"}'
```

---

## 7. Scale & HPA

```bash
# Manual scale
kubectl -n securebank scale deploy/transaction-service --replicas=3

# HPAs (base overlay only — gateway, transaction-service, account-service)
kubectl -n securebank get hpa
kubectl -n securebank describe hpa gateway

# Generate load to watch it scale (metrics-server must be installed):
kubectl -n securebank run load --image=busybox --restart=Never -it --rm -- \
  /bin/sh -c "while true; do wget -q -O- http://gateway:8080/actuator/health; done"
kubectl -n securebank get hpa -w
```

---

## 8. Secrets — do NOT ship the template

`k8s/base/secret.yaml` holds **plaintext placeholders** so `apply -k` works on a demo
cluster. For anything shared:

```bash
# Sealed Secrets (controller decrypts in-cluster):
kubeseal --format yaml < k8s/base/secret.yaml > sealed-secret.yaml   # commit THIS
# then reference sealed-secret.yaml from the prod overlay instead of secret.yaml.
```

Or use the **External Secrets Operator** / **Vault Agent Injector** to sync from a
real secret store. Rotate `SECUREBANK_JWT_SECRET` and DB/Rabbit passwords first.

---

## 9. Production swaps

- **Databases:** delete `postgres.yaml` from the kustomization, point
  `POSTGRES_HOST` at a managed Postgres (RDS/Cloud SQL) — or run CloudNativePG.
- **Kafka:** use the Strimzi `Kafka` + `KafkaTopic` CRs (commented in
  [`k8s/base/kafka.yaml`](../k8s/base/kafka.yaml)).
- **RabbitMQ/Redis:** RabbitMQ Cluster Operator / managed Redis.
- **Images:** the prod overlay pins `REGISTRY/securebank/*:1.0.0` — set your registry
  and tags.

---

## 10. Tear down

```bash
kubectl delete -k k8s/overlays/dev      # or k8s/base
kind delete cluster --name securebank   # or: minikube delete
```
