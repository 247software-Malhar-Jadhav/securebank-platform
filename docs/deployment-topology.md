# Deployment Topology

> Where each piece runs in a production-shaped Kubernetes deployment, and how traffic
> enters.

---

## 1. Deployment diagram

```mermaid
flowchart TB
    user([Customer browser])

    subgraph cloud["Cloud / Kubernetes cluster"]
        direction TB
        lb["Cloud Load Balancer<br/>(TLS termination)"]
        ing["Ingress (nginx)<br/>/ → shell · /api → gateway"]

        subgraph nsedge["namespace: securebank — edge"]
            shellpods["shell × N (Deployment)<br/>+ HPA"]
            gwpods["gateway × N (Deployment)<br/>+ HPA"]
            mfeA["mfe-accounts (Deployment)"]
            mfeP["mfe-payments (Deployment)"]
        end

        subgraph nssvc["namespace: securebank — services (internal only)"]
            auth["auth-service (Deployment)"]
            acct["account-service × N + HPA"]
            txn["transaction-service × N + HPA"]
            fraud["fraud-service (Deployment)"]
            notif["notification-service (Deployment)"]
        end

        subgraph nsdata["stateful (operators or managed)"]
            pg[("Postgres<br/>StatefulSet / managed")]
            redis[("Redis")]
            kafka{{"Kafka (Strimzi)"}}
            rabbit{{"RabbitMQ (operator)"}}
        end
    end

    anthropic([Anthropic API — optional])

    user -->|HTTPS| lb --> ing
    ing -->|/| shellpods
    ing -->|/api| gwpods
    shellpods -. "remoteEntry.js" .-> mfeA
    shellpods -. "remoteEntry.js" .-> mfeP

    gwpods -->|gRPC| auth
    gwpods -->|REST| acct
    gwpods -->|REST| txn
    gwpods -->|REST| fraud

    txn -->|gRPC| acct
    txn -->|gRPC| fraud
    txn --> kafka
    kafka --> notif
    notif --> rabbit

    auth --> pg
    acct --> pg
    acct --> redis
    txn --> pg
    fraud --> redis
    notif --> pg
    fraud -. optional .-> anthropic
```

---

## 2. What is exposed where

| Tier | Components | Exposure |
|---|---|---|
| Edge | Ingress → shell (`/`), gateway (`/api`) | **Public** (behind LB + TLS) |
| Services | auth, account, transaction, fraud, notification | **Cluster-internal** (ClusterIP only) |
| gRPC | 9091/9092/9093/9094 named ports | **Cluster-internal**, never via Ingress |
| Data | Postgres, Redis, Kafka, RabbitMQ | **Cluster-internal** / managed endpoints |

Only two things ever face the internet: the **shell** (static UI) and the
**gateway** (`/api`). Everything else is reachable only by service name inside the
namespace.

---

## 3. Scaling profile

```mermaid
flowchart LR
    subgraph hpa["HPA-managed (CPU 70%)"]
        g["gateway 2→6"]
        t["transaction 2→8"]
        a["account 2→6"]
    end
    subgraph fixed["fixed replicas (prod overlay)"]
        au["auth 2"]
        fr["fraud 2"]
        no["notification 2"]
        sh["shell 2"]
    end
```

- The **hot path** (public gateway + the transfer saga's transaction & account
  services) autoscales on CPU.
- **notification-service** scales with Kafka consumer-group parallelism (add replicas
  up to the partition count of `securebank.transactions`).
- **Stateful infra** scales via its operator (Strimzi brokers, Postgres replicas),
  not HPA.

---

## 4. Environments

| Env | Overlay | DB / Kafka | Replicas | Secrets |
|---|---|---|---|---|
| Local docker | `docker-compose.yml` | in-compose containers | 1 each | `.env` |
| Dev cluster | `k8s/overlays/dev` | in-cluster StatefulSets | 1 each, no HPA | template Secret |
| Prod | `k8s/overlays/prod` | managed / operators | floors + HPA | SealedSecret / Vault |

See [`kubernetes-guide.md`](./kubernetes-guide.md) for apply commands and
[`cicd.md`](./cicd.md) for how images get built and promoted.
