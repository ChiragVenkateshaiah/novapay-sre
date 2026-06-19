# Daily Learning Questions — Day 07 (Week 1 Complete Set)
*Paste these into Claude.ai chat to dig deeper on each topic.*
*This is the first complete set — covers all concepts encountered across Week 1.*

---

## Go Fundamentals
*(Anchored to actual NovaPay code — chargeRequest struct, receiptWorker channel, callPSP function, context usage)*

1. [Basic] In `payment-api/main.go`, the charge handler decodes the request body into a struct:
   ```go
   var req struct {
       IdempotencyKey string `json:"idempotency_key"`
       AmountMinor    int64  `json:"amount_minor"`
       Currency       string `json:"currency"`
       CustomerID     string `json:"customer_id"`
   }
   ```
   What is a struct in Go? How is it different from a map? Why is `int64` used for `AmountMinor` instead of `float64`?

2. [Basic] Go variables can be declared three ways: `var x int = 5`, `var x = 5`, and `x := 5`. When is each form used? In NovaPay's `callPSP` function, you see `var pspClient = &http.Client{Timeout: 6 * time.Second}` at the package level. Why can't `:=` be used there?

3. [Basic] NovaPay uses `var receiptWorker = make(chan string, 50)`. What is a slice and how does it differ from an array in Go? Now look at `make(chan string, 50)` — `make` is also used for slices. What does `make` do in each case, and why does Go need `make` at all?

4. [Applied] The NovaPay ledger writes two rows per charge: one debit, one credit. In Go, if you wanted to collect the two `ledger_entries` in a slice before inserting them, how would you declare and append to that slice? Write the code. Now explain: what happens to the underlying array when you `append` beyond the slice's capacity?

5. [Applied] In `callPSP`, the function signature is:
   ```go
   func callPSP(ctx context.Context, amountMinor int64, currency string) (status, ref string, err error)
   ```
   Go supports multiple return values. Why does `callPSP` return three values? What does the named return `(status, ref string, err error)` tell you about the function's contract? How does the caller use all three?

6. [Applied] NovaPay's retry loop uses this pattern:
   ```go
   select {
   case <-pspCtx.Done():
       return "", "", pspCtx.Err()
   case <-time.After(time.Duration(delayMS) * time.Millisecond):
   }
   ```
   What is `select` in Go? How is it different from a `switch`? What happens if both channels are ready at the same time?

7. [Deep] The receipt worker uses `for id := range receiptWorker`. Explain exactly what happens when `close(receiptWorker)` is called while there are still items in the buffer. Why does `for range` on a channel drain buffered items before exiting, and what is the internal mechanism that makes this work? What would happen if you used `for { id := <-receiptWorker }` instead — and why is that unsafe?

8. [Deep] `context.WithTimeout` returns a child context and a `cancel` function. The NovaPay code does:
   ```go
   pspCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
   defer cancel()
   ```
   What happens if you forget `defer cancel()`? What goroutine leak does it cause? Trace the internal chain: how does `WithTimeout` implement the deadline at the Go runtime level, and how does the HTTP transport watch `pspCtx.Done()` without blocking the caller's goroutine?

9. [Deep] NovaPay wraps errors like this: `fmt.Errorf("http: %w", urlErr)`. What does `%w` do that `%v` does not? In the charge handler, `errors.Is(err, context.DeadlineExceeded)` traverses the wrapped chain to find `DeadlineExceeded`. Write out the complete error wrapping chain from the moment `pspCtx` fires to the `errors.Is` call that classifies it as a timeout. What is the purpose of each layer of wrapping?

---

## Linux & Systems
*(Based on concepts from Days 1–6: process lifecycle, signals, systemd, journald, ps/top, goroutines vs threads)*

1. [Basic] On Linux, every process has a PID (Process ID) and a PPID (Parent Process ID). What is a process? How is a new process created on Linux — what system calls are involved, and why does a child process initially look like a copy of its parent?

2. [Basic] When `systemctl stop payment-api` runs, systemd sends SIGTERM to the process. What is a signal? Name five common signals, their numbers, and their default actions. Why does systemd send SIGTERM first rather than SIGKILL?

3. [Basic] NovaPay's systemd unit file has `StandardOutput=journal` and `SyslogIdentifier=payment-api`. What is journald, and how does it differ from traditional syslog? What does `journalctl -u payment-api -f` actually do at the OS level — where does it read from?

4. [Applied] In Day 5, 15 charges produced 15 zombie processes (state `Z`). Explain the complete zombie lifecycle: what system calls are involved from `fork()` to `wait()` to `exit()`. Why does a zombie hold no memory or CPU but still occupy a process table entry? At what scale does zombie accumulation become a system-level failure?

5. [Applied] `ps -p <pid> -o pid,nlwp,vsz` showed NLWP=9 throughout the goroutine accumulation (7 → 27 goroutines). Explain the M:N threading model Go uses. What is an OS thread (LWP — light-weight process)? Why did goroutines pile up (27) while OS threads stayed flat (9)? What is `epoll` and how does it allow Go to block goroutines on I/O without blocking OS threads?

6. [Applied] NovaPay's unit file uses `After=network.target postgresql.service` for `payment-api` but only `After=network.target` for `fake-psp`. Why? What does `After=` actually guarantee — is it ordering only, or does systemd also wait for the dependency to be "ready"? What would you add to get a true readiness dependency?

7. [Applied] Connect to NovaPay: The `payment-api.service` unit has `Restart=on-failure` and `RestartSec=5s`. Under what exact conditions will systemd restart the process? Under what conditions will it NOT restart? If the invariant breaks and you `kill -9 <pid>`, does systemd restart it? If yes, what is the risk to the ledger?

8. [Deep] Go's runtime multiplexes goroutines onto OS threads. When a goroutine calls `http.Client.Do(req)` and the PSP hangs, the goroutine blocks. Explain the exact sequence: how does Go's netpoller (epoll/kqueue) suspend the goroutine without blocking the OS thread? When `pspCtx.Done()` fires, what wakes the goroutine up, and which OS thread picks it up? Why does goroutine count reflect resource exhaustion even when thread count does not?

9. [Deep] `context.DeadlineExceeded` fires at 5s, the HTTP transport closes the TCP connection, and the blocked `Read()` on the socket returns immediately. Explain this from the kernel's perspective: what does `conn.Close()` do to a blocking `read()` syscall? What error code does the kernel return? How does Go's HTTP transport translate that kernel error into `context.DeadlineExceeded` rather than a generic `io.EOF`?

---

## Ansible
*(Concepts from Day 3: playbooks, modules, idempotency, delegate_to, check mode)*

1. [Basic] An Ansible playbook has three main sections: `hosts`, `vars`, and `tasks`. What is a task, and what is a module? Name five modules used in NovaPay's `deploy.yml` and what each one does.

2. [Basic] Ansible idempotency means "running the playbook twice leaves the system in the same state as running it once." Which modules in `deploy.yml` are idempotent by design? Which tasks are NOT idempotent by default, and how were they made idempotent in NovaPay's playbook?

3. [Applied] `delegate_to: localhost` appears on the `go build` tasks in `deploy.yml`. Explain what this does: the play targets EC2, but the task runs on WSL2. Why is this the correct pattern for a build-then-deploy workflow? What would break if you removed `delegate_to: localhost` and ran `go build` on EC2 directly?

4. [Applied] Connect to NovaPay: The `--check --diff` flags make Ansible run in check mode. From the Day 3 notes, which task types are silent in check mode and give zero information? What does `--diff` add? Write out the complete confidence chain: what does `/check` cover that `--check` misses, and vice versa?

5. [Deep] In `deploy.yml`, the Postgres setup uses `shell` tasks with `2>/dev/null || true` instead of `community.postgresql` modules. Explain the trade-off: what does the `community.postgresql` module offer that raw `shell` does not? Why was `shell` chosen? What would you need to do to use `community.postgresql` correctly on a fresh EC2 host?

---

## Terraform
*(Intro level — Terraform joins the workflow in Week 2; understand what it is and how it relates to Ansible)*

1. [Basic] What is Terraform, and what problem does it solve? In one sentence each: how does Terraform differ from Ansible in its purpose, its approach (declarative vs procedural), and the infrastructure layer it targets?

2. [Basic] Terraform uses a concept called "state." What is Terraform state, and why does it exist? Where is state stored by default, and why is that a problem for team workflows?

3. [Applied] NovaPay currently uses Ansible to provision EC2 (`provision.yml`) and deploy the app (`deploy.yml`). If Terraform replaced `provision.yml`, what would it manage? What would Ansible still be responsible for? Draw the boundary: Terraform manages X, Ansible manages Y.

4. [Applied] A Terraform resource block looks like:
   ```hcl
   resource "aws_instance" "novapay" {
     ami           = "ami-0abcdef1234567890"
     instance_type = "t3.micro"
   }
   ```
   What does `terraform plan` show you? What does `terraform apply` do? How does Terraform know what already exists vs what needs to be created?

5. [Deep] Ansible and Terraform both claim to be "idempotent." But they implement idempotency differently. Explain the difference: how does Ansible achieve idempotency (per-module, imperative checks), vs how Terraform achieves it (desired state vs actual state in the state file). What failure modes does each approach have that the other doesn't?

---

## Cloud & AWS Concepts
*(Connecting current EC2 work to the broader AWS foundation — SAA cert is ~Week 12)*

1. [Basic] NovaPay runs on EC2 (`t3.micro`, `ap-south-2`). What is EC2? What is an instance type, and what does `t3.micro` mean specifically — CPU credits, memory, network? Why was `ap-south-2` (Asia Pacific — Hyderabad) chosen rather than `us-east-1`?

2. [Basic] EC2 access uses an SSH key pair (`.pem` file, `~/.ssh/sre-lab-key.pem`). How does SSH key-based authentication work? What is stored on EC2 (the public key) vs on WSL2 (the private key)? What happens if you lose the private key?

3. [Basic] What is a Security Group in AWS? NovaPay's EC2 needs to accept SSH (port 22) and HTTP traffic on ports 8080 and 8081. Write out the inbound rules you would set. What is the difference between a Security Group and a Network ACL?

4. [Applied] Connect to NovaPay: Ansible connects to EC2 via SSH using the key in `inventory.ini`. When Ansible runs `go build` with `delegate_to: localhost`, it runs on WSL2. When it runs `copy` or `systemd` tasks, it connects to EC2 over SSH. Describe what happens at the network layer during a full `ansible-playbook deploy.yml` run: which connections are opened, to where, carrying what?

5. [Applied] AWS billing can surprise you. A `t3.micro` runs 24/7 for a month at ~$8–10 USD. The NovaPay workflow includes "stop-vm" as the last step of every day. What is the difference between stopping and terminating an EC2 instance? What costs continue when an instance is stopped (hint: EBS volume)? What is a billing alarm, and how would you set one?

6. [Deep] EC2 instances run on AWS's physical hypervisor infrastructure. `t3` instances use the AWS Nitro System. What is a hypervisor, and what is the difference between Type 1 and Type 2? What does "t3 burstable" mean — how do CPU credits work, what happens when you run out, and why does this matter for a payments service under sustained load?

7. [Deep] NovaPay's Postgres runs locally on EC2 (not RDS). This is a deliberate deferral — RDS is Week 7. Explain the operational trade-offs: what does running Postgres on the same EC2 instance gain (cost, simplicity, latency)? What does it lose (failover, backups, Multi-AZ, parameter groups)? What would you need to change in `payment-api/main.go` and `deploy.yml` to move from local Postgres to RDS with zero downtime?

---

## Week 1 Synthesis Questions
*(Connect everything built this week into a coherent picture)*

1. [Applied] The NovaPay invariant (`sum(debits) == sum(credits)` per payment) held through all of Week 1 — 0 rows from the invariant query after D4 load test, D5 zombie test, D6 timeout test. Explain why each hardening property (bounded retry / goroutine lifecycle / context deadline) guarantees the invariant on its specific failure path. Where is the code that ensures a failed PSP call never opens a DB transaction?

2. [Applied] Trace a single charge through the full system: `curl → payment-api → callPSP → fake-psp → ledger write → response`. Name every Go construct involved (struct, goroutine, context, channel, error wrapping), every Linux concept involved (process, file descriptor, TCP connection, systemd), and every infrastructure piece involved (EC2, Postgres, Ansible). How many of these did you know on Day 1?

3. [Deep] The Week 1 hardening properties form a hierarchy. Bounded retry (D4) is the first line of defence against a flaky PSP. The goroutine lifecycle (D5) ensures in-process work doesn't leak. The context deadline (D6) ensures external calls can't hold resources indefinitely. What failure mode is NOT defended against yet — what would still bring down the service? (Hint: what happens if Postgres goes down? What happens if the EC2 disk fills up?)

---
*Difficulty guide: Basic = recall and understand, Applied = use in context, Deep = explain the why and the trade-offs*
*Week 1 complete. Next set covers Week 2: filesystems, disk, memory, log rotation, OOM killer.*
