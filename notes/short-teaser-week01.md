10 charges. 23 calls to the bank. Every one returned "approved."

The ledger balanced. The dashboard was green. It looked completely correct.

It was a retry storm — my client quietly hammering a struggling dependency 10× harder, exactly when it was already failing. The outcome looked fine, which is what made it dangerous.

That was one of three incidents in Week 1 of building NovaPay — a small payments platform I'm using to learn SRE, DevOps, and Platform Engineering by operating a real system and deliberately breaking it.

The other two:

→ A service whose health check answered in 11ms and reported "ok" — while every real request hung on a dead dependency and goroutines climbed 7 → 27. Liveness is not health.

→ 15 successful charges that left 15 zombie processes behind, one per charge, counting down toward PID exhaustion. The only signal was one line of `ps` output.

The thread connecting all three: each one *looked* correct. The failure was invisible until I went looking with the right command.

I wrote up the whole week — the root causes, the actual command output, the fixes, and the agentic workflow (Claude Code with a hook that physically blocks unsafe deploys). The repo is public and every incident is a real GitHub issue.

Full article in comments. 👇

github.com/ChiragVenkateshaiah/novapay-sre

#SRE #DevOps #PlatformEngineering #Go #Observability
