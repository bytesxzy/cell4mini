/*  GABRIEL chat -- a popup assistant that answers out of the site itself.
 *
 *  No external model, no API key, no server. Everything runs in the visitor's
 *  browser against brain/brain.js, which build_brain.py generates from the
 *  site's own pages.
 *
 *  Retrieval is two scores added together:
 *
 *    BM25            classic lexical overlap, so an exact word always counts;
 *    query likelihood  the log-linear language model trained by build_brain.py,
 *                    conditioned on a passage's heading, asked how probable the
 *                    question's words are. This is what reaches a passage whose
 *                    wording differs from the question's.
 *
 *  The reply is assembled from the site's own sentences. It cannot invent a
 *  fact, because it has no way to produce a sentence that is not already on the
 *  page -- which for a portfolio is the right trade.
 *
 *  Install:  <script src="gabriel-chat/brain/brain.js"></script>
 *            <script src="gabriel-chat/gabriel-chat.js"></script>
 */
(function () {
  "use strict";

  var STOP = (" a an and are as at be been but by for from had has have he her his i" +
    " if in is it its me my no not of on or our so than that the their them then" +
    " there these they this to too was we were what when where which who will with" +
    " would you your ").split(" ").filter(Boolean);
  var STOPSET = {};
  STOP.forEach(function (w) { STOPSET[w] = 1; });

  /* The builder ships the list it indexed with, so the two can never drift --
   * a word that scores here but was stripped there is how "do you sell
   * hamsters" ends up matching "we do prefer to talk". */
  function useStopList(words) {
    STOPSET = {};
    (words || STOP).forEach(function (w) { STOPSET[w] = 1; });
  }

  function tokenize(text) {
    var out = [], m = String(text || "").toLowerCase().match(/[a-z0-9][a-z0-9'+#.-]*/g) || [];
    for (var i = 0; i < m.length; i++) {
      if (m[i].length > 1 && !STOPSET[m[i]]) out.push(m[i]);
    }
    return out;
  }

  /* Words related by a shared stem count as the same evidence: "worked" has to
   * find "work", "pricing" has to find "price".  A prefix test does that
   * without a stemmer, which is a thing that would have to be kept identical in
   * two languages to stay correct. */
  function related(a, b) {
    if (a === b) return true;
    var n = Math.min(a.length, b.length);
    if (n < 4) return false;
    return a.slice(0, n) === b.slice(0, n) && Math.abs(a.length - b.length) <= 4;
  }

  /* ---------------------------------------------------------------- model */

  function Brain(data) {
    this.d = data || {};
    this.passages = this.d.passages || [];
    this.docs = (this.d.tokens || []).map(function (s) { return s.split(" "); });
    this.idf = this.d.idf || {};
    this.avgdl = this.d.avgdl || 12;
    this.lm = this.d.lm && this.d.lm.vocab ? this.d.lm : null;
    this._cache = {};
  }

  /* One document model per passage: the bias row plus its heading rows.
   * Same softmax the Python trainer normalises with; the weights are the
   * trained ones, not a summary of them. */
  Brain.prototype.docDist = function (index) {
    if (this._cache[index]) return this._cache[index];
    var lm = this.lm;
    if (!lm) return null;
    var feats = ["b"].concat(this.passages[index].g || []);
    var acc = Object.create(null), v = lm.vocab, i, j, row, t;
    for (i = 0; i < v.length; i++) acc[v[i]] = 0;
    for (i = 0; i < feats.length; i++) {
      row = lm.w[feats[i]];
      if (!row) continue;
      for (t in row) if (t in acc) acc[t] += row[t];
    }
    var peak = -Infinity;
    for (i = 0; i < v.length; i++) if (acc[v[i]] > peak) peak = acc[v[i]];
    var z = 0, out = Object.create(null);
    for (i = 0; i < v.length; i++) { out[v[i]] = Math.exp(acc[v[i]] - peak); z += out[v[i]]; }
    for (i = 0; i < v.length; i++) out[v[i]] /= z;
    this._cache[index] = out;
    return out;
  };

  Brain.prototype.vocabForm = function (w) {
    if (!this.lm) return null;
    if (this.lm.unigram[w] != null) return w;
    var v = this.lm.vocab;
    for (var i = 0; i < v.length; i++) if (related(w, v[i])) return v[i];
    return null;
  };

  Brain.prototype.queryLikelihood = function (index, q) {
    var d = this.docDist(index);
    if (!d) return 0;
    var seen = 0, total = 0;
    for (var i = 0; i < q.length; i++) {
      var w = this.vocabForm(q[i]);
      if (w && w in d) { total += Math.log(Math.max(d[w], 1e-9)); seen++; }
    }
    if (!seen) return 0;
    /* mean log-probability, shifted so a perfectly typical word scores ~0 */
    return (total / seen + Math.log(this.lm.vocab.length)) * 0.9;
  };

  Brain.prototype.bm25 = function (index, q) {
    var doc = this.docs[index] || [], k1 = 1.4, b = 0.72, score = 0;
    if (!doc.length) return 0;
    var tf = Object.create(null), i, t;
    for (i = 0; i < doc.length; i++) tf[doc[i]] = (tf[doc[i]] || 0) + 1;
    for (i = 0; i < q.length; i++) {
      var f = tf[q[i]] || 0, discount = 1, key = q[i];
      if (!f) {                                  /* try a shared stem */
        for (t in tf) {
          if (related(q[i], t)) { f = tf[t]; key = t; discount = 0.75; break; }
        }
      }
      if (!f) continue;
      var idf = this.idf[key] || 0.4;
      score += discount * idf * (f * (k1 + 1)) /
               (f + k1 * (1 - b + b * doc.length / this.avgdl));
    }
    return score;
  };

  /* A question's words, plus the vocabulary bridge from build_brain.py. */
  Brain.prototype.expand = function (q) {
    var aliases = this.d.aliases || {}, out = q.slice(), i, j;
    for (i = 0; i < q.length; i++) {
      var add = aliases[q[i]];
      if (!add) continue;
      for (j = 0; j < add.length; j++) if (out.indexOf(add[j]) < 0) out.push(add[j]);
    }
    return out;
  };

  Brain.prototype.rank = function (question) {
    var asked = tokenize(question);
    if (!asked.length) return [];
    var q = this.expand(asked), scored = [], i, j;
    for (i = 0; i < this.passages.length; i++) {
      var p = this.passages[i];
      var lex = this.bm25(i, q);
      var lm = this.queryLikelihood(i, q);
      /* A question that names a section is usually asking about that section --
       * but only where the heading is a heading.  On a page whose markup makes
       * a paragraph its own <h2>, every word is a "heading" word, and an
       * uncapped bonus there turns the longest passage into the answer to
       * everything. */
      var head = tokenize(p.h), boost = 0;
      if (head.length <= 12) {
        for (j = 0; j < q.length; j++) if (head.indexOf(q[j]) >= 0) boost += 0.8;
        boost = Math.min(boost, 1.6);
      }
      scored.push({ i: i, p: p, score: lex + 0.55 * lm + boost, lex: lex, lm: lm });
    }
    scored.sort(function (a, b) { return b.score - a.score; });
    /* No passage shares a word with the question -> say so, rather than
     * handing back whichever passage the priors happened to like. */
    return scored.filter(function (s) { return s.lex > 0.3 && s.score > 0.6; });
  };

  /* ------------------------------------------------------------- answering */

  function sentences(text) {
    return String(text).split(/(?<=[.!?:])\s+/).filter(function (s) {
      return s.trim().length > 2;
    });
  }

  function bestSentences(text, q, limit) {
    var ss = sentences(text);
    if (ss.length <= limit) return ss.join(" ");
    var scored = ss.map(function (s, i) {
      var t = tokenize(s), hit = 0;
      for (var j = 0; j < q.length; j++) if (t.indexOf(q[j]) >= 0) hit++;
      return { s: s, i: i, hit: hit };
    });
    scored.sort(function (a, b) { return b.hit - a.hit || a.i - b.i; });
    var keep = scored.slice(0, limit).sort(function (a, b) { return a.i - b.i; });
    return keep.map(function (k) { return k.s; }).join(" ");
  }

  var SMALLTALK = [
    { re: /^(hi|hey|hello|yo|sup|hola)\b/i,
      say: "Hey. Ask me anything about this site — pricing, the team, the work, how to get in touch." },
    { re: /\b(thanks|thank you|ty|appreciate)\b/i, say: "Anytime." },
    { re: /\b(bye|goodbye|cya|see ya)\b/i, say: "See you." },
    { re: /\b(who|what) (are|r) (you|u)\b/i,
      say: "A small assistant that reads this site and answers out of it. No outside model — everything runs in your browser." },
    { re: /\b(are you (chat)?gpt|are you ai|which model|what model)\b/i,
      say: "Not GPT and not any hosted model. I am a language model trained on this site's own text, running locally in this page." },
    { re: /\b(help|what can you (do|answer))\b/i,
      say: "Try: what do you charge, what is CELL4, who have you worked with, which Roblox games, how do I contact you." }
  ];

  function answer(brain, question) {
    for (var i = 0; i < SMALLTALK.length; i++) {
      if (SMALLTALK[i].re.test(question.trim())) {
        return { text: SMALLTALK[i].say, sources: [] };
      }
    }
    var q = tokenize(question);
    var hits = brain.rank(question);
    if (!hits.length) {
      return {
        text: "I could not find that on this site. I only answer from what is actually published here — try pricing, the team, past work, or contact.",
        sources: []
      };
    }
    var top = hits[0];
    var body = bestSentences(top.p.t, q, 3);
    /* A heading on its own is a label, not an answer.  Where the best passage
     * is that short, the runner-up carries the content. */
    if (body.split(/\s+/).length < 8 && hits[1]) {
      var more = bestSentences(hits[1].p.t, q, 2);
      if (more && more.toLowerCase().indexOf(body.toLowerCase()) < 0) {
        /* The content answers; the label was only how we found it. */
        return { text: more, sources: [hits[1].p.s, top.p.s] };
      }
    }
    /* Lead with the section name -- but only where the heading is a heading.
     * Where the markup makes a whole paragraph an <h2>, prefixing it restates
     * the answer before giving it. */
    var h = (top.p.h || "").replace(/[:\s]+$/, "");
    var lead = (h && h.split(/\s+/).length <= 10 &&
                body.toLowerCase().indexOf(h.toLowerCase()) !== 0) ? h + " — " : "";
    var out = { text: lead + body, sources: [top.p.s] };
    if (hits[1] && hits[1].score > top.score * 0.6) {
      var second = bestSentences(hits[1].p.t, q, 1);
      if (second && second.length > 12 && out.text.indexOf(second.slice(0, 24)) < 0) {
        out.related = second;
        out.sources.push(hits[1].p.s);
      }
    }
    return out;
  }

  /* ------------------------------------------------------------------- ui */

  var CSS = [
    ":host{all:initial}",
    "*{box-sizing:border-box;margin:0;padding:0;font-family:Georgia,'Times New Roman',serif}",
    ".wrap{position:fixed;right:20px;bottom:20px;z-index:2147483000;display:flex;flex-direction:column;align-items:flex-end;gap:12px}",
    /* launcher */
    ".bubble{width:56px;height:56px;border-radius:999px;border:1px solid rgba(255,255,255,.14);",
    "background:rgba(5,5,5,.62);-webkit-backdrop-filter:blur(18px) saturate(140%);backdrop-filter:blur(18px) saturate(140%);",
    "box-shadow:0 10px 30px rgba(0,0,0,.8),inset 0 1px 0 rgba(255,255,255,.10);cursor:pointer;color:#f2f2f2;",
    "font-size:22px;display:flex;align-items:center;justify-content:center;transition:transform .35s cubic-bezier(.165,.84,.44,1),box-shadow .35s ease}",
    ".bubble:hover{transform:scale(1.06);box-shadow:0 16px 35px rgba(0,0,0,.7),inset 0 1px 0 rgba(255,255,255,.16)}",
    ".bubble .dot{position:absolute;top:12px;right:12px;width:7px;height:7px;border-radius:999px;background:#e33232}",
    /* panel */
    ".panel{width:360px;max-width:calc(100vw - 32px);height:498px;max-height:calc(100vh - 120px);",
    "display:none;flex-direction:column;overflow:hidden;border-radius:14px;",
    "border:1px solid rgba(255,255,255,.12);background:rgba(6,6,6,.58);",
    "-webkit-backdrop-filter:blur(22px) saturate(150%);backdrop-filter:blur(22px) saturate(150%);",
    "box-shadow:0 16px 45px rgba(0,0,0,.85),inset 0 1px 0 rgba(255,255,255,.09);",
    "opacity:0;transform:translateY(10px) scale(.98);transition:opacity .3s ease,transform .35s cubic-bezier(.165,.84,.44,1)}",
    ".panel.open{display:flex;opacity:1;transform:none}",
    ".head{display:flex;align-items:center;gap:10px;padding:13px 14px;border-bottom:1px solid rgba(255,255,255,.09)}",
    ".head .name{color:#f2f2f2;font-size:15px;letter-spacing:.3px}",
    ".head .sub{color:#8a8a8a;font-size:11px}",
    ".head .close{margin-left:auto;color:#aaa;font-size:22px;line-height:1;cursor:pointer;background:none;border:0}",
    ".head .close:hover{color:#fff}",
    ".mark{width:26px;height:26px;border-radius:999px;background:rgba(227,50,50,.16);border:1px solid rgba(227,50,50,.4);",
    "display:flex;align-items:center;justify-content:center;color:#ff6347;font-size:13px}",
    ".log{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px;scrollbar-color:#ff6347 transparent}",
    ".log::-webkit-scrollbar{width:8px}.log::-webkit-scrollbar-track{background:transparent}",
    ".log::-webkit-scrollbar-thumb{background:rgba(255,99,71,.35);border-radius:6px}",
    ".msg{max-width:88%;padding:9px 12px;border-radius:12px;font-size:12.5px;line-height:1.5;color:#f2f2f2;white-space:pre-wrap;word-wrap:break-word}",
    ".msg.bot{align-self:flex-start;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08)}",
    ".msg.me{align-self:flex-end;background:rgba(227,50,50,.16);border:1px solid rgba(227,50,50,.28)}",
    ".rel{font-size:11.5px;color:#c8c8c8;border-top:1px solid rgba(255,255,255,.10);margin-top:7px;padding-top:6px}",
    ".src{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}",
    ".src a{font-size:10.5px;color:#ff6347;text-decoration:none;border:1px solid rgba(255,99,71,.32);",
    "border-radius:999px;padding:2px 8px;font-family:Arial,Helvetica,sans-serif}",
    ".src a:hover{background:rgba(255,99,71,.12)}",
    ".chips{display:flex;gap:6px;flex-wrap:wrap;padding:0 14px 10px}",
    ".chips button{font-size:11px;color:#ddd;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.12);",
    "border-radius:999px;padding:5px 10px;cursor:pointer}",
    ".chips button:hover{background:rgba(255,255,255,.10);color:#fff}",
    ".ask{display:flex;gap:8px;padding:11px 12px;border-top:1px solid rgba(255,255,255,.09)}",
    ".ask input{flex:1;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.12);border-radius:999px;",
    "padding:9px 13px;color:#f2f2f2;font-size:12.5px;outline:none}",
    ".ask input:focus{border-color:rgba(255,99,71,.5)}",
    ".ask button{background:rgba(227,50,50,.22);border:1px solid rgba(227,50,50,.45);color:#f2f2f2;",
    "border-radius:999px;padding:0 15px;font-size:12.5px;cursor:pointer}",
    ".ask button:hover{background:rgba(227,50,50,.34)}",
    ".typing span{display:inline-block;width:5px;height:5px;margin-right:3px;border-radius:999px;",
    "background:#ff6347;opacity:.4;animation:b 1.1s infinite}",
    ".typing span:nth-child(2){animation-delay:.15s}.typing span:nth-child(3){animation-delay:.3s}",
    "@keyframes b{0%,60%,100%{opacity:.25;transform:translateY(0)}30%{opacity:1;transform:translateY(-3px)}}",
    "@media (max-width:420px){.panel{width:calc(100vw - 28px);height:calc(100vh - 130px)}}"
  ].join("");

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function mount(brain, opts) {
    var host = document.createElement("div");
    host.setAttribute("data-gabriel-chat", "");
    var root = host.attachShadow ? host.attachShadow({ mode: "open" }) : host;
    var style = document.createElement("style");
    style.textContent = CSS;
    root.appendChild(style);

    var wrap = el("div", "wrap");
    var panel = el("div", "panel");
    var head = el("div", "head");
    var mark = el("div", "mark", "◆");
    var titles = el("div");
    titles.appendChild(el("div", "name", opts.title));
    titles.appendChild(el("div", "sub", opts.subtitle));
    var close = el("button", "close", "×");
    close.setAttribute("aria-label", "Close chat");
    head.appendChild(mark); head.appendChild(titles); head.appendChild(close);

    var log = el("div", "log");
    log.setAttribute("role", "log");
    var chips = el("div", "chips");
    var ask = el("div", "ask");
    var input = el("input");
    input.type = "text";
    input.placeholder = "Ask about " + opts.title.replace(/ .*/, "") + "…";
    input.setAttribute("aria-label", "Your question");
    var send = el("button", null, "Ask");
    ask.appendChild(input); ask.appendChild(send);
    panel.appendChild(head); panel.appendChild(log);
    panel.appendChild(chips); panel.appendChild(ask);

    var bubble = el("div", "bubble", "◆");
    bubble.setAttribute("role", "button");
    bubble.setAttribute("tabindex", "0");
    bubble.setAttribute("aria-label", "Open chat");
    bubble.appendChild(el("div", "dot"));
    wrap.appendChild(panel); wrap.appendChild(bubble);
    root.appendChild(wrap);
    document.body.appendChild(host);

    function bot(a) {
      var m = el("div", "msg bot");
      m.appendChild(document.createTextNode(a.text));
      if (a.related) m.appendChild(el("div", "rel", "Also: " + a.related));
      if (a.sources && a.sources.length) {
        var box = el("div", "src");
        a.sources.filter(function (s, i, arr) { return arr.indexOf(s) === i; })
          .forEach(function (s) {
            var link = el("a", null, String(s).replace(/^.*\//, "") || s);
            link.href = s; link.target = "_top";
            box.appendChild(link);
          });
        m.appendChild(box);
      }
      log.appendChild(m);
      log.scrollTop = log.scrollHeight;
    }

    function me(text) {
      log.appendChild(el("div", "msg me", text));
      log.scrollTop = log.scrollHeight;
    }

    function respond(text) {
      me(text);
      var wait = el("div", "msg bot typing");
      wait.innerHTML = "<span></span><span></span><span></span>";
      log.appendChild(wait);
      log.scrollTop = log.scrollHeight;
      setTimeout(function () {
        log.removeChild(wait);
        bot(answer(brain, text));
      }, 260 + Math.random() * 220);
    }

    function submit() {
      var v = input.value.trim();
      if (!v) return;
      input.value = "";
      respond(v);
    }

    send.addEventListener("click", submit);
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); submit(); }
    });

    var open = false;
    function toggle(state) {
      open = state == null ? !open : state;
      panel.classList.toggle("open", open);
      bubble.setAttribute("aria-label", open ? "Close chat" : "Open chat");
      if (open) setTimeout(function () { input.focus(); }, 60);
    }
    bubble.addEventListener("click", function () { toggle(); });
    bubble.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); }
    });
    close.addEventListener("click", function () { toggle(false); });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && open) toggle(false);
    });

    opts.suggestions.forEach(function (s) {
      var b = el("button", null, s);
      b.addEventListener("click", function () { respond(s); });
      chips.appendChild(b);
    });

    bot({ text: opts.greeting, sources: [] });
    return { open: function () { toggle(true); }, close: function () { toggle(false); },
             ask: respond, brain: brain };
  }

  function boot() {
    var data = window.GABRIEL_BRAIN;
    if (data && data.stop) useStopList(data.stop);
    var cfg = window.GABRIEL_CHAT_CONFIG || {};
    var site = (data && data.site) || "this site";
    var opts = {
      title: cfg.title || (site + " assistant"),
      subtitle: cfg.subtitle || (data ? "reads this site · runs in your browser"
                                     : "brain not loaded"),
      greeting: cfg.greeting ||
        (data ? "Ask me anything about " + site + ". I answer from what is published here, and I run entirely in your browser — nothing is sent anywhere."
              : "brain/brain.js has not loaded, so I have nothing to read. Add it before this script, or run build_brain.py to generate it."),
      suggestions: cfg.suggestions ||
        ["What do you charge?", "What is " + site + "?", "Who have you worked with?", "How do I get in touch?"]
    };
    window.GabrielChat = mount(new Brain(data), opts);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
