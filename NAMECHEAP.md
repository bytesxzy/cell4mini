# Running CELL4 on Namecheap, within the terms

## The honest fit assessment, first

Namecheap shared hosting is sold to serve websites. Its Acceptable Use / Hosting
policy restricts using an account as a general compute resource, and the plans
are enforced with CloudLinux LVE limits (CPU %, entry processes, I/O) that kill
processes which exceed them.

CELL4 is a CPU-bound search. Measured on one core in this repository:

| profile | one generation |
| --- | --- |
| defaults (4 candidates, 3s / 3000 nodes, 60 ARC) | ~117 s |
| `CELL4_CANDIDATES=1 CELL4_SECONDS=2 CELL4_NODES=2000` | ~76 s |
| `CELL4_CANDIDATES=1 CELL4_SECONDS=1 CELL4_NODES=800` | **~10 s** |

Those are seconds of pure 100%-CPU work, and they grow as the regression suite
and ARC corpus grow. So there are two honest deployments, and **the second one
is the one to use**:

* **A. Everything on shared hosting** — only defensible in the heavily throttled
  profile, and only if Lua is actually available there. Section 2.
* **B. Split (recommended)** — the generation runs where compute is allowed
  (Replit scheduled deployment, a small VPS, your own machine); Namecheap serves
  the resulting static `live.json` and console. Namecheap is then doing exactly
  what you are paying it to do, and no policy question arises at all. Section 3.

Whichever you pick: **read the current Universal Terms of Service, the Hosting
Acceptable Use Policy, and the cron-frequency note in Namecheap's Knowledgebase
before scheduling anything.** They change, this document does not, and your
account is the one at risk. If anything below conflicts with what you read
there, the policy wins.

## What this program will not do to your host

These are properties of the code, not promises:

* One invocation runs exactly one generation and exits. There is no daemon, no
  supervisor, no sleep-and-repeat, no self-relaunch and no background process.
  `cell4.lua loop` exists only to refuse and exit 1.
* Two overlapping scheduled runs cannot both work: the second takes no CPU, it
  fails on the lock and exits 1 immediately.
* Every solver call is bounded by a node budget, a wall-clock budget and a VM
  instruction budget, so a single task cannot run away.
* Network use is a handful of `curl` calls, at most once every 90 minutes, each
  capped at 45 seconds.

## 1. Check whether Lua exists on the server

SSH in (cPanel → SSH Access; enable it if your plan offers it) and run:

    which luajit lua lua5.1 lua5.4; luajit -v 2>/dev/null; lua -v 2>/dev/null

Most Namecheap shared plans have **no Lua of any kind** — cPanel's application
manager offers PHP, Python, Ruby and Node, not Lua. If nothing is found, do not
start compiling or uploading a LuaJIT binary until you have checked whether your
plan's AUP permits running custom compiled binaries from the home directory; on
many shared plans that is either forbidden or blocked by a `noexec` mount. If it
is not clearly permitted, go to Section 3 instead. That is not a workaround, it
is the correct architecture.

## 2. Deployment A — everything on shared hosting (throttled)

Only if Section 1 found a working Lua and the AUP permits this workload.

**Upload.** Put `cell4.lua`, `run-once.sh` and `README.md` in a directory
**outside** `public_html`, e.g. `/home/USER/cell4/`. The `rsi/` state tree, the
lineage snapshots and the corpus have no business being web-readable.

    mkdir -p ~/cell4 && cd ~/cell4
    # upload cell4.lua and run-once.sh here (cPanel File Manager or SFTP)
    chmod +x run-once.sh

**Point the wrapper at the interpreter you actually found.** `run-once.sh` ends
with `exec luajit cell4.lua step`; change `luajit` to the path from Section 1 if
it differs.

**Set the throttle.** Add these above the `exec` line in `run-once.sh`:

    export CELL4_CANDIDATES=1        # one candidate per generation
    export CELL4_SECONDS=1           # per-task solver wall clock
    export CELL4_NODES=800           # per-task solver node budget
    export CELL4_EXTERNAL_CAP=20     # ARC tasks per generation

These lower how much work one invocation does. They do **not** touch the
acceptance rule — `alpha`, `bootstrap_reps`, the held-out split size and the
adversarial tolerance are deliberately not settable from the environment,
because lowering those would not make the system cheaper, it would make it start
accepting changes the evidence does not support.

**Cap it from the outside as well.** Belt and braces, in `run-once.sh`:

    exec nice -n 19 timeout 300 luajit cell4.lua step

`nice -n 19` means you yield the core to anything else on the box. `timeout 300`
means no invocation of yours can ever be the long-running process that trips a
limit; if it is killed it leaves a lock, which the next run clears after an hour
of silence, or `luajit cell4.lua unlock` clears immediately.

**First run by hand, and watch it.**

    cd ~/cell4 && ./run-once.sh

It should print one `generation N done:` line and exit. Then check `status`.

**Schedule it.** cPanel → Advanced → Cron Jobs. Check Namecheap's current
documented minimum interval first, then pick something far above it. Every 30
minutes is plenty — this system improves over days, not minutes, and a faster
cron mostly buys you lock contention:

    */30 * * * * /home/USER/cell4/run-once.sh >> /home/USER/cell4/cron.log 2>&1

At ~10 s of CPU every 30 minutes that is about a 0.6% duty cycle on one core.
Start there. If cPanel's resource usage page shows you anywhere near your CPU or
entry-process limits, lengthen the interval before you do anything else.

Set the cron email field to your address so failures reach you, and rotate
`cron.log` occasionally — it grows forever otherwise.

**Publish the output.** Symlink or copy just the derived files into the web root:

    ln -s /home/USER/cell4/live.json      /home/USER/public_html/live.json
    ln -s /home/USER/cell4/rsi/www/index.html /home/USER/public_html/cell4.html

Never expose `rsi/state/`, `rsi/genome/` or `rsi/versions/`.

## 3. Deployment B — split (recommended)

Namecheap serves static files. The generation runs somewhere compute is allowed.
No policy question, no throttle, no interpreter hunt.

**Where to run it.** A Replit Scheduled Deployment (`luajit cell4.lua step`, see
`.replit`), the cheapest VPS you can find, or a machine of your own. Anything
that can run one command on a timer.

**How the output gets to Namecheap.** `publish.sh` uploads the derived files
over FTPS and exits. Create `cell4.env` next to it (`chmod 600`, already in
`.gitignore`):

    CELL4_FTP_HOST=ftp.yourdomain.com
    CELL4_FTP_USER=cell4@yourdomain.com
    CELL4_FTP_PASS='the password'
    CELL4_FTP_DIR=/public_html/cell4

Make a dedicated FTP account in cPanel scoped to that one directory rather than
using your main account, so a leaked credential cannot touch the rest of the
site. Then the whole scheduled job is:

    ./run-once.sh && ./publish.sh

It uploads `live.json`, the console HTML and its two JSON feeds, plus
`JOURNAL.md` and `HISTORY.md`. `--ssl-reqd` is not optional in that script: plain
FTP would put the password on the wire in clear text on every run.

## 4. If something goes wrong

| symptom | cause | fix |
| --- | --- | --- |
| every run prints "another generation is already running" | a previous run was killed and left its lock | `luajit cell4.lua unlock` (it refuses while the lock still looks live; `unlock force` overrides) |
| every run says "refusing to run: persisted state exists at ..." | cron started somewhere other than the install directory | use `run-once.sh`, which does the `cd`; the message prints the exact command |
| stuck at generation 1 forever | same as above, on an older build | as above |
| `research: ... (9 fetch errors)` | the host blocks outbound HTTPS, or `curl` is missing | harmless — generations continue without new papers or ARC tasks. Fix by allowing outbound HTTPS, or download ARC task JSON into `rsi/data/arc/` yourself |
| the host kills the process partway | budget too high for the plan | lower `CELL4_SECONDS` / `CELL4_NODES` / `CELL4_CANDIDATES`, lengthen the cron interval, or move to Deployment B |
| held-out % jumped between generations | you changed the budget | expected: a budget change re-measures the champion and is logged. `live.json`'s `budget` field says which profile each generation ran under; generations at different budgets are not directly comparable |

## 5. What not to do

Do not run `cell4.lua loop` (it refuses, and that is the point). Do not wrap it
in `while true`, `nohup`, `screen`, `tmux` or `&`. Do not set a cron interval
shorter than a generation takes — you would only produce runs that fail on the
lock. Do not try to keep a process alive between generations: the entire design
puts the system's memory on disk precisely so that it does not need to.
