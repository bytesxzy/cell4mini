# Installing and running CELL4 in a folder on your own machine or web host

This is pure Lua. There is nothing to compile, no package manager, no C module, no service to sign up
for. You need one binary — the Lua interpreter — and a folder.

Everything below assumes you unzipped the archive into a folder called `cell4`.

---

## 1. Install Lua

### Windows

Everything works on native Windows — the OS calls the loop makes (create a directory, delete a tree,
list a directory, sleep) go through `rsi/kernel/plat.lua`, which uses the cmd.exe equivalent when it
detects Windows. It was POSIX-only until this was written, so if you are looking at an older copy,
run it under WSL instead.

The simplest working route, in order of preference:

**a. winget (Windows 10/11, nothing else needed)**

```
winget install DEVCOM.Lua
```

Close and reopen the terminal, then check:

```
lua -v
```

You want `Lua 5.4.x`. Lua 5.3 works. Lua 5.1 and 5.2 are untested — the code avoids 5.3+ syntax
deliberately (there is no `//`, no bitwise operator and no `table.move` anywhere in it, which is what
makes LuaJIT work), so they may well run it, but nothing here has been measured on them.

**b. LuaBinaries (no installer, just a folder)**

Download `lua-5.4.x_Win64_bin.zip` from <https://luabinaries.sourceforge.net/download.html>, unzip it
to `C:\lua`, then add `C:\lua` to your PATH:

```
setx PATH "%PATH%;C:\lua"
```

The binary there is called `lua54.exe`. Either rename it to `lua.exe` or type `lua54` everywhere this
guide says `lua`.

**c. LuaJIT (faster, optional)**

<https://luajit.org/download.html>, or `winget install LuaJIT.LuaJIT`. The code deliberately avoids
syntax LuaJIT does not have, so `luajit run.lua step` works identically and is roughly 2–4× faster on
the search. If you have it, use it — the search is the bottleneck and nothing else changes.

### macOS

```
brew install lua        # or: brew install luajit
```

### Linux (including most shared web hosts with SSH)

```
sudo apt install lua5.4        # Debian / Ubuntu
sudo dnf install lua           # Fedora
sudo pacman -S lua             # Arch
```

On Debian/Ubuntu the binary is `lua5.4`, not `lua`. Either use that name or:

```
sudo ln -s /usr/bin/lua5.4 /usr/local/bin/lua
```

**No root on your host?** Build it into your home directory; it takes about thirty seconds and has no
dependencies beyond a C compiler:

```
curl -R -O https://www.lua.org/ftp/lua-5.4.7.tar.gz
tar zxf lua-5.4.7.tar.gz && cd lua-5.4.7
make linux && make local
# binary is now at ~/lua-5.4.7/install/bin/lua
export PATH="$HOME/lua-5.4.7/install/bin:$PATH"
```

### Also useful, but not required

* **curl** — the research fetcher shells out to it to pull ARC tasks and arXiv abstracts. Windows 10
  build 1803 and later already have it; on Linux `sudo apt install curl`. Without it the loop runs
  fine and simply never fetches anything; the external ARC score stays `0/0`.
* **python3** — only to serve the two HTML pages locally. If the folder is already inside a web
  server's document root you do not need it.

---

## 2. Unzip it into place

```
cd /path/to/your/webroot
unzip cell4.zip           # creates cell4/
cd cell4
lua run.lua selftest
```

`selftest` takes a few seconds and should end with:

```
selftest OK: ARC-format loading, solving, held-out verification and the narrator's accuracy guard all work
```

If that passes, the interpreter and every module path are correct. **Always run commands from the
`cell4` folder itself** — module paths are relative (`require("rsi.kernel.cycle")` resolves against
the working directory), so `lua cell4/run.lua step` from one level up will not find anything.

---

## 3. The settings you might actually want to change

All of them are in `rsi/config.lua`, and every one is safe to change between generations.

| setting | default | change it when |
|---|---|---|
| `heldout_per_family` | 20 | Lower to 10 to make a generation ~2× faster. Costs statistical power: the acceptance rule needs a large held-out split precisely so the threshold can stay strict. |
| `candidates_per_gen` | 4 | Lower to 2 on a slow box. Fewer shots per generation, not worse ones. |
| `nodes` / `seconds` | 3000 / 3 | The per-task search budget. Raising `nodes` raises the solve rate but makes every measurement slower and is **not** an improvement to the system — the lineage records the budget so scores stay comparable. |
| `research_interval` | 5400 (1.5h) | How often it goes out to the internet. Set very high to run fully offline. |
| `loop_sleep` | passed on the CLI | `lua run.lua loop 20` = wait 20 seconds between generations. |

You do **not** need to change anything to get it running. The defaults are what the numbers in the
README were measured with.

---

## 4. Keep it running

**Foreground (a terminal you leave open):**

```
lua run.lua loop 20
```

**Linux/macOS, detached, survives logout:**

```
nohup lua run.lua loop 60 >> cell4.log 2>&1 &
```

**Linux with systemd (a real always-on service):**

```ini
# /etc/systemd/system/cell4.service
[Unit]
Description=CELL4 self-improvement loop
After=network.target

[Service]
Type=simple
User=YOURUSER
WorkingDirectory=/path/to/webroot/cell4
ExecStart=/usr/bin/lua5.4 run.lua loop 60
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl enable --now cell4
journalctl -u cell4 -f
```

**Windows, in the background:** create a shortcut or a `.bat`:

```bat
cd /d C:\webroot\cell4
lua run.lua loop 60
```

and register it with Task Scheduler, trigger "At startup", action "Start a program", pointing at the
`.bat`. Tick "Run whether user is logged on or not" — the between-generation wait uses `ping -n`
rather than `timeout /t`, precisely because `timeout` fails when stdin is redirected, which is what
happens to a scheduled task.

**Cron, if you would rather it ran a generation on a schedule than in a loop:**

```
*/30 * * * * cd /path/to/webroot/cell4 && /usr/bin/lua5.4 run.lua step >> cell4.log 2>&1
```

That is safe even if a generation overruns: `rsi/state/.lock` is an atomic `mkdir`, so a second
`step` refuses to start rather than interleaving writes. The lock is broken automatically after 30
minutes in case a process is killed mid-generation.

---

## 5. Seeing it, in a browser

Two pages live in `rsi/www/`:

| page | what it is |
|---|---|
| `plain.html` | **Undesigned on purpose.** Every number the system knows, in plain HTML tables in reading order, plus what the language model wrote. This is the one to use if you want to see everything. |
| `index.html` | The styled console — the same data, arranged. |

Both are static files that poll `state.json`, `progress.json`, `lineage.jsonl` and `narrative.jsonl`
sitting beside them. There is no server-side code, so anywhere that can serve a file will serve these.

**Already on a web host:** if `cell4` is inside your document root, the page is at
`https://yoursite/cell4/rsi/www/plain.html` and there is nothing more to do. To put it at a tidier
address, symlink or copy the `rsi/www` folder:

```
ln -s /path/to/webroot/cell4/rsi/www /path/to/webroot/cell4-console
```

**Locally, no web host:**

```
cd rsi/www && python3 -m http.server 8080
```

then open <http://localhost:8080/plain.html>. Opening the file directly with `file://` will **not**
work — the pages `fetch()` the JSON beside them and browsers block that on `file://`.

### If you are putting this on a public site

`rsi/www/` is the only directory meant to be reachable. The rest of the folder is state, source and
your own run's data. The pages already carry `<meta name="robots" content="noindex,nofollow">`, but
that is a request, not a control. To actually restrict it under Apache, drop this in `cell4/.htaccess`:

```apache
Require all denied
<FilesMatch "\.(html|json|jsonl)$">
  Require all granted
</FilesMatch>
```

or serve only `rsi/www` and keep the rest of the folder outside the document root entirely. Under
nginx, `location /cell4/ { deny all; }` with a separate `location /cell4/rsi/www/` block.

---

## 6. The language model, and its dataset

`rsi/lm/markov.lua` is an n-gram Markov language model: it counts `P(word | previous words)` on
`rsi/lm/corpus.txt` and generates by sampling that distribution with backoff and temperature. It is
seeded from `os.time()` mixed with `os.clock()` and the generation number, and the seed is recorded,
so the wording differs every run but any run can be reproduced exactly.

```
lua run.lua lm                # model statistics, and the check that the vocabulary has no numerals
lua run.lua lm standing       # sample five sentences on one topic
lua run.lua narrate 0.05      # replay the last generation's account, typed out
lua run.lua history           # the whole narrated history
```

**Its vocabulary contains no digits.** A Markov chain has no idea what is true and will produce a
fluent falsehood without hesitating, so it is not allowed to produce numbers at all: every quantity
arrives through a `{slot}` filled from audited measurements after the sentence is sampled, and any
sentence whose numerals do not match the facts is thrown away and re-drawn. If no sample passes
verification, a deterministic template writes that sentence and the page labels it `[template]`.

The shipped corpus is a seed of ~80 lines, which is enough to work but small enough that the chain
often reproduces a whole training line. **`DATASET_PROMPT.md` is a ready-made prompt for Grok** (or
anything else) that will write you 400–1000 more. Paste it in, append the result to
`rsi/lm/corpus.txt`, and run `lua run.lua lm` — it prints every line it rejected and why. Growing the
corpus changes only fluency; the accuracy guarantee comes from the slot mechanism, not the data.

---

## 7. Troubleshooting

| symptom | cause |
|---|---|
| `module 'rsi.kernel.cycle' not found` | You are not in the `cell4` folder. `cd` into it. |
| `attempt to call a nil value (field 'move')` | Lua 5.1 or 5.2. Install 5.4, or LuaJIT. |
| `lua: not found` on Debian/Ubuntu | The binary is `lua5.4`. Symlink it, or use that name. |
| The page says `state.json unavailable` | The loop has not finished a generation yet, or you opened the file over `file://` instead of through a server. |
| `ARC 0/0` forever | No outbound HTTPS, or no `curl`. Everything else still works; run `lua run.lua research` to see the error. |
| A generation refuses to start | `rsi/state/.lock` exists because another one is running. If nothing is running, `rmdir rsi/state/.lock`. |
| Scores dropped to zero after a reset | Deleting `rsi/state` regenerates the secret held-out salt, so the tasks are different ones. Scores before and after a reset are not comparable, by design. |

Deleting `rsi/state`, `rsi/versions` and `rsi/data` resets the run completely. Nothing else is
generated, so the folder can be re-zipped and moved anywhere.

---

## 8. Verifying it is doing what this says

```
lua run.lua selftest
```

checks three separate things and exits non-zero if any of them fails:

1. Two ARC-format tasks are written to a scratch directory, loaded through the same code path the
   real fetcher feeds, solved, and verified on their held-out test example.
2. A summary field is deliberately set to `9999`; the narration must catch it by recomputing from the
   per-task vector and keep the false number out of the text.
3. The language model is sampled sixty times against deliberately incomplete facts; no numeral the
   facts do not contain may reach the prose, and its vocabulary must contain zero numerals.

None of that is a claim about the system — it is the system checking itself, and you can read the
checks in `run.lua`.
