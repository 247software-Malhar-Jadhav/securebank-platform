# The Money-Transfer Saga — flagship flow

> This is the single most important flow in SecureBank. A customer initiates a
> transfer in the payments micro-frontend; it crosses the gateway, the
> transaction-service saga orchestrator, the fraud + account services over **gRPC**,
> emits a **Kafka** event, which the notification-service turns into a **RabbitMQ**
> delivery. It includes the **saga compensation path** for a failed credit.

---

## 1. Happy path (end to end)

```mermaid
sequenceDiagram
    autonumber
    actor U as Customer
    participant MFE as mfe-payments<br/>(./Transfer)
    participant SH as shell (:5170)
    participant GW as gateway (:8080)
    participant AU as auth-service<br/>(gRPC :9091)
    participant TX as transaction-service<br/>(saga orchestrator)
    participant FR as fraud-service<br/>(gRPC :9094)
    participant AC as account-service<br/>(gRPC :9092)
    participant K as Kafka<br/>securebank.transactions
    participant NO as notification-service
    participant RB as RabbitMQ<br/>notifications.queue

    U->>MFE: Fill transfer form, submit
    MFE->>SH: dispatch (shared store) + RTK Query
    SH->>GW: POST /api/transactions/transfer<br/>Bearer <jwt> { from, to, amount, currency }

    GW->>AU: gRPC ValidateToken(jwt)
    AU-->>GW: TokenClaims{ valid=true, userId, roles }
    GW->>TX: POST /transactions/transfer<br/>+ X-User-Id, X-Roles (trusted headers)

    Note over TX: SAGA begins — orchestration, not 2PC

    TX->>FR: gRPC Score(from,to,amount,customerId)
    FR-->>TX: ScoreResult{ score, decision=ALLOW }
    alt decision == BLOCK
        TX-->>GW: TransferResult{ status=REJECTED, reason }
        GW-->>SH: 200 { REJECTED }
    else decision == ALLOW
        TX->>AC: gRPC Debit(from, amount, txRef)
        AC->>AC: lock row + @Version + Redis lock<br/>check funds, apply, record txRef
        AC-->>TX: BalanceChangeResult{ applied=true, newBalance }

        TX->>AC: gRPC Credit(to, amount, txRef)
        AC-->>TX: BalanceChangeResult{ applied=true, newBalance }

        TX->>TX: write double-entry ledger rows (schema ledger)
        TX->>K: publish TransactionCompleted
        TX-->>GW: TransferResult{ status=COMPLETED, reference, fraudScore }
        GW-->>SH: 200 { COMPLETED }
        SH-->>U: success toast + updated balance
    end

    K-->>NO: consume TransactionCompleted
    NO->>NO: render localized message (en/hi/mr)<br/>persist to schema notifications
    NO->>RB: publish to securebank.notifications.exchange<br/>routing-key notification.transaction.completed
    RB-->>RB: queued for delivery worker (email/SMS/push)
```

### Why it is a **saga**, not a distributed transaction

There is no two-phase commit across services. transaction-service **orchestrates** a
sequence of local transactions (Debit on source, Credit on destination), each
committed independently in account-service. If a later step fails, the orchestrator
runs a **compensating action** to undo the earlier committed step. This trades strict
atomicity for availability and loose coupling — the standard microservices answer to
"there is no shared transaction manager".

---

## 2. Compensation path (credit fails after a successful debit)

```mermaid
sequenceDiagram
    autonumber
    participant TX as transaction-service<br/>(saga orchestrator)
    participant AC as account-service
    participant K as Kafka
    participant NO as notification-service

    TX->>AC: gRPC Debit(from, amount, txRef)
    AC-->>TX: applied=true (money has LEFT the source)

    TX->>AC: gRPC Credit(to, amount, txRef)
    AC--xTX: FAILED (e.g. destination FROZEN / not found / timeout)

    Note over TX: Step 2 failed AFTER step 1 committed.<br/>Run the COMPENSATING transaction.

    TX->>AC: gRPC Credit(from, amount, txRef-COMP)<br/>(refund the source)
    AC-->>TX: applied=true (source made whole)

    TX->>TX: mark ledger entry status = FAILED/COMPENSATED
    TX->>K: publish TransactionCompleted{ status=FAILED }
    TX-->>TX: return TransferResult{ status=FAILED, reason }
    K-->>NO: consume → notify customer the transfer failed
```

### Idempotency makes the saga safe to retry

Both `Debit` and `Credit` are **idempotent on `transaction_ref`** (account.proto):
account-service records the ref and, on a repeat with the same ref, returns the
*original* result instead of applying the change again. So when
transaction-service's Resilience4j retry re-sends a `Debit` after a network blip, the
money is **not** moved twice. The compensating credit uses a *distinct* ref so it is
itself idempotent and never confused with the original.

```mermaid
stateDiagram-v2
    [*] --> Scoring
    Scoring --> Rejected: decision = BLOCK
    Scoring --> Debiting: decision = ALLOW
    Debiting --> Crediting: debit applied
    Debiting --> Failed: debit refused (insufficient funds)
    Crediting --> Completed: credit applied
    Crediting --> Compensating: credit failed
    Compensating --> Failed: source refunded
    Completed --> [*]
    Rejected --> [*]
    Failed --> [*]
```

---

## 3. Failure-mode summary

| Step fails | What transaction-service does | Customer sees | Money state |
|---|---|---|---|
| Fraud `Score` unavailable | Circuit breaker → fail closed (REVIEW/REJECT) or retry | REJECTED / pending review | unchanged |
| `Debit` refused (no funds) | Stop the saga, no compensation needed | REJECTED reason=INSUFFICIENT_FUNDS | unchanged |
| `Debit` times out | Retry (idempotent on txRef) | COMPLETED or FAILED | applied at most once |
| `Credit` fails | **Compensate**: refund source via Credit | FAILED | source made whole |
| Kafka publish fails | Transfer already COMPLETED; event retried / outbox | COMPLETED | unchanged (notification delayed) |
| Notification path down | No effect on the transfer | COMPLETED | unchanged |

The boundary is deliberate: **the transfer's correctness depends only on the
synchronous gRPC saga**; the Kafka→Rabbit notification is best-effort and
eventually-consistent.
