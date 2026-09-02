-- Writes www/state.json, www/progress.json and the static www/index.html research console.
-- The indicator on the page is the champion's held-out solve rate with a Wilson 95% interval;
-- it only moves when a candidate has passed the kernel's acceptance rule.
local json = require("rsi.kernel.json")
local M = {}

M.HTML_VERSION = 3

function M.write_progress(root, p)
  p.time = os.time()
  json.write(root .. "/www/progress.json", p)
end

function M.write_state(root, s)
  s.time = os.time()
  json.write(root .. "/www/state.json", s)
end

local HTML = [==[<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>CELL4 RSI console</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<style>
:root{--bg:#0b0e11;--panel:#12171c;--ink:#e6edf3;--mute:#8b98a5;--ok:#3fb950;--bad:#f85149;--warn:#d29922;--acc:#58a6ff;--line:#22282f}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
header{padding:18px 24px;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:8px}
h1{margin:0;font-size:16px;letter-spacing:.08em;text-transform:uppercase}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;padding:14px 24px}
section{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px;min-width:0;overflow:auto}
h2{margin:0 0 10px;font-size:12px;color:var(--mute);letter-spacing:.1em;text-transform:uppercase}
.big{font-size:44px;font-weight:600;line-height:1}
.ci{color:var(--mute)} .ok{color:var(--ok)} .bad{color:var(--bad)} .warn{color:var(--warn)} .acc{color:var(--acc)}
table{border-collapse:collapse;width:100%} td,th{padding:4px 6px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;font-size:12px}
th{color:var(--mute);font-weight:normal}
.bar{height:8px;background:#1c2430;border-radius:4px;overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;background:var(--acc)}
svg{width:100%;height:220px;display:block} .wide{grid-column:1/-1}
.kv{display:grid;grid-template-columns:auto 1fr;gap:2px 12px} .kv b{color:var(--mute);font-weight:normal}
small{color:var(--mute)} ul{margin:0;padding-left:18px}
</style></head><body>
<header><h1>CELL4 &middot; recursive self-improvement console</h1><div id="hdr"><small>loading&hellip;</small></div></header>
<main>
<section><h2>Champion &middot; held-out solve rate</h2><div class="big" id="score">&ndash;</div><div class="ci" id="score_ci"></div>
<div class="kv" id="champ_kv" style="margin-top:10px"></div></section>
<section><h2>Live activity</h2><div id="phase">idle</div><div class="bar"><i id="pbar" style="width:0%"></i></div><div id="ptext" class="ci"></div>
<div class="kv" id="live_kv" style="margin-top:10px"></div></section>
<section><h2>Benchmarks</h2><div class="kv" id="bench_kv"></div></section>
<section class="wide"><h2>Champion held-out score by generation (accepted &#9679; rejected &#215; candidates)</h2><svg id="chart" viewBox="0 0 1000 220" preserveAspectRatio="none"></svg></section>
<section class="wide"><h2>Lineage (latest first)</h2><table><thead><tr><th>gen</th><th>operator</th><th>change</th><th>held-out &Delta;</th><th>p</th><th>adv &Delta;</th><th>regr</th><th>verdict</th></tr></thead><tbody id="lineage"></tbody></table></section>
<section><h2>Research feed</h2><div id="research"></div></section>
<section><h2>Learned library (champion)</h2><div id="lib"></div></section>
<section class="wide"><h2>What is real here / what is not</h2><ul>
<li>The score is the champion's solve rate on tasks generated from a <b>secret salt the genome never sees</b>; a solve requires the found program to be correct on a held-out test example of the task, not just the training pairs.</li>
<li>A candidate is retained only if its paired held-out gain is significant under <b>both</b> the bootstrap and the exact sign test (&alpha;=0.05 each; either test alone lets through a 3-win, 0-loss candidate that is not real evidence), it loses nothing on the regression suite, it does not drop on the fresh adversarial split, and its visible-split gain is not out of proportion to its held-out gain (overfit check).</li>
<li>Candidates are produced by operators that use the system's own experimental data: library learning from solved programs, near-miss abstraction, prior fitting, enumeration reordering, constant and hyperparameter changes, DSL pruning. Operator selection adapts to which operators have produced accepted candidates.</li>
<li>Internet research pulls fresh ARC tasks into the external, never-trained-on evaluation and logs recent arXiv abstracts for the human. <b>No language model is used anywhere</b>; therefore the system does not derive mechanisms from papers. That is a fundamental limitation of an LLM-free design, not hidden.</li>
<li>Held-out seeds rotate and harder family variants are spawned automatically when one family drives repeated acceptances.</li>
</ul></section>
</main>
<script>
const $=id=>document.getElementById(id);
const pct=x=>(100*x).toFixed(1)+'%';
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
async function load(){
  try{
    const s=await (await fetch('state.json?'+Date.now())).json();
    let p={};try{p=await (await fetch('progress.json?'+Date.now())).json();}catch(e){}
    let lines=[];try{const t=await (await fetch('lineage.jsonl?'+Date.now())).text();lines=t.trim().split('\n').filter(Boolean).map(l=>{try{return JSON.parse(l)}catch(e){return null}}).filter(Boolean);}catch(e){}
    render(s,p,lines);
  }catch(e){$('hdr').innerHTML='<small class="bad">state.json unavailable: '+esc(e)+'</small>';}
}
function render(s,p,lines){
  const age=Math.round(Date.now()/1000-s.time);
  $('hdr').innerHTML='<small>generation <b>'+s.gen+'</b> &middot; champion <b>'+esc(s.champion.fingerprint)+'</b> &middot; state age '+age+'s'+(age>900?' <span class="warn">(stale?)</span>':'')+'</small>';
  const c=s.champion;
  $('score').textContent=pct(c.heldout.rate);
  $('score_ci').textContent='95% CI '+pct(c.heldout.lo)+' – '+pct(c.heldout.hi)+' on '+c.heldout.n+' secret-salted tasks (epoch '+s.bench.epoch+')';
  $('champ_kv').innerHTML=['partial credit',pct(c.heldout.partial),'adversarial',pct(c.adversarial.rate)+' (n='+c.adversarial.n+')','regression suite',c.regression.solved+'/'+c.regression.n,'external ARC',c.external.n?c.external.solved+'/'+c.external.n:'no ARC tasks yet','mean nodes / task',c.heldout.nodes.toFixed(0),'library size',c.library_size,'visible ops',c.ops,'accepted so far',s.accepted_total+' of '+s.candidates_total+' candidates'].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  const pa=p.time?Math.round(Date.now()/1000-p.time):null;
  $('phase').innerHTML=esc(p.phase||'idle')+(pa!==null?' <small>('+pa+'s ago)</small>':'');
  const frac=p.total?p.done/p.total:0;$('pbar').style.width=(100*frac).toFixed(1)+'%';
  $('ptext').textContent=p.total?p.done+'/'+p.total+' tasks, '+p.solved+' solved so far':'';
  $('live_kv').innerHTML=['candidate',p.candidate||'–','operator',p.operator||'–','change',p.change||'–','next research',s.research.next_in_s!=null?Math.max(0,s.research.next_in_s)+'s':'–'].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  const b=s.bench;
  $('bench_kv').innerHTML=['held-out epoch',b.epoch,'active families',b.families.join(', '),'burned',b.burned.length?b.burned.join(', '):'none','variants spawned',b.variants.length?b.variants.join(', '):'none','pressure',Object.entries(b.pressure).filter(x=>x[1]>0).map(x=>x[0]+':'+x[1]).join(' ')||'none','rotations',b.rotations,'regression tasks',b.regression_size,'ARC tasks on disk',b.arc_on_disk].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  // chart
  const pts=lines.map(l=>({g:l.gen,champ:l.champion_heldout,cand:l.candidate_heldout,acc:l.accepted}));
  const W=1000,H=220,px=40,py=14;
  let svg='';
  if(pts.length){
    const gmin=pts[0].g,gmax=Math.max(pts[pts.length-1].g,gmin+1);
    const X=g=>px+(g-gmin)/(gmax-gmin)*(W-2*px),Y=v=>H-py-v*(H-2*py);
    for(let v=0;v<=1;v+=0.25)svg+='<line x1="'+px+'" x2="'+(W-px)+'" y1="'+Y(v)+'" y2="'+Y(v)+'" stroke="#22282f"/><text x="4" y="'+(Y(v)+4)+'" fill="#8b98a5" font-size="11">'+Math.round(v*100)+'%</text>';
    let d='';pts.forEach((q,i)=>{const s2=q.acc?q.cand:q.champ;d+=(i?'L':'M')+X(q.g)+','+Y(s2)+' ';});
    svg+='<path d="'+d+'" fill="none" stroke="#58a6ff" stroke-width="2"/>';
    pts.forEach(q=>{svg+=q.acc?'<circle cx="'+X(q.g)+'" cy="'+Y(q.cand)+'" r="5" fill="#3fb950"/>':'<text x="'+(X(q.g)-4)+'" y="'+(Y(q.cand)+4)+'" fill="#f85149" font-size="12">×</text>';});
  }
  $('chart').innerHTML=svg;
  $('lineage').innerHTML=lines.slice().reverse().slice(0,40).map(l=>'<tr><td>'+l.gen+'</td><td>'+esc(l.operator)+'</td><td>'+esc(l.change)+'</td><td class="'+(l.heldout_delta>0?'ok':l.heldout_delta<0?'bad':'')+'">'+(l.heldout_delta>=0?'+':'')+(100*l.heldout_delta).toFixed(1)+'pp</td><td>'+(l.p_value!=null?l.p_value.toFixed(3):'')+'</td><td>'+(l.adversarial_delta!=null?((l.adversarial_delta>=0?'+':'')+(100*l.adversarial_delta).toFixed(1)+'pp'):'')+'</td><td>'+esc(l.regression||'')+'</td><td class="'+(l.accepted?'ok':'bad')+'">'+(l.accepted?'ACCEPT':'reject')+': '+esc(l.reason)+'</td></tr>').join('');
  $('research').innerHTML=(s.research.papers||[]).map(r=>'<div><small>'+esc((r.published||'').slice(0,10))+'</small> '+esc(r.title)+(r.signals&&r.signals.length?' <small class="acc">['+esc(r.signals.join(', '))+']</small>':'')+'</div>').join('')||'<small>no papers fetched yet (needs outbound HTTPS from the server)</small>';
  $('lib').innerHTML=(c.library||[]).map(e=>'<div><b class="acc">'+esc(e.name)+'</b> = '+esc(e.expr)+' <small>'+esc(e.arg)+(e.arg2?','+esc(e.arg2):'')+'→'+esc(e.ret)+' &middot; '+esc(e.origin||'')+'</small></div>').join('')||'<small>empty: nothing learned yet</small>';
}
load();setInterval(load,4000);
</script></body></html>
]==]

function M.ensure_html(root)
  local path = root .. "/www/index.html"
  local f = io.open(path, "r")
  local cur = f and f:read("*a") or nil
  if f then f:close() end
  if cur ~= HTML then
    local w = assert(io.open(path, "w"))
    w:write(HTML)
    w:close()
  end
end

return M
