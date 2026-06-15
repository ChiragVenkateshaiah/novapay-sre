package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	db               *pgxpool.Pool
	receiptSemaphore = make(chan struct{}, 100)
)

func main() {
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, dbURL())
	if err != nil {
		slog.Error("cannot connect to database", "err", err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		slog.Error("database ping failed", "err", err)
		os.Exit(1)
	}
	db = pool
	slog.Info("database connected")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/healthz", handleHealth)
	http.HandleFunc("/charge", handleCharge)

	slog.Info("payment-api starting", "port", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		slog.Error("server failed", "err", err)
		os.Exit(1)
	}
}

func dbURL() string {
	if u := os.Getenv("DATABASE_URL"); u != "" {
		return u
	}
	return "postgres://novapay:novapay@localhost:5432/novapay?sslmode=disable"
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

type chargeRequest struct {
	IdempotencyKey string `json:"idempotency_key"`
	AmountMinor    int64  `json:"amount_minor"`
	Currency       string `json:"currency"`
	CustomerID     string `json:"customer_id"`
}

type chargeResponse struct {
	PaymentID string `json:"payment_id"`
	Status    string `json:"status"`
}

func handleCharge(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req chargeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if req.IdempotencyKey == "" || req.AmountMinor <= 0 || req.Currency == "" {
		http.Error(w, "missing required fields", http.StatusBadRequest)
		return
	}

	ctx := r.Context()

	// idempotency check — return the original result if the key exists
	var existingID, existingStatus string
	err := db.QueryRow(ctx,
		`SELECT id, status FROM payments WHERE idempotency_key = $1`,
		req.IdempotencyKey,
	).Scan(&existingID, &existingStatus)

	if err == nil {
		slog.Info("charge idempotent",
			"idempotency_key", req.IdempotencyKey,
			"payment_id", existingID,
			"latency_ms", time.Since(start).Milliseconds(),
		)
		writeJSON(w, chargeResponse{PaymentID: existingID, Status: existingStatus})
		return
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		slog.Error("idempotency check failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// call fake-psp (no timeout yet — added on Day 6)
	pspStatus, pspRef, err := callPSP(ctx, req.AmountMinor, req.Currency)
	if err != nil {
		slog.Error("psp call failed", "err", err, "idempotency_key", req.IdempotencyKey)
		http.Error(w, "psp unavailable", http.StatusServiceUnavailable)
		return
	}

	// resolve account IDs — stable reference data, looked up once per charge
	var custID, pspID string
	if err := db.QueryRow(ctx,
		`SELECT id FROM accounts WHERE name = 'customer_funds'`,
	).Scan(&custID); err != nil {
		slog.Error("lookup customer_funds failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := db.QueryRow(ctx,
		`SELECT id FROM accounts WHERE name = 'psp_clearing'`,
	).Scan(&pspID); err != nil {
		slog.Error("lookup psp_clearing failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// write payment + two balanced ledger entries in a single transaction
	paymentID := uuid.New().String()

	tx, err := db.Begin(ctx)
	if err != nil {
		slog.Error("db begin failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx,
		`INSERT INTO payments (id, idempotency_key, amount_minor, currency, status, psp_ref)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		paymentID, req.IdempotencyKey, req.AmountMinor, req.Currency, pspStatus, pspRef,
	)
	if err != nil {
		slog.Error("insert payment failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// debit customer_funds
	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (id, payment_id, account_id, amount_minor, direction)
		 VALUES ($1, $2, $3, $4, 'debit')`,
		uuid.New().String(), paymentID, custID, req.AmountMinor,
	)
	if err != nil {
		slog.Error("insert debit failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// credit psp_clearing — must equal the debit for the invariant to hold
	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (id, payment_id, account_id, amount_minor, direction)
		 VALUES ($1, $2, $3, $4, 'credit')`,
		uuid.New().String(), paymentID, pspID, req.AmountMinor,
	)
	if err != nil {
		slog.Error("insert credit failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		slog.Error("commit failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	slog.Info("charge complete",
		"payment_id", paymentID,
		"idempotency_key", req.IdempotencyKey,
		"amount_minor", req.AmountMinor,
		"psp_status", pspStatus,
		"latency_ms", time.Since(start).Milliseconds(),
	)

	select {
	case receiptSemaphore <- struct{}{}:
		go func(pid string) {
			defer func() { <-receiptSemaphore }()
			time.Sleep(100 * time.Millisecond)

			f, err := os.OpenFile("/tmp/novapay-receipts.txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
			if err != nil {
				slog.Error("failed to open receipt log", "err", err)
				return
			}
			defer f.Close()
			if _, err := f.WriteString("receipt-" + pid + "\n"); err != nil {
				slog.Error("failed to write receipt", "err", err)
			}
		}(paymentID)
	default:
		slog.Warn("receipt generation skipped, at concurrency limit", "payment_id", paymentID)
	}

	writeJSON(w, chargeResponse{PaymentID: paymentID, Status: pspStatus})
}

// callPSP sends an authorisation request to fake-psp.
// Retries up to 3 attempts total on HTTP 5xx only, with full-jitter exponential backoff.
// 4xx, network errors, and context cancellation are returned immediately without retry.
// No timeout yet — context deadline added on Day 6.
func callPSP(ctx context.Context, amountMinor int64, currency string) (status, ref string, err error) {
	pspURL := os.Getenv("PSP_URL")
	if pspURL == "" {
		pspURL = "http://localhost:8081"
	}

	body, err := json.Marshal(map[string]any{
		"amount_minor": amountMinor,
		"currency":     currency,
	})
	if err != nil {
		return "", "", fmt.Errorf("marshal: %w", err)
	}

	const maxAttempts = 3
	const baseDelayMS = int64(100)
	const maxDelayMS = int64(1000)

	var lastErr error
	var lastStatus int

	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			capMS := baseDelayMS << attempt // 100*2^attempt: 200ms, 400ms
			if capMS > maxDelayMS {
				capMS = maxDelayMS
			}
			delayMS := rand.Int63n(capMS + 1)
			slog.Warn("psp retry",
				"attempt", attempt+1,
				"delay_ms", delayMS,
				"psp_status", lastStatus,
			)
			select {
			case <-ctx.Done():
				return "", "", ctx.Err()
			case <-time.After(time.Duration(delayMS) * time.Millisecond):
			}
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			pspURL+"/authorize", bytes.NewReader(body))
		if err != nil {
			return "", "", fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return "", "", fmt.Errorf("http: %w", err)
		}

		lastStatus = resp.StatusCode

		if resp.StatusCode >= 500 {
			resp.Body.Close()
			lastErr = fmt.Errorf("psp returned %d", resp.StatusCode)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return "", "", fmt.Errorf("psp returned %d", resp.StatusCode)
		}

		var result struct {
			PSPRef string `json:"psp_ref"`
			Status string `json:"status"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			resp.Body.Close()
			return "", "", fmt.Errorf("decode: %w", err)
		}
		resp.Body.Close()
		return result.Status, result.PSPRef, nil
	}

	return "", "", fmt.Errorf("psp failed after %d attempts: %w", maxAttempts, lastErr)
}
