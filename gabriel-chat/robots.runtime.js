/* robots.html runtime — retrieval, live reading, and on-page learning.
 *
 * Everything here runs in the visitor's browser. No API key, no inference
 * server, no third-party model: the weights below were trained by
 * build_brain.py with gabriel.lm.GabrielLM, the same sparse log-linear model
 * the ARC engine reasons with, and this file runs the same softmax over them.
 */
(function () {
  "use strict";

  var B = window.ROBOTS_BRAIN;
  var CFG = window.ROBOTS_CONFIG || {};
  var LS_KEY = "robots.lm.v1";
  var LS_CACHE = "robots.live.v1";
  var LIVE_TTL = 6 * 3600 * 1000;

  /* Directories this page reads live, same origin only. The architecture
     notes and source files live under /astron/xyz/, so that is the default. */
  var SOURCES = CFG.sources || ["/astron/xyz/"];
  var READABLE = /\.(md|markdown|txt|py|js|mjs|json|html?|css|ya?ml|toml|cfg|ini|sh)$/i;

  var $ = function (s) { return document.querySelector(s); };
  var log = $("#log"), chips = $("#chips"), statusEl = $("#status"),
      panel = $("#panel"), input = $("#q"), sub = $("#sub");

  /* ------------------------------------------------------------ tokenising */
  var STOP = {};
  ((B && B.stop) || []).forEach(function (w) { STOP[w] = 1; });

  function tok(s) {
    var out = [], m = String(s || "").toLowerCase().match(/[a-z0-9][a-z0-9'+#._-]*/g) || [];
    for (var i = 0; i < m.length; i++) {
      var w = m[i].replace(/[._-]+$/, "");
      if (w.length > 1 && !STOP[w]) out.push(w);
    }
    return out;
  }

  /* Words sharing a four-character stem are the same evidence: "worked" has to
     reach "work", "pricing" has to reach "price". A prefix test does that
     without a stemmer that would have to stay identical in two languages. */
  function related(a, b) {
    if (a === b) return true;
    var n = Math.min(a.length, b.length);
    return n >= 4 && a.slice(0, n) === b.slice(0, n) && Math.abs(a.length - b.length) <= 4;
  }

  /* ---------------------------------------------------------------- model */
  function Brain(d) {
    this.d = d || {};
    this.passages = (this.d.passages || []).slice();
    this.docs = (this.d.tokens || []).map(function (s) { return s.split(" "); });
    this.idf = Object.assign({}, this.d.idf || {});
    this.avgdl = this.d.avgdl || 14;
    this.lm = (this.d.lm && this.d.lm.vocab) ? this.d.lm : null;
    this.deltas = {};                       /* learned on this device */
    this._cache = {};
  }

  Brain.prototype.reindex = function () {
    var df = {}, n = this.passages.length, total = 0, i, j;
    this.docs = this.passages.map(function (p) {
      return tok(p.h + " " + p.t);
    });
    for (i = 0; i < this.docs.length; i++) {
      total += this.docs[i].length;
      var seen = {};
      for (j = 0; j < this.docs[i].length; j++) seen[this.docs[i][j]] = 1;
      for (var w in seen) df[w] = (df[w] || 0) + 1;
    }
    this.idf = {};
    for (var t in df) this.idf[t] = Math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5));
    this.avgdl = total / Math.max(1, n);
    this._cache = {};
  };

  /* One document model per passage: the trained bias row, that passage's
     heading rows, and whatever this browser has since learned. */
  Brain.prototype.docDist = function (i) {
    if (this._cache[i]) return this._cache[i];
    if (!this.lm) return null;
    var feats = ["b"].concat(this.passages[i].g || []), v = this.lm.vocab;
    var acc = Object.create(null), k, f, row, t;
    for (k = 0; k < v.length; k++) acc[v[k]] = 0;
    for (k = 0; k < feats.length; k++) {
      f = feats[k];
      row = this.lm.w[f];
      if (row) for (t in row) if (t in acc) acc[t] += row[t];
      row = this.deltas[f];
      if (row) for (t in row) if (t in acc) acc[t] += row[t];
    }
    var peak = -Infinity;
    for (k = 0; k < v.length; k++) if (acc[v[k]] > peak) peak = acc[v[k]];
    var z = 0, out = Object.create(null);
    for (k = 0; k < v.length; k++) { out[v[k]] = Math.exp(acc[v[k]] - peak); z += out[v[k]]; }
    for (k = 0; k < v.length; k++) out[v[k]] /= z;
    this._cache[i] = out;
    return out;
  };

  Brain.prototype.vocabForm = function (w) {
    if (!this.lm) return null;
    if (this.lm.unigram[w] != null) return w;
    var v = this.lm.vocab;
    for (var i = 0; i < v.length; i++) if (related(w, v[i])) return v[i];
    return null;
  };

  /* Query likelihood: how probable are the question's words under this
     passage's own model? The classic language-model approach to retrieval. */
  Brain.prototype.ql = function (i, q) {
    var d = this.docDist(i);
    if (!d) return 0;
    var seen = 0, total = 0, w;
    for (var k = 0; k < q.length; k++) {
      w = this.vocabForm(q[k]);
      if (w && w in d) { total += Math.log(Math.max(d[w], 1e-9)); seen++; }
    }
    if (!seen) return 0;
    return (total / seen + Math.log(this.lm.vocab.length)) * 0.9;
  };

  Brain.prototype.bm25 = function (i, q) {
    var doc = this.docs[i] || [], k1 = 1.4, b = 0.72, score = 0, tf = Object.create(null), j, t;
    if (!doc.length) return 0;
    for (j = 0; j < doc.length; j++) tf[doc[j]] = (tf[doc[j]] || 0) + 1;
    for (j = 0; j < q.length; j++) {
      var f = tf[q[j]] || 0, key = q[j], disc = 1;
      if (!f) for (t in tf) if (related(q[j], t)) { f = tf[t]; key = t; disc = .75; break; }
      if (!f) continue;
      score += disc * (this.idf[key] || 0.4) * (f * (k1 + 1)) /
               (f + k1 * (1 - b + b * doc.length / this.avgdl));
    }
    return score;
  };

  Brain.prototype.expand = function (q) {
    var al = this.d.aliases || {}, out = q.slice(), i, j;
    for (i = 0; i < q.length; i++) {
      var add = al[q[i]];
      if (add) for (j = 0; j < add.length; j++) if (out.indexOf(add[j]) < 0) out.push(add[j]);
    }
    return out;
  };

  Brain.prototype.rank = function (question) {
    var asked = tok(question);
    if (!asked.length) return [];
    var q = this.expand(asked), out = [], i, j;
    for (i = 0; i < this.passages.length; i++) {
      var p = this.passages[i], lex = this.bm25(i, q), lm = this.ql(i, q);
      var head = tok(p.h), boost = 0;
      /* Only where a heading is a heading. On a page that makes whole
         paragraphs headings, an uncapped bonus makes the longest passage the
         answer to everything. */
      if (head.length && head.length <= 12) {
        for (j = 0; j < q.length; j++) if (head.indexOf(q[j]) >= 0) boost += 0.8;
        boost = Math.min(boost, 1.6);
        /* "What does CELL4 do?" is one word once the stop list has had it, and
           term frequency then hands the question to whichever passage repeats
           that word most -- usually the page chrome. A heading that covers the
           whole question is the stronger signal, and a section named for what
           was asked should win. */
        if (asked.length && asked.every(function (w) {
              return head.some(function (h) { return related(w, h); });
            })) boost += 1.4;
      }
      out.push({ i: i, p: p, lex: lex, lm: lm, score: lex + 0.55 * lm + boost });
    }
    out.sort(function (a, b) { return b.score - a.score; });
    /* Nothing shares a word with the question -> say so, rather than handing
       back whichever passage the priors happened to like. */
    return out.filter(function (s) { return s.lex > 0.3 && s.score > 0.6; });
  };

  /* --------------------------------------------------------------- answers */
  function sentences(t) {
    return String(t).split(/(?<=[.!?:])\s+/).filter(function (s) { return s.trim().length > 2; });
  }

  function clamp(s, n) {
    if (s.length <= n) return s;
    var cut = s.slice(0, n);
    return cut.slice(0, cut.lastIndexOf(" ")) + "…";
  }

  function best(text, q, limit) {
    var ss = sentences(text);
    if (ss.length <= limit) return ss.join(" ");
    var sc = ss.map(function (s, i) {
      var t = tok(s), hit = 0;
      for (var j = 0; j < q.length; j++) {
        for (var k = 0; k < t.length; k++) if (related(q[j], t[k])) { hit++; break; }
      }
      return { s: s, i: i, hit: hit };
    });
    sc.sort(function (a, b) { return b.hit - a.hit || a.i - b.i; });
    return sc.slice(0, limit).sort(function (a, b) { return a.i - b.i; })
             .map(function (x) { return x.s; }).join(" ");
  }

  var SMALL = [
    [/^(hi|hey|hello|yo|sup|hola|gm)\b/i,
     "Hey. Ask me anything about CELL4 — what the agency does, the work, robots.js, the community, or how to get in touch."],
    [/\b(thanks|thank you|ty|appreciate)\b/i, "Anytime."],
    [/\b(bye|goodbye|cya|see ya)\b/i, "See you."],
    [/\b(who|what) (are|r) (you|u)\b/i,
     "robots.html — a small assistant that reads this site and answers out of it. I run entirely in your browser and I learn from the questions people ask me."],
    [/\b(are you (chat)?gpt|are you claude|are you ai|which model|what model|openai)\b/i,
     "No hosted model and no API. I am a sparse log-linear language model trained on this site's own text — the same model class the CELL4 ARC engine reasons with — running locally in this page."],
    [/\b(help|what can you (do|answer))\b/i,
     "Try: what does CELL4 do · what is robots.js · who is on the team · how do I join the community · how do I get in touch."]
  ];

  function answer(question) {
    for (var i = 0; i < SMALL.length; i++) {
      if (SMALL[i][0].test(question.trim())) return { text: SMALL[i][1], sources: [] };
    }
    var q = tok(question), hits = brain.rank(question);
    if (!hits.length) {
      return { text: "I could not find that on this site. I only answer from what is actually published here — try what CELL4 does, the proof of work, robots.js, the community, or contact.",
               sources: [] };
    }
    var top = hits[0], body = best(top.p.t, q, 3);
    if (body.split(/\s+/).length < 8 && hits[1]) {
      var more = best(hits[1].p.t, q, 2);
      if (more && more.toLowerCase().indexOf(body.toLowerCase()) < 0) {
        return { text: clamp(more, 460), sources: [hits[1].p.s, top.p.s], hit: hits[1] };
      }
    }
    var h = (top.p.h || "").replace(/[:\s]+$/, "");
    var lead = (h && h.split(/\s+/).length <= 10 &&
                body.toLowerCase().indexOf(h.toLowerCase()) !== 0) ? h + " — " : "";
    var out = { text: clamp(lead + body, 460), sources: [top.p.s], hit: top };
    if (hits[1] && hits[1].score > top.score * 0.62) {
      var alt = best(hits[1].p.t, q, 1);
      if (alt && alt.length > 14 && out.text.indexOf(alt.slice(0, 22)) < 0) {
        out.also = clamp(alt, 220);
        out.sources.push(hits[1].p.s);
      }
    }
    return out;
  }

  /* ------------------------------------------------------- self-improvement
   * Every answered question is a labelled example: these words went with that
   * passage. The page takes a gradient step on the passage's own rows of the
   * language model, and keeps it only if a held-out set of earlier questions
   * is still ranked at least as well. That is the same rule the ARC engine
   * lives by -- a change has to earn its place against the version it
   * replaces -- with mean reciprocal rank standing in for the sign test.
   *
   * The weights learned here stay in this browser. `robots.export()` writes
   * them out so they can be folded back into the trained model.
   */
  function Learner(brain) {
    this.b = brain;
    this.hist = [];        /* [{q, passage}] recent, for the gate */
    this.events = [];      /* adopted / rejected, for the status line */
    this.load();
  }

  Learner.prototype.load = function () {
    try {
      var s = JSON.parse(localStorage.getItem(LS_KEY) || "{}");
      this.b.deltas = s.deltas || {};
      this.hist = s.hist || [];
      this.events = s.events || [];
      this.b._cache = {};
    } catch (e) { /* private mode, cleared storage: start fresh */ }
  };

  Learner.prototype.save = function () {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify({
        deltas: this.b.deltas, hist: this.hist.slice(-40), events: this.events.slice(-30)
      }));
    } catch (e) {}
  };

  /* Mean reciprocal rank of the remembered (question -> passage) pairs. */
  Learner.prototype.mrr = function () {
    if (!this.hist.length) return 1;
    var total = 0;
    for (var i = 0; i < this.hist.length; i++) {
      var h = this.hist[i], r = this.b.rank(h.q), place = 0;
      for (var j = 0; j < r.length; j++) {
        if (r[j].p.key === h.key) { place = j + 1; break; }
      }
      total += place ? 1 / place : 0;
    }
    return total / this.hist.length;
  };

  Learner.prototype.step = function (question, hit, sign) {
    if (!hit || !this.b.lm) return null;
    var rows = (hit.p.g || []).filter(function (f) { return f.indexOf("s|") === 0; });
    if (!rows.length) return null;              /* nothing document-specific to move */
    var q = tok(question).map(this.b.vocabForm, this.b).filter(Boolean);
    if (!q.length) return null;

    var before = this.mrr();
    var backup = JSON.stringify(this.b.deltas);
    var d = this.b.docDist(hit.i), lr = 0.25 * sign, v = this.b.lm.vocab;
    var target = Object.create(null), i, t, f;
    for (i = 0; i < q.length; i++) target[q[i]] = 1 / q.length;

    for (i = 0; i < v.length; i++) {
      t = v[i];
      var g = (d[t] || 0) - (target[t] || 0);
      if (Math.abs(g) < 1e-4) continue;
      for (var k = 0; k < rows.length; k++) {
        f = rows[k];
        var row = this.b.deltas[f] || (this.b.deltas[f] = {});
        var nv = (row[t] || 0) - lr * g;
        row[t] = Math.max(-1.5, Math.min(1.5, nv));   /* clipped: no runaway */
      }
    }
    this.b._cache = {};

    var key = hit.p.key;
    if (sign > 0 && !this.hist.some(function (h) { return h.q === question; })) {
      this.hist.push({ q: question, key: key });
      if (this.hist.length > 40) this.hist.shift();
    }
    var after = this.mrr();
    var adopted = after >= before - 1e-9;
    if (!adopted) {
      this.b.deltas = JSON.parse(backup);        /* the gate said no */
      this.b._cache = {};
    }
    this.events.push({ t: Date.now(), adopted: adopted,
                       before: +before.toFixed(3), after: +after.toFixed(3) });
    if (this.events.length > 30) this.events.shift();
    this.save();
    return { adopted: adopted, before: before, after: after };
  };

  Learner.prototype.summary = function () {
    var a = 0;
    for (var i = 0; i < this.events.length; i++) if (this.events[i].adopted) a++;
    return { rounds: this.events.length, adopted: a,
             weights: Object.keys(this.b.deltas).length };
  };

  /* ----------------------------------------------------------- live reading
   * Same-origin only -- a browser will not let any page fetch a third party's
   * site, and no amount of JavaScript changes that. What it will let this page
   * read is the rest of cell4.art, which is where the architecture notes and
   * the source files are. */
  function absolute(href, base) {
    try { return new URL(href, base).href; } catch (e) { return null; }
  }

  function chunkText(name, text, url) {
    var out = [], i;
    if (/\.(md|markdown)$/i.test(name)) {
      var parts = text.split(/^(#{1,4}\s+.*)$/m), head = name;
      for (i = 0; i < parts.length; i++) {
        var seg = parts[i].trim();
        if (!seg) continue;
        if (/^#{1,4}\s/.test(seg)) { head = seg.replace(/^#+\s*/, ""); continue; }
        seg.match(/[\s\S]{1,700}(\.|$)/g).forEach(function (block) {
          if (block.trim().length > 40) out.push({ h: head, t: block.trim().replace(/\s+/g, " "), s: url, g: [] });
        });
      }
    } else if (/\.html?$/i.test(name)) {
      var body = text.replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
                     .replace(/<[^>]+>/g, " ").replace(/&[a-z#0-9]+;/gi, " ");
      body.replace(/\s+/g, " ").match(/[\s\S]{1,700}(\.|$)/g).forEach(function (block) {
        if (block.trim().length > 60) out.push({ h: name, t: block.trim(), s: url, g: [] });
      });
    } else {
      var lines = text.split("\n");
      for (i = 0; i < lines.length; i += 45) {
        var block = lines.slice(i, i + 45).join(" ").replace(/\s+/g, " ").trim();
        if (block.length > 60) {
          out.push({ h: name + " (" + (i + 1) + "-" + (i + 45) + ")",
                     t: block.slice(0, 900), s: url, g: [] });
        }
      }
    }
    return out;
  }

  function readLive(done) {
    if (!/^https?:$/.test(location.protocol)) { return done(null, "local file"); }
    try {
      var cached = JSON.parse(localStorage.getItem(LS_CACHE) || "null");
      if (cached && Date.now() - cached.t < LIVE_TTL && cached.src === SOURCES.join(",")) {
        return done(cached.p, "cached");
      }
    } catch (e) {}

    var pending = SOURCES.length, added = [], files = 0;
    if (!pending) return done(null, "no sources");

    SOURCES.forEach(function (src) {
      var dirUrl = absolute(src, location.href);
      if (!dirUrl || new URL(dirUrl).origin !== location.origin) {
        if (!--pending) finish();
        return;
      }
      fetch(dirUrl, { credentials: "same-origin" })
        .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
        .then(function (body) {
          /* A file was given directly; index it. Otherwise treat the response
             as a listing and follow the readable links inside it. */
          if (READABLE.test(dirUrl) && !/<a\s/i.test(body.slice(0, 400))) {
            added = added.concat(chunkText(dirUrl.split("/").pop(), body, dirUrl));
            files++;
            if (!--pending) finish();
            return;
          }
          var hrefs = [], m, re = /href\s*=\s*["']([^"']+)["']/gi;
          while ((m = re.exec(body)) && hrefs.length < 40) {
            var u = absolute(m[1], dirUrl);
            if (u && READABLE.test(u) && u.indexOf(dirUrl) === 0 && hrefs.indexOf(u) < 0) {
              hrefs.push(u);
            }
          }
          hrefs = hrefs.slice(0, 14);
          if (!hrefs.length) { if (!--pending) finish(); return; }
          var left = hrefs.length;
          hrefs.forEach(function (u) {
            fetch(u, { credentials: "same-origin" })
              .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
              .then(function (t) {
                added = added.concat(chunkText(u.split("/").pop(), t.slice(0, 260000), u));
                files++;
              })
              .catch(function () {})
              .then(function () { if (!--left && !--pending) finish(); });
          });
        })
        .catch(function () { if (!--pending) finish(); });
    });

    function finish() {
      try {
        localStorage.setItem(LS_CACHE, JSON.stringify(
          { t: Date.now(), src: SOURCES.join(","), p: added }));
      } catch (e) {}
      done(added.length ? added : null, files + " file" + (files === 1 ? "" : "s"));
    }
  }

  /* ------------------------------------------------------------------- ui */
  var brain = new Brain(B), learner;

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function bot(a, question) {
    var m = el("div", "msg bot");
    m.appendChild(document.createTextNode(a.text));
    if (a.also) m.appendChild(el("div", "also", "Also: " + a.also));
    if ((a.sources && a.sources.length) || a.hit) {
      var meta = el("div", "meta");
      (a.sources || []).filter(function (s, i, arr) { return s && arr.indexOf(s) === i; })
        .slice(0, 3).forEach(function (s) {
          var link = el("a", "src", String(s).split("/").pop() || s);
          link.href = s; link.target = "_top"; link.rel = "noopener";
          meta.appendChild(link);
        });
      if (a.hit) {
        var vote = el("div", "vote");
        [["↑", 1], ["↓", -1]].forEach(function (pair) {
          var btn = el("button", null, pair[0]);
          btn.title = pair[1] > 0 ? "Right answer — teach it" : "Wrong answer — teach it";
          btn.addEventListener("click", function () {
            if (btn.classList.contains("on")) return;
            vote.querySelectorAll("button").forEach(function (b2) { b2.classList.remove("on"); });
            btn.classList.add("on");
            learner.step(question, a.hit, pair[1] * 2);
            paintStatus();
          });
          vote.appendChild(btn);
        });
        meta.appendChild(vote);
      }
      m.appendChild(meta);
    }
    log.appendChild(m);
    log.scrollTop = log.scrollHeight;
  }

  function ask(text) {
    log.appendChild(el("div", "msg me", text));
    var wait = el("div", "msg bot think");
    wait.innerHTML = "<i></i><i></i><i></i>";
    log.appendChild(wait);
    log.scrollTop = log.scrollHeight;
    setTimeout(function () {
      log.removeChild(wait);
      var a = answer(text);
      bot(a, text);
      if (a.hit) { learner.step(text, a.hit, 1); paintStatus(); }
    }, 240 + Math.random() * 200);
  }

  function paintStatus() {
    var s = learner.summary();
    statusEl.innerHTML = "";
    statusEl.appendChild(el("span", null,
      brain.passages.length + " passages"));
    statusEl.appendChild(el("span", "sep", "·"));
    statusEl.appendChild(el("span", null,
      (brain.lm ? brain.lm.vocab.length : 0) + "-word model"));
    statusEl.appendChild(el("span", "sep", "·"));
    var learn = el("span", null, "learned " + s.adopted + "/" + s.rounds);
    learn.title = "Gradient steps this browser kept, out of steps it tried. A step is " +
                  "discarded when it would rank earlier questions worse.";
    statusEl.appendChild(learn);
    if (s.rounds) {
      statusEl.appendChild(el("span", "sep", "·"));
      var ex = el("a", null, "export");
      ex.title = "Download what this browser learned, to fold back into the trained model";
      ex.addEventListener("click", exportLearning);
      statusEl.appendChild(ex);
    }
  }

  function exportLearning() {
    var blob = new Blob([JSON.stringify(
      { deltas: brain.deltas, history: learner.hist, events: learner.events }, null, 1)],
      { type: "application/json" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "robots-learned.json";
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 4000);
  }

  function boot() {
    if (window.top !== window.self) document.body.classList.add("embed");
    brain.reindex();
    /* Give every passage a stable identity: the learner's gate compares the
       passages it ranked before against the ones it ranks now, and live files
       change the indices under it. */
    brain.passages.forEach(function (p, i) { p.key = (p.s || "") + "#" + i; });
    learner = new Learner(brain);

    var suggestions = CFG.suggestions ||
      ["What does CELL4 do?", "What is robots.js?", "Show me the proof of work",
       "How do I get in touch?"];
    suggestions.forEach(function (s) {
      var b2 = el("button", null, s);
      b2.addEventListener("click", function () { ask(s); });
      chips.appendChild(b2);
    });

    bot({ text: CFG.greeting ||
      "Ask me anything about CELL4. I answer out of this site's own pages, I run entirely in your browser, and I get better at this as people ask me things.",
      sources: [] });
    paintStatus();
    sub.textContent = "reads this site · runs in your browser";

    readLive(function (extra, note) {
      if (extra && extra.length) {
        extra.forEach(function (p, i) { p.key = (p.s || "") + "@" + i; });
        brain.passages = brain.passages.concat(extra);
        brain.reindex();
        brain.passages.forEach(function (p, i) {
          if (!p.key) p.key = (p.s || "") + "#" + i;
        });
        sub.textContent = "read " + note + " from " + SOURCES.join(", ");
      } else {
        sub.textContent = "reads this site · runs in your browser" +
          (note === "local file" ? " · offline copy" : "");
      }
      paintStatus();
    });
  }

  /* wiring */
  $("#launcher").addEventListener("click", function () { panel.classList.toggle("open"); input.focus(); });
  $(".close").addEventListener("click", function () { panel.classList.remove("open"); });
  $(".theme").addEventListener("click", function () {
    var cur = document.documentElement.getAttribute("data-theme");
    var next = cur === "dark" ? "light" : (cur === "light" ? "dark" :
      (matchMedia("(prefers-color-scheme: dark)").matches ? "light" : "dark"));
    document.documentElement.setAttribute("data-theme", next);
  });
  $(".ask").addEventListener("submit", function (e) {
    e.preventDefault();
    var v = input.value.trim();
    if (!v) return;
    input.value = "";
    ask(v);
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") panel.classList.remove("open");
  });

  window.robots = { ask: ask, brain: brain, export: exportLearning,
                    open: function () { panel.classList.add("open"); } };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
