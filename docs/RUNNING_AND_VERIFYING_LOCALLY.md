# Running & Verifying SecureBank Locally (Step by Step)

This is the **hands-on, verified** runbook for bringing the entire microservices platform
up on one machine with Docker, opening the website, and proving every moving part works
(REST, the gRPC saga, the double-entry ledger, Kafka, and RabbitMQ delivery).

> Everything below was executed end-to-end. Where this machine already had services on the
> default ports, the platform publishes on **alternate host ports** (see the table) via a
> local `docker-compose.override.yml`. On a clean machine the standard ports are used.

---

## 1. Prerequisites

- **Docker** 24+ and the **docker compose** plugin (`docker compose version`).
- ~6 GB free RAM and ~5 GB disk for the images.
- The repos checked out **side by side** in one folder, because the platform compose builds
  each service from `../securebank-<name>`:

```
securebank-ms/
├── securebank-contracts/
├── securebank-gateway/
├── securebank-auth-service/
├── securebank-account-service/
├── securebank-transaction-service/
├── securebank-fraud-service/
├── securebank-notification-service/
├── securebank-shell/
├── securebank-mfe-accounts/
├── securebank-mfe-payments/
└── securebank-platform/   ← you run docker compose from here
```

Clone them all (one-liner):
```bash
for r in contracts gateway auth-service account-service transaction-service \
         fraud-service notification-service shell mfe-accounts mfe-payments platform; do
  git clone https://github.com/247software-Malhar-Jadhav/securebank-$r.git
done
```

---

## 2. Start everything (one command)

```bash
cd securebank-ms/securebank-platform
cp .env.example .env          # required: provides SECUREBANK_JWT_SECRET etc.
docker compose up -d --build
```

The first build compiles the 6 Java services and builds the 3 frontends, so it takes a few
minutes. Compose starts things in dependency order using **healthchecks**:

```
postgres, redis, zookeeper, rabbitmq  →  kafka  →  kafka-init (creates topics)
   →  auth-service, account-service, fraud-service, notification-service
   →  transaction-service, gateway  →  shell
```

Watch them turn healthy:
```bash
docker compose ps
```
Wait until `securebank-gateway` and `securebank-shell` are `Up`. (Java services have a ~90s
health start period — that is normal.)

> **Faster local builds (optional).** Building 6 Java images downloads the Maven world inside
> each container. If you have already built the jars on the host (`mvn -DskipTests package` in
> each service) and the frontends (`npm i && npm run build`), you can use a thin
> "copy-the-artifact" Dockerfile instead — see [Appendix A](#appendix-a--fast-local-images).

---

## 3. Access links (what to open)

> Ports in **bold** are the alternates this machine used because the default was busy. On a
> clean machine use the default (shown in parentheses).

| What | URL | Notes |
|---|---|---|
| **Website (the app)** — micro-frontend shell | http://localhost:5170 | start here |
| mfe-accounts (standalone remote) | http://localhost:5171 | also `/assets/remoteEntry.js` |
| mfe-payments (standalone remote) | http://localhost:5172 | also `/assets/remoteEntry.js` |
| API gateway (public REST) | http://localhost:**18080**/api  (clean: 8080) | the only public backend |
| auth-service Swagger | http://localhost:8081/swagger-ui/index.html | |
| account-service Swagger | http://localhost:**18082**/swagger-ui/index.html (clean: 8082) | |
| transaction-service Swagger | http://localhost:8083/swagger-ui/index.html | |
| fraud-service Swagger | http://localhost:8084/swagger-ui/index.html | |
| notification-service health | http://localhost:8085/actuator/health | |
| **RabbitMQ** management UI | http://localhost:15672 | user/pass `guest` / `guest` |
| PostgreSQL | localhost:**55432** (clean: 5432) | user `securebank`/`securebank`, db `securebank`; user `auth`/`auth`, db `auth` |
| Redis | localhost:**56379** (clean: 6379) | |
| Kafka broker | localhost:29092 | internal listener `kafka:29092` |

**Demo logins** (seeded by Flyway): `admin / Password123!` (ADMIN) and
`jsmith / Password123!` (CUSTOMER, owns two INR accounts).

---

## 4. Use the website

1. Open **http://localhost:5170**.
2. Log in as `jsmith / Password123!`.
3. **Dashboard** (served by `mfe-accounts`, lazy-loaded into the shell) shows account balance
   cards, recent activity, and the AI spending-insights chart + summary.
4. **Transfer** (served by `mfe-payments`) — move money between the two accounts; you get a
   reference id and the updated balance. A fraud BLOCK or insufficient-funds shows the
   backend's localized error.
5. Switch language (top bar: **English / हिन्दी / मराठी**) — UI strings *and* server messages
   localize.

---

## 5. Verify the backend end-to-end with curl

```bash
GW=http://localhost:18080/api      # use 8080 on a clean machine

# 5.1 Log in (gateway → auth-service), capture the JWT
TOKEN=$(curl -s -X POST $GW/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"jsmith","password":"Password123!"}' | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)

# 5.2 List accounts (gateway validates the JWT over gRPC, routes to account-service)
curl -s $GW/accounts -H "Authorization: Bearer $TOKEN"
# → two accounts, e.g. SB-INR-0000000001 = 5000.00, SB-INR-0000000002 = 1500.00

# 5.3 Transfer 250 (the gRPC SAGA: fraud.Score → account.Debit → account.Credit → Kafka)
curl -s -X POST $GW/transactions/transfer -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"fromAccountId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
       "toAccountId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
       "amount":250,"currency":"INR","description":"test"}'
# → {"reference":"TXN-...","status":"COMPLETED","fraudScore":0.49,"sourceBalanceAfter":4650.0000}
```

Note the request shape: `amount` is a **plain number** + a `currency` field on the REST API
(the `Money{currency,units,nanos}` object is the gRPC wire format, used *between* services).

**Confirm the money actually moved (double-entry):**
```bash
docker exec securebank-postgres psql -U securebank -d securebank \
  -c "SELECT account_number, balance FROM accounts.accounts ORDER BY 1;"
# SB-INR-0000000001 = 4650.0000   (source −250)
# SB-INR-0000000002 = 1750.0000   (destination +250)

docker exec securebank-postgres psql -U securebank -d securebank \
  -c "SELECT account_id, direction, amount FROM ledger.ledger_entries ORDER BY created_at DESC LIMIT 2;"
# one DEBIT 250 on the source, one CREDIT 250 on the destination — balanced
```

---

## 6. Verify the event pipeline (Kafka → RabbitMQ)

```bash
# The transfer published a TransactionCompleted event to Kafka:
docker exec securebank-kafka kafka-console-consumer \
  --bootstrap-server localhost:29092 --topic securebank.transactions \
  --from-beginning --timeout-ms 5000

# notification-service consumed it, localized a message, and delivered it via RabbitMQ:
docker logs securebank-notification-service 2>&1 | grep DELIVERY
# [DELIVERY:LOG] ... body="Your transfer of INR 250 to account ... was completed ..."

# RabbitMQ queue (drains as messages are consumed):
docker exec securebank-rabbitmq rabbitmqctl list_queues name messages
```

See [`kafka-guide.md`](./kafka-guide.md), [`rabbitmq-guide.md`](./rabbitmq-guide.md),
[`redis-guide.md`](./redis-guide.md) for deeper inspection (consumer groups, exchanges,
cache keys, distributed locks).

---

## 7. Inspect the gRPC mesh

The internal gRPC ports (9091–9094) are not published; reach them from inside the network:
```bash
docker exec securebank-transaction-service sh -c \
  'grpcurl -plaintext account-service:9092 list' 2>/dev/null || \
  echo "install grpcurl in the image to introspect; reflection is enabled on every server"
```
gRPC server reflection is enabled, so `grpcurl ... list` / `describe` works. See
[`grpc-guide.md`](./grpc-guide.md).

---

## 8. Stop / reset

```bash
docker compose down            # stop, keep data
docker compose down -v         # stop AND wipe volumes (fresh DB + reseed on next up)
docker compose logs -f <svc>   # follow a service's logs
```

---

## 9. Troubleshooting (issues actually hit, and the fixes)

| Symptom | Cause | Fix |
|---|---|---|
| `Bind for 0.0.0.0:6379 failed: port is already allocated` | host already runs Postgres/Redis/another app on 5432/6379/8080/8082 | publish on alternate host ports (the override file remaps them); or stop the conflicting service |
| Zookeeper stuck "health: starting" forever | the image's `ruok` 4-letter-word stays disabled even with the whitelist env | healthcheck uses **`srvr`** instead (already fixed in `docker-compose.yml`) |
| A Java service crash-loops with `ClassNotFoundException: io.grpc.InternalConfiguratorRegistry` | gRPC artifacts at mismatched versions | the service pom imports the **grpc-bom** so all `io.grpc:*` converge (already fixed) |
| gateway crash-loops with `NoClassDefFoundError: io.grpc.netty.NettyChannelBuilder` | Spring Cloud Gateway's gRPC config needs the **unshaded** `grpc-netty` | gateway pom adds `io.grpc:grpc-netty` (already fixed) |
| `password authentication failed for user "auth"` | a **stale Postgres volume** from an earlier run; the init script (which creates the `auth` role/db) only runs on an empty volume | `docker compose down -v` then `up` so init runs fresh |
| mfe-payments nginx exits: `host not found in upstream "gateway"` | nginx resolves a literal upstream at startup before the gateway exists | use a `resolver` + variable so it resolves lazily (already fixed) |
| transfer returns COMPLETED but destination not credited | debit & credit shared one idempotency key, so the credit was deduped as a replay of the debit | the saga sends **distinct keys** (`ref:debit` / `ref:credit`) (already fixed) |

---

## Appendix A — Fast local images

To skip in-container Maven/npm downloads, build artifacts on the host first, then point each
service/frontend at a thin Dockerfile that copies the artifact:

```dockerfile
# Dockerfile.local (Java service) — copies the host-built fat jar
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY target/*.jar app.jar
ENTRYPOINT ["java","-jar","/app/app.jar"]
```
```dockerfile
# Dockerfile.local (frontend) — serves the host-built dist via nginx
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
```
Add a `Dockerfile.local.dockerignore` (BuildKit honors per-Dockerfile ignore files) that does
NOT exclude `target/`/`dist`, then override `build.dockerfile: Dockerfile.local` per service in
a local `docker-compose.override.yml`. This is exactly how this run was accelerated.
