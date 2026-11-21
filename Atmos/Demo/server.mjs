import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { catalog, catalogRevision, InputError, newState, trackerFor, updateState, searchLocalMemory, guideForVisit, itineraryBriefing, dinnerTextFor } from './scenario.mjs';
import { createMemoryWorker } from './memory.mjs';
import { createObserver } from './observer.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const publicRoot = resolve(here,'public');
const types = { '.html':'text/html; charset=utf-8', '.css':'text/css', '.js':'text/javascript', '.jpg':'image/jpeg', '.png':'image/png', '.svg':'image/svg+xml', '.webp':'image/webp' };
const hash = value => createHash('sha256').update(value).digest('hex');
const token = () => randomBytes(32).toString('hex');
function json(res,status,body) {
  res.writeHead(status,{'Content-Type':'application/json; charset=utf-8'}); res.end(JSON.stringify(body));
}
async function body(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new InputError('Send a JSON request.');
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 32768) throw new InputError('The briefing is too long.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString()); }
  catch { throw new InputError('The request is not valid JSON.'); }
}

export function createDemo({filename=':memory:',env={}} = {}) {
  if (filename !== ':memory:') mkdirSync(dirname(resolve(filename)), {recursive:true});
  const db = new DatabaseSync(filename);
  db.exec(`PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS guide (id INTEGER PRIMARY KEY CHECK(id = 1), version TEXT NOT NULL, snapshot TEXT NOT NULL);`);
  db.prepare(`INSERT INTO guide VALUES (1,?,?) ON CONFLICT(id) DO UPDATE SET
    version=excluded.version,snapshot=excluded.snapshot WHERE guide.version != excluded.version`).run(catalogRevision,JSON.stringify(catalog));
  const sharedGuide = JSON.parse(db.prepare('SELECT snapshot FROM guide WHERE id=1').get().snapshot);
  const memory = createMemoryWorker(db,env);
  const observer = createObserver(db,{enabled:env.ATMOS_DEMO_LIVE_SOURCES === '1'});
  observer.start();
  memory.queueShared(sharedGuide);
  memory.start();
  // The browser holds its visit key only for the lifetime of this document.
  const visits = new Map();
  const handoffs = new Map();
  const visitLifetime = 4*60*60_000;
  const cleanup = setInterval(() => {
    const now = Date.now();
    for (const records of [visits,handoffs]) {
      for (const [id,entry] of records) if (entry.expires <= now) records.delete(id);
    }
  },60_000).unref();
  function visitor(req,res) {
    const key = req.headers['x-atmos-visit'];
    if (key !== undefined) {
      const visit = visits.get(hash(key));
      if (!visit || visit.expires <= Date.now()) return null;
      visit.expires = Date.now()+visitLifetime;
      return visit;
    }
    const fresh = token();
    const visit = {id:hash(fresh),state:newState(),expires:Date.now()+visitLifetime};
    visits.set(visit.id,visit);
    res.setHeader('X-Atmos-Visit',fresh);
    return visit;
  }
  function issueHandoff(stage,state,expires) {
    const key = token();
    handoffs.set(hash(stage+key),{state,expires});
    return key;
  }
  function takeHandoff(stage,key) {
    if (typeof key !== 'string' || !/^[0-9a-f]{64}$/.test(key)) return;
    const id = hash(stage+key);
    const entry = handoffs.get(id);
    handoffs.delete(id);
    if (entry && entry.expires > Date.now()) return entry;
  }
  const server = createServer(async (req,res) => {
    res.setHeader('Cache-Control','no-store');
    res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('X-Content-Type-Options','nosniff');
    res.setHeader('Content-Security-Policy',"default-src 'self'; img-src 'self' data: https://boichikbagels.com; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    try {
      const host = req.headers.host;
      const port = server.address().port;
      if (![ `127.0.0.1:${port}`, `localhost:${port}` ].includes(host)) return json(res,403,{error:'Use the local demo address.'});
      const url = new URL(req.url,'http://'+host);
      if (req.method === 'POST' && req.headers.origin && req.headers.origin !== 'http://'+host) return json(res,403,{error:'Open the demo on this device.'});
      if (url.pathname === '/api/handoff' && req.method === 'POST') {
        if (req.headers['x-atmos-client'] !== 'native-demo') return json(res,403,{error:'Native demo handoff required.'});
        const input = await body(req);
        const checked = updateState(newState(),{action:'start',transcript:input?.transcript});
        const ticket = issueHandoff('native',checked,Date.now()+60_000);
        return json(res,201,{ticket});
      }
      const match = /^\/handoff\/([0-9a-f]{64})$/.exec(url.pathname);
      if (req.method === 'GET' && match) {
        const handoff = takeHandoff('native',match[1]);
        if (!handoff) return json(res,410,{error:'This one-time briefing has expired.'});
        const claim = issueHandoff('browser',handoff.state,handoff.expires);
        res.writeHead(303,{Location:'/#planning='+claim}); return res.end();
      }
      if (url.pathname === '/api/demo' && ['GET','POST'].includes(req.method)) {
        const input = req.method === 'POST' ? await body(req) : null;
        const v = visitor(req,res);
        if (!v) return json(res,410,{error:'This visit expired. Reload to start a fresh trip.'});
        if (req.method === 'POST') {
          if (input?.revision !== undefined && input.revision !== v.state.revision) return json(res,409,{error:'The plan changed. Review your latest choices.'});
          if (input?.action === 'handoff') {
            if (v.state.started) throw new InputError('Open the handoff in a fresh visit.');
            const handoff = takeHandoff('browser',input.ticket);
            if (!handoff) return json(res,410,{error:'This one-time briefing has expired.'});
            v.state = handoff.state;
          } else {
            const updated = updateState(v.state,input);
            if (['choose','skip','reroute','reset'].includes(input.action)) memory.queueVisitor(v.id,updated);
            v.state = updated;
          }
        }
        const evidence = observer.snapshot();
        const guide = guideForVisit(sharedGuide,v.state,evidence);
        const tracker = trackerFor(v.state);
        const dinnerTextDraft = dinnerTextFor(v.state,tracker);
        return json(res,200,{catalog:guide,state:v.state,tracker,
          dinnerTextDraft,briefing:itineraryBriefing(v.state,tracker),memoryStatus:memory.status(v.id),evidence});
      }
      if (url.pathname === '/api/recall' && req.method === 'POST') {
        const input = await body(req);
        if (!['private','shared'].includes(input?.scope) || typeof input.query !== 'string' || !input.query.trim() || input.query.length>500) {
          throw new InputError('Choose a memory and enter a question of up to 500 characters.');
        }
        const v = visitor(req,res);
        if (!v) return json(res,410,{error:'This visit expired. Reload to start a fresh trip.'});
        const remote = await memory.recall(v.id,input.query,input.scope);
        if (remote.status === 'ready' && remote.results.length) return json(res,200,{status:'Cognee test memory',results:remote.results});
        // A reset or edit may have happened while the remote lookup was pending.
        const latest = v.state;
        const results = searchLocalMemory(guideForVisit(sharedGuide,latest,observer.snapshot()),latest,input.scope,input.query);
        const source = input.scope === 'private' ? 'From this visit' : 'From the local city guide';
        return json(res,200,{status:results.length ? source : 'No matching facts in this memory',results});
      }
      if (!['GET','HEAD'].includes(req.method)) return json(res,405,{error:'Method unavailable.'});
      const path = resolve(publicRoot,'.'+(url.pathname === '/' ? '/index.html' : decodeURIComponent(url.pathname)));
      if (!path.startsWith(publicRoot+sep) || !types[extname(path)]) return json(res,404,{error:'Page not found.'});
      const content = await readFile(path);
      res.writeHead(200,{'Content-Type':types[extname(path)]}); res.end(req.method === 'HEAD' ? undefined : content);
    } catch (err) {
      if (err instanceof InputError || err instanceof URIError) return json(res,400,{error:err.message});
      if (err.code === 'ENOENT' || err.code === 'EISDIR') return json(res,404,{error:'Page not found.'});
      console.error('Local demo request failed:',err.name);
      return json(res,500,{error:'The local demo could not complete this request.'});
    }
  });
  server.on('close',()=>{ clearInterval(cleanup); void Promise.all([observer.stop(),memory.stop()]).finally(()=>db.close()); });
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const port = Number(process.env.ATMOS_DEMO_PORT ?? 4317);
  const server = createDemo({filename:process.env.ATMOS_DEMO_DB ?? resolve(here,'.sandbox','atmos.sqlite'),env:process.env});
  server.on('error',err => { console.error(`Could not start the test environment: ${err.message}`); process.exitCode=1; });
  server.listen(port,'127.0.0.1',()=>console.log(`Atmos test itinerary: http://127.0.0.1:${server.address().port}`));
}
