


CREATE TABLE IF NOT EXISTS accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) UNIQUE NOT NULL,
  type VARCHAR(50) NOT NULL
);

CREATE TABLE IF NOT EXISTS payments (
    id              UUID                PRIMARY KEY,
    idempotency_key VARCHAR(255)        UNIQUE NOT NULL,
    amount_minor    BIGINT              NOT NULL,
    currency        VARCHAR(3)          NOT NULL,
    status          VARCHAR(50)         NOT NULL,
    psp_ref         VARCHAR(255),
    created_at      TIMESTAMPTZ          NOT NULL DEFAULT NOW()

);


  CREATE TABLE IF NOT EXISTS ledger_entries (
    id              UUID                PRIMARY KEY,
    payment_id      UUID                NOT NULL REFERENCES payments(id),
    account_id      UUID                NOT NULL REFERENCES accounts(id),
    amount_minor    BIGINT              NOT NULL,
    direction       VARCHAR(10)         NOT NULL CHECK (direction IN ('debit', 'credit')),
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW()

);  


-- Seed accounts
INSERT INTO accounts (name, type) VALUES
    ('customer_funds', 'asset'),
    ('psp_clearing',   'liability')
ON CONFLICT (name) DO NOTHING;



-- Invariant check query (run by hand to verify balance)
-- SELECT payment_id
--        SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) AS debits,
--        SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credit,
-- FROM ledger_entries GROUP BY payment_id
-- HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
--        SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);