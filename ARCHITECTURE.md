# CELL4 — compiler architecture

## Where the source came from

`source/main.lua` was not in the working tree. It was inside `source (2).zip`,
uploaded on 11 Jan 2026 and deleted four minutes later, and survived only as a
loose object in git history:

```
git cat-file -p 42383712cd1495bb5fc0d278d83401dafe0eb44d > source2.zip
```

It is now restored at `source/main.lua`, byte-identical (43,547 bytes,
md5 `a7119ff974a70a763080c53ac049e632`). The zip also held `source/execute.lua`
(0 bytes — a build output) and copies of the site's HTML and images.

Everything below was measured by running that file under Lua 5.4 before any of
the new code was written. Nothing here is inferred from reading it.

## What the program does

`main.lua` is a transpiler. It reads a keyword file named `CELL2` and writes
two outputs from it:

```
CELL2 ──pass 1 (loop headers)──┐
CELL2 ──pass 2 (backend)───────┼──> source/execute.lua   Lua
CELL2 ──pass 3 (frontend)──────┴──> source/testing.html  HTML
                                    then: os.execute("luajit source/execute.lua")
```

The part worth calling reasoning is how it decides what a line means. That
decision is a tree of `if line:upper():find("<PRINT>") and not
line:upper():find("<LUA>") ...` branches about nine levels deep, with an
`Anti_mixup` boolean threaded through the print/write subtree to stop two
branches firing on the same line.

## Verified defects

Each of these was reproduced against `source/main.lua`, and each now has a
test in `spec/test_regression.lua`.

### 1. Sequential blocks compile to nested ones

Pass 1 walks the whole file emitting a `while` header for every `<REVIVE>`;
pass 2 then emits all the bodies. Input:

```
<REVIVE>            <REVIVE>
<PRINT> loop one    <PRINT> loop two
<DONE>              <DONE>
```

Output — the second loop is inside the first, and `loop two` runs in the wrong
scope:

```lua
while true do
while true do
print('loop one body')
end
print('loop two body')
end
```

### 2. `<ELSE>` does nothing

`local elses = [[<ELSE>]]` is declared on line 13 and stripped by every gsub
chain in the file, but no branch ever emits `else`. So an if/else compiles with
both arms unconditionally inside the `if`:

```lua
if  1 == 2 then
print('yes')
print('no')     -- runs whenever the branch is taken; never when it isn't
end
```

This is the worst of the set because it is silent and the output still parses.

### 3. Frontend output escapes the document

The HTML pass calls `io.open(UIDirectory,"a")` 13 times and `:close()` 5 times
in the whole file. The unclosed handles flush when the collector reaches them,
which is after the document terminator has been written. `FILL: #000000
POSITION: center` produced:

```html
<!DOCTYPE html>...<body></body></html>text-align:center;'><body style='background-color:#000000 POSITION: center;'>
```

Three faults visible at once: content after `</html>`, a `text-align` fragment
with no opening tag, and `POSITION: center` left inside a CSS value because the
`FILL:` branch only stripped `FILL:`.

### 4. `and` binds tighter than `or`

Line 741 reads:

```lua
if Translation:find(align) or Translation:find(color) and not Translation:find(linkframe) and not ... then
```

Lua parses that as `find(align) or (find(color) and not ...)`, so every guard
after the `or` applies only to the `color` half. A line containing `POSITION:`
enters the branch no matter what else is on it. The same shape appears on lines
237, 250, 255, 262, 273, 278 and 363.

### 5. The trim never happens

`FP1:match("^%s*(.-)%s*$")` is called 16 times with its return value discarded —
`match` does not mutate. `<LOCAL> <STRING> hello world` compiled to a literal
with the leading blanks still in it.

### 6. One declaration, two statements

The same input also emitted the declaration twice, because the `<STRING>`
branch fires in addition to the `<LOCAL>` branch:

```lua
local ___1 = [[  hello world]]
___1 =[[  hello world]]
```

### 7. Variables are named after line numbers

`RFLevel` increments once per source line, so the fourth line's declaration is
`___4`. Inserting a blank line above renames every variable below it.

### 8. Classification by character presence

`if Translation:find("1") or Translation:find("2") or ...` decides whether a
payload is numeric, so `level 2 complete` is a number. `find("+") or find("-")`
decides whether it is arithmetic, so any hyphenated word is an expression and
reaches the output unquoted, where it stops the generated file from parsing.

### 9. Smaller ones

- `local string = [[<STRING>]]` (line 9) shadows the `string` library.
- `io.popen('dir /b *.html')` (line 444) is opened for reading and then
  written to, and `dir /b` is a Windows command.
- `FP1:gsub(line,"")` uses the source line as a *pattern*, so magic characters
  in it change the match.
- `scrolling="no""` (line 735) emits a stray quote.
- The `WORLD:` handler builds two `FBXLoader`s and adds the model twice.
- `class='img-left'` and friends are emitted but no stylesheet defines them.
- `io.open(UIDirectory,"w"):write(""):close()` (line 49) has no nil check.
- The file ends with an unconditional `os.execute("luajit source/execute.lua")`,
  so a mis-parse immediately runs its own output.

## The new pipeline

```
CELL source
  │
  ├─ lexer.lua       one left-to-right scan; each keyword owns the text after it
  ├─ rules.lua       one row per possible meaning (requires / forbids / bonus)
  ├─ resolver.lua    scores every applicable row, picks the best, reports margin
  ├─ parser.lua      block stack + symbol table -> one tree
  │
  ├─ emit_lua.lua ──> Lua
  └─ emit_html.lua ─> HTML
```

The two emitters read the same tree, so the three-passes-over-the-file
ordering problem cannot recur.

### The resolver is the part that replaces "reasoning"

A rule declares what it needs rather than being guarded by hand:

```lua
{
  id = "local_random",
  requires = { "LOCAL", "GUESS" },
  forbids  = { "READ", "STATE" },
  build    = function(s) ... end,
}
```

Score is `10 × #requires + 2 × #prefers_present + bonus + priority`. Three
properties follow, none of which the original had:

- **Specificity decides, not source order.** `<LOCAL> <GUESS>` scores 20 and
  `<LOCAL>` scores 10, so the specific rule wins without anyone sequencing the
  branches. `spec/test_resolver.lua` reverses the entire rule table and asserts
  the answer is unchanged.
- **Adding a keyword is adding a row.** In the original, a new keyword needed a
  new `and not Translation:find(...)` clause in every earlier branch.
- **The pick is inspectable.** Confidence is the margin over the runner-up,
  `(top − second) / top`. A tie is reported as an ambiguity warning; a thin
  margin is reported as a note.

```
$ lua cell4c.lua --explain '<PRINT> well-known problem'
tokens:     PRINT=well-known problem
winner:     print_text (confidence 0.50)
candidates:
  print_text          10
  print_expr           5
```

Evidence has to cut both ways for this to work. `print_expr` first returned a
bonus of 0 for prose, which left it tied with `print_text` at 10; the tie-break
then sent every message down the arithmetic path and emitted
`print(starting up)`, which does not parse. It now returns −5 for prose. The
test suite caught that, not review.

### Structure and symbols

`parser.lua` keeps a stack: an opener pushes, `<DONE>` pops, statements attach
to the top frame. `<ELSE>` moves the current frame's target from `body` to
`orelse`, which is what makes the keyword exist at all. An unclosed block is an
error naming the line that opened it, instead of a counter silently reshaping
the nesting.

Variable slots are allocated in declaration order, so the first declaration is
`___1` wherever it sits in the file.

### Diagnostics

There was no diagnostic channel before; an unclassifiable line produced no
output and no message. Now:

```
$ lua cell4c.lua broken.cell
line 1: error: block opened here is never closed; add <DONE>
line 3: error: no file is open here; <CREATE> must come before <STATE>/<READ>/<CLOSE>
line 4: warning: ___9 is not declared (nothing has been declared yet)
cell4c: 2 error(s); nothing written
```

Errors mean nothing is written. The original always wrote something.

### Deliberate behaviour changes

Not everything is bug-for-bug compatible. These are the intentional
differences:

| Was | Now | Why |
|---|---|---|
| runs `luajit source/execute.lua` on every compile | `--run` opt-in | a mis-parse ran itself |
| `___<line number>` | `___<declaration order>` | editing above a variable renamed it |
| `[[ ]]` literals | `%q` literals | payloads containing `]]` or quotes broke the output |
| any digit ⇒ numeric | `tonumber(payload)` | `level 2 complete` was numeric |
| any `+`/`-` ⇒ arithmetic | expression *shape* | hyphenated words reached output unquoted |
| second `<body>` mid-document | `FILL:` sets the body attribute | one body per document |
| style fragments, unbalanced | spans opened and always closed | output is balanced whatever the input |
| payloads interpolated into markup | text escaped; `HTML:` still raw | a `<` in a caption truncated the page |
| `<SLEEP>` text passed to a shell | must be numeric, else an error | `<SLEEP> ; rm -rf /` built that command |
| `<FUNCTION>` opened, never closed | opens a block `<DONE>` closes | generated functions did not close |
| bare word `function` triggered | `<FUNCTION>` keyword | the word in a message triggered it |

Generated code stays Lua 5.1-compatible so LuaJIT still runs it.

## Running it

```bash
lua cell4c.lua                          # compile ./CELL2
lua cell4c.lua path/to/src              # compile that file
lua cell4c.lua --check                  # diagnostics only, write nothing
lua cell4c.lua --explain '<PRINT> hi'   # show how one line is understood
lua cell4c.lua --run                    # compile, then run the generated Lua
lua spec/run.lua                        # 58 tests, no dependencies
```

`source/main.lua` is untouched and still runs, so the two can be compared on
the same input.

## State, and what is not done

Done: lexer, rule table, resolver, parser, both emitters, diagnostics, CLI,
58 tests. Every defect listed above is fixed and pinned by a test.

Not done, roughly in the order I would take it:

1. **Keyword coverage.** `<BASKET>`, `<READ>` and `<FUNCTION>` are implemented
   thinly. `AUPD:`, `CHARACTER:` and `BRACKET:`'s original span semantics are
   not carried over — `AUPD:` was broken in the original (`io.popen` opened for
   read, written to) so there is no working behaviour to preserve, and I did
   not want to invent one.
2. **Expressions.** Conditions and `for` headers are still passed through as
   raw text. Parsing them would let `<WELL>` report a malformed condition
   instead of handing it to the Lua parser.
3. **Multi-slot references.** Only `___N` resolves. The original's `____`
   four-underscore guard suggests a second namespace whose intent I could not
   determine from the code; it needs a decision rather than a guess.
4. **Scope.** The symbol table is flat. Declarations inside a block are visible
   after it, which matches the original but is not right.
5. **A real corpus.** The strongest thing missing is the actual `CELL2` file
   the portfolio was built from. Compiling it with both compilers and diffing
   the output is the check that matters, and I do not have it.

### On item 5

`CELL2` is not in the repo or in the zip. If you have it, dropping it in makes
every claim here checkable against the site that was actually shipped, and it
becomes the regression corpus for the rest of the work.
