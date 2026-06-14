

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/google/uuid"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}

	http.HandleFunc("/authorize", handleAuthorize)
	log.Printf("fake-psp listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleAuthorize(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Failure knob: inject latency
	if ms := os.Getenv("PSP_LATENCY_MS"); ms != "" {
		n, _ := strconv.Atoi(ms)
		time.Sleep(time.Duration(n) * time.Millisecond)
	}

	// Failure knob: random transient errors (Day 4 meltdown demo)
	if rate := os.Getenv("PSP_ERROR_RATE"); rate != "" {
		if r, _ := strconv.ParseFloat(rate, 64); rand.Float64() < r {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "psp_transient_failure"})
			return
		}
	}

	// Failure knob: hang forever (Day 6 incident)
	if os.Getenv("PSP_HANG") == "true" {
		select {} // block forever
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"psp_ref": fmt.Sprintf("psp_%s", uuid.New().String()[:8]),
		"status":  "approved",
	})
}
