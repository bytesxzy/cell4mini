/* Public databases robots.html can query with no key and no server.
 *
 * Every source here is (a) free, (b) keyless, and (c) chosen because it
 * documents CORS support -- a browser cannot call an API that does not send
 * Access-Control-Allow-Origin, no matter how public it is. That last property
 * is the one that decides whether a source is usable at all, and it is a
 * decision each of these services makes on their servers, not something this
 * file can guarantee. So none of them are trusted: robots.js probes a source
 * the first time it is used and disables it permanently on this device if it
 * does not answer. `robots.diagnose()` prints the live verdict.
 *
 * Requests are plain GETs with no custom headers, which keeps them "simple
 * requests" and avoids a CORS preflight that several of these would refuse.
 *
 * ── ON LINKEDIN ──────────────────────────────────────────────────────────
 * There is no keyless LinkedIn API and there cannot be one here. Every
 * LinkedIn API (Marketing, Talent, Sign In with LinkedIn) requires OAuth plus
 * partner approval, their servers send no CORS headers to a page like this,
 * and scraping profiles is a breach of their User Agreement. Anything claiming
 * otherwise is a paid scraper reselling data of contested provenance behind a
 * key. So: people and companies are served here by Wikidata (notable people
 * and organisations) and GLEIF (the global registry of legal entities, with
 * real addresses and ownership), which are open by design rather than open by
 * accident.
 */
(function () {
  "use strict";

  function txt(v) { return String(v == null ? "" : v).replace(/\s+/g, " ").trim(); }
  function clip(s, n) { s = txt(s); return s.length > n ? s.slice(0, n) + "…" : s; }
  function q(s) { return encodeURIComponent(s); }

  /* A source's `when` returns 0..1: how much this question looks like its
     subject. The router spends its four slots on the highest scorers. */
  function has(tokens, words) {
    for (var i = 0; i < words.length; i++) if (tokens.indexOf(words[i]) >= 0) return 1;
    return 0;
  }

  var SOURCES = [
    {
      id: "wikipedia", label: "Wikipedia", kind: "encyclopedia",
      home: "https://en.wikipedia.org", probe: "internet",
      when: function () { return 0.75; },          /* a sane default for anything */
      url: function (s) {
        return "https://en.wikipedia.org/w/api.php?action=query&generator=search" +
          "&gsrsearch=" + q(s) + "&gsrlimit=3&prop=extracts&exintro=1&explaintext=1" +
          "&format=json&origin=*";
      },
      parse: function (j) {
        var out = [], pages = j && j.query && j.query.pages;
        for (var k in pages) {
          var p = pages[k];
          if (!p.extract) continue;
          out.push({ h: p.title, t: clip(p.extract, 700),
                     s: "https://en.wikipedia.org/?curid=" + p.pageid });
        }
        return out;
      }
    },
    {
      id: "wikidata", label: "Wikidata", kind: "entities",
      home: "https://www.wikidata.org", probe: "microsoft",
      when: function (s, t) {
        return 0.6 + 0.3 * has(t, ["who", "company", "founder", "ceo", "born",
                                   "headquarters", "founded", "person", "org"]);
      },
      url: function (s) {
        return "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=" +
          q(s) + "&language=en&uselang=en&limit=5&format=json&origin=*";
      },
      parse: function (j) {
        var out = [], r = (j && j.search) || [];
        for (var i = 0; i < r.length; i++) {
          if (!r[i].description) continue;
          out.push({ h: r[i].label || r[i].id,
                     t: r[i].label + " — " + r[i].description,
                     s: "https://www.wikidata.org/wiki/" + r[i].id });
        }
        return out;
      }
    },
    {
      id: "gleif", label: "GLEIF company registry", kind: "companies",
      home: "https://www.gleif.org", probe: "apple",
      when: function (s, t) {
        return 0.2 + 0.7 * has(t, ["company", "companies", "corp", "inc", "ltd",
                                   "llc", "gmbh", "registry", "registered",
                                   "headquarters", "entity", "business", "legal"]);
      },
      url: function (s) {
        return "https://api.gleif.org/api/v1/lei-records?page[size]=3" +
          "&filter[entity.legalName]=" + q(s);
      },
      parse: function (j) {
        var out = [], d = (j && j.data) || [];
        for (var i = 0; i < d.length; i++) {
          var a = d[i].attributes || {}, e = a.entity || {}, addr = e.legalAddress || {};
          out.push({
            h: txt(e.legalName && e.legalName.name),
            t: txt(e.legalName && e.legalName.name) + " — " +
               txt((e.status || "") + " legal entity") +
               (addr.country ? ", registered in " + addr.country : "") +
               (addr.city ? " (" + txt(addr.city) + ")" : "") +
               (a.lei ? ". LEI " + a.lei + "." : ""),
            s: "https://search.gleif.org/#/record/" + a.lei
          });
        }
        return out;
      }
    },
    {
      id: "openalex", label: "OpenAlex", kind: "research",
      home: "https://openalex.org", probe: "transformers",
      when: function (s, t) {
        return 0.15 + 0.7 * has(t, ["paper", "papers", "research", "study",
                                    "studies", "cited", "citation", "journal",
                                    "author", "academic", "science"]);
      },
      url: function (s) {
        return "https://api.openalex.org/works?search=" + q(s) +
          "&per_page=3&select=id,title,publication_year,cited_by_count,doi";
      },
      parse: function (j) {
        var out = [], r = (j && j.results) || [];
        for (var i = 0; i < r.length; i++) {
          out.push({ h: clip(r[i].title, 90),
                     t: clip(r[i].title, 260) + " (" + (r[i].publication_year || "n.d.") +
                        "), cited " + (r[i].cited_by_count || 0) + " times.",
                     s: r[i].doi || r[i].id });
        }
        return out;
      }
    },
    {
      id: "crossref", label: "Crossref", kind: "research",
      home: "https://www.crossref.org", probe: "program synthesis",
      when: function (s, t) {
        return 0.1 + 0.6 * has(t, ["doi", "paper", "papers", "journal",
                                   "published", "citation", "preprint"]);
      },
      url: function (s) {
        /* mailto is Crossref's documented way into the polite pool; a browser
           cannot set a User-Agent, so the query parameter is the only route. */
        return "https://api.crossref.org/works?rows=3&select=title,DOI,issued," +
          "container-title&query=" + q(s) + "&mailto=cell4.art@gmail.com";
      },
      parse: function (j) {
        var out = [], r = (j && j.message && j.message.items) || [];
        for (var i = 0; i < r.length; i++) {
          var title = (r[i].title || [])[0];
          if (!title) continue;
          out.push({ h: clip(title, 90),
                     t: clip(title, 260) + " — " +
                        clip((r[i]["container-title"] || [])[0] || "journal article", 80) + ".",
                     s: "https://doi.org/" + r[i].DOI });
        }
        return out;
      }
    },
    {
      id: "github", label: "GitHub", kind: "code",
      home: "https://github.com", probe: "playwright",
      when: function (s, t) {
        return 0.15 + 0.7 * has(t, ["github", "repo", "repository", "library",
                                    "package", "open", "source", "code", "sdk"]);
      },
      url: function (s) {
        return "https://api.github.com/search/repositories?per_page=3&q=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.items) || [];
        for (var i = 0; i < r.length; i++) {
          out.push({ h: r[i].full_name,
                     t: r[i].full_name + " — " + clip(r[i].description || "no description", 240) +
                        " " + (r[i].stargazers_count || 0) + " stars, " +
                        (r[i].language || "mixed") + ".",
                     s: r[i].html_url });
        }
        return out;
      }
    },
    {
      id: "hn", label: "Hacker News", kind: "discussion",
      home: "https://news.ycombinator.com", probe: "startup",
      when: function (s, t) {
        return 0.1 + 0.6 * has(t, ["hacker", "news", "discussion", "opinion",
                                   "thread", "startup", "launch", "yc"]);
      },
      url: function (s) {
        return "https://hn.algolia.com/api/v1/search?hitsPerPage=3&query=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.hits) || [];
        for (var i = 0; i < r.length; i++) {
          var t = r[i].title || r[i].story_title;
          if (!t) continue;
          out.push({ h: clip(t, 90),
                     t: clip(t, 240) + " — " + (r[i].points || 0) + " points, " +
                        (r[i].num_comments || 0) + " comments.",
                     s: r[i].url || ("https://news.ycombinator.com/item?id=" + r[i].objectID) });
        }
        return out;
      }
    },
    {
      id: "stackexchange", label: "Stack Overflow", kind: "howto",
      home: "https://stackoverflow.com", probe: "cors",
      when: function (s, t) {
        return 0.1 + 0.7 * has(t, ["error", "how", "fix", "why", "javascript",
                                   "python", "css", "html", "api", "bug", "code"]);
      },
      url: function (s) {
        return "https://api.stackexchange.com/2.3/search/advanced?order=desc" +
          "&sort=relevance&pagesize=3&site=stackoverflow&q=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.items) || [];
        for (var i = 0; i < r.length; i++) {
          out.push({ h: clip(r[i].title, 90),
                     t: clip(r[i].title, 240) + " — " + (r[i].answer_count || 0) +
                        " answers, score " + (r[i].score || 0) +
                        (r[i].is_answered ? ", accepted." : "."),
                     s: r[i].link });
        }
        return out;
      }
    },
    {
      id: "openlibrary", label: "Open Library", kind: "books",
      home: "https://openlibrary.org", probe: "dune",
      when: function (s, t) {
        return 0.05 + 0.8 * has(t, ["book", "books", "author", "novel", "isbn",
                                    "published", "read", "wrote"]);
      },
      url: function (s) {
        return "https://openlibrary.org/search.json?limit=3&fields=title,author_name," +
          "first_publish_year,key&q=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.docs) || [];
        for (var i = 0; i < r.length; i++) {
          out.push({ h: clip(r[i].title, 90),
                     t: clip(r[i].title, 200) + " by " +
                        ((r[i].author_name || ["unknown"])[0]) +
                        (r[i].first_publish_year ? ", " + r[i].first_publish_year : "") + ".",
                     s: "https://openlibrary.org" + r[i].key });
        }
        return out;
      }
    },
    {
      id: "coingecko", label: "CoinGecko", kind: "markets",
      home: "https://www.coingecko.com", probe: "bitcoin",
      when: function (s, t) {
        return 0.05 + 0.85 * has(t, ["price", "token", "coin", "crypto", "market",
                                     "cap", "usdt", "cpx", "trading", "chart"]);
      },
      url: function (s) { return "https://api.coingecko.com/api/v3/search?query=" + q(s); },
      parse: function (j) {
        var out = [], r = (j && j.coins) || [];
        for (var i = 0; i < Math.min(3, r.length); i++) {
          out.push({ h: r[i].name + " (" + String(r[i].symbol).toUpperCase() + ")",
                     t: r[i].name + " — token, symbol " + String(r[i].symbol).toUpperCase() +
                        (r[i].market_cap_rank ? ", market cap rank #" + r[i].market_cap_rank : "") + ".",
                     s: "https://www.coingecko.com/en/coins/" + r[i].id });
        }
        return out;
      }
    },
    {
      id: "restcountries", label: "REST Countries", kind: "places",
      home: "https://restcountries.com", probe: "japan",
      when: function (s, t) {
        return 0.02 + 0.85 * has(t, ["country", "capital", "population",
                                     "currency", "continent", "region"]);
      },
      url: function (s) {
        return "https://restcountries.com/v3.1/name/" + q(s) +
          "?fields=name,capital,population,region,currencies";
      },
      parse: function (j) {
        var out = [], r = (j && j.length) ? j : [];
        for (var i = 0; i < Math.min(2, r.length); i++) {
          var c = r[i], cur = [];
          for (var k in (c.currencies || {})) cur.push(c.currencies[k].name);
          out.push({ h: c.name && c.name.common,
                     t: (c.name && c.name.common) + " — capital " +
                        ((c.capital || ["n/a"])[0]) + ", population " +
                        (c.population || 0).toLocaleString() + ", " + (c.region || "") +
                        (cur.length ? ", currency " + cur[0] : "") + ".",
                     s: "https://restcountries.com/v3.1/name/" + q(c.name.common) });
        }
        return out;
      }
    },
    {
      id: "openmeteo", label: "Open-Meteo", kind: "weather",
      home: "https://open-meteo.com", probe: "london",
      when: function (s, t) {
        return 0.02 + 0.9 * has(t, ["weather", "temperature", "forecast",
                                    "raining", "rain", "snow", "climate"]);
      },
      url: function (s) {
        return "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" +
          q(s.replace(/\b(weather|forecast|temperature|in|at|the)\b/gi, " ").trim() || s);
      },
      parse: function (j) {
        var r = (j && j.results) || [];
        if (!r.length) return [];
        var p = r[0];
        return [{ h: p.name,
                  t: p.name + (p.admin1 ? ", " + p.admin1 : "") + ", " + (p.country || "") +
                     " — " + p.latitude.toFixed(2) + ", " + p.longitude.toFixed(2) +
                     (p.population ? ", population " + p.population.toLocaleString() : "") + ".",
                  s: "https://open-meteo.com/en/docs" }];
      }
    },
    {
      id: "npm", label: "npm", kind: "code",
      home: "https://www.npmjs.com", probe: "react",
      when: function (s, t) {
        return 0.02 + 0.75 * has(t, ["npm", "node", "javascript", "package",
                                     "module", "install", "yarn"]);
      },
      url: function (s) {
        return "https://registry.npmjs.org/-/v1/search?size=3&text=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.objects) || [];
        for (var i = 0; i < r.length; i++) {
          var p = r[i].package || {};
          out.push({ h: p.name,
                     t: p.name + "@" + p.version + " — " + clip(p.description || "", 220),
                     s: (p.links && p.links.npm) || ("https://www.npmjs.com/package/" + p.name) });
        }
        return out;
      }
    },
    {
      id: "pypi", label: "PyPI", kind: "code",
      home: "https://pypi.org", probe: "requests",
      when: function (s, t) {
        return 0.02 + 0.7 * has(t, ["pypi", "python", "pip", "package", "module"]);
      },
      url: function (s) {
        return "https://pypi.org/pypi/" + q(s.split(/\s+/).pop()) + "/json";
      },
      parse: function (j) {
        var i = j && j.info;
        if (!i) return [];
        return [{ h: i.name + " " + i.version,
                  t: i.name + " " + i.version + " — " + clip(i.summary || "", 240),
                  s: i.package_url || ("https://pypi.org/project/" + i.name + "/") }];
      }
    },
    {
      id: "datamuse", label: "Datamuse", kind: "language",
      home: "https://www.datamuse.com", probe: "ocean",
      when: function (s, t) {
        return 0.02 + 0.8 * has(t, ["word", "words", "meaning", "means",
                                    "synonym", "define", "definition", "spelled"]);
      },
      url: function (s) {
        return "https://api.datamuse.com/words?md=d&max=3&ml=" + q(s);
      },
      parse: function (j) {
        var out = [], r = j || [];
        for (var i = 0; i < Math.min(3, r.length); i++) {
          var defs = r[i].defs || [];
          if (!defs.length) continue;
          out.push({ h: r[i].word,
                     t: r[i].word + " — " + defs.slice(0, 2).join("; ").replace(/\t/g, ". "),
                     s: "https://www.datamuse.com/api/" });
        }
        return out;
      }
    },
    {
      id: "openfoodfacts", label: "Open Food Facts", kind: "products",
      home: "https://world.openfoodfacts.org", probe: "nutella",
      when: function (s, t) {
        return 0.01 + 0.85 * has(t, ["food", "ingredient", "ingredients",
                                     "calories", "nutrition", "product", "barcode"]);
      },
      url: function (s) {
        return "https://world.openfoodfacts.org/cgi/search.pl?search_simple=1&json=1" +
          "&page_size=2&fields=product_name,brands,ingredients_text,code&search_terms=" + q(s);
      },
      parse: function (j) {
        var out = [], r = (j && j.products) || [];
        for (var i = 0; i < r.length; i++) {
          if (!r[i].product_name) continue;
          out.push({ h: r[i].product_name,
                     t: r[i].product_name + (r[i].brands ? " by " + r[i].brands : "") +
                        " — " + clip(r[i].ingredients_text || "no ingredient list", 240),
                     s: "https://world.openfoodfacts.org/product/" + r[i].code });
        }
        return out;
      }
    }
  ];

  window.ROBOTS_SOURCE_DEFS = SOURCES;
})();
