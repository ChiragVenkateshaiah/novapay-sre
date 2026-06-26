package main

import (
	"fmt"
	"net/http"
	"strconv"
)

// balloon holds allocated slabs across requests so the GC cannot collect them.
// Grows monotonically for the duration of the process — this is intentional:
// the point is to drive RSS up to trigger the cgroup OOM kill.
var balloon [][]byte

func handleBalloon(w http.ResponseWriter, r *http.Request) {
	mbStr := r.URL.Query().Get("mb")
	mb, err := strconv.Atoi(mbStr)
	if err != nil || mb <= 0 || mb > 512 {
		http.Error(w, "mb must be a positive integer <= 512", http.StatusBadRequest)
		return
	}

	slab := make([]byte, mb*1024*1024)

	// Touch every page so the kernel faults in physical frames now.
	// make() returns virtual memory backed by MAP_ANONYMOUS pages that are
	// copy-on-write zeroed — they don't contribute to RSS until first written.
	// Writing one byte per 4KB page forces a page fault on each page, causing
	// the kernel to assign a physical frame. After this loop RSS grows by ~N MB.
	const pageSize = 4096
	for i := 0; i < len(slab); i += pageSize {
		slab[i] = 1
	}

	balloon = append(balloon, slab)
	fmt.Fprintf(w, "ballooned +%dMB (total slabs: %d)\n", mb, len(balloon))
}
