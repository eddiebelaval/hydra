// datatech-emit-todo-sensor - publish Data-Tech's open todos as a living sensor.
//
// Portfolio parallel to lexicon/scripts/emit-todo-sensor.ts. The morning briefing
// reads "living sensors" (one small JSON per job, ONE common schema) and
// ~/.hydra/tools/master-todo.py merges + ranks them. This is Data-Tech's emitter.
//
//   node --env-file=$HOME/Development/datatech-site/.env.local \
//        $HOME/.hydra/tools/datatech-emit-todo-sensor.mjs
//
// DEPENDENCY-FREE BY DESIGN. It queries the live catalog over PostgREST with the
// service-role key (built-in fetch, no @supabase/supabase-js) so it can live in the
// tool fleet next to master-todo.py instead of inside the client repo. The env-file
// carries SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY; node reads it regardless of where
// this script sits. It only READS the DB and READS the owes file, and WRITES the
// sensor - it never mutates the client platform.
//
// TWO SOURCES (read before "improving" it):
//   1. WRITTEN / owes  - human decisions the DB cannot see (Nixon access call, Marcos
//      tie rule). Operator-maintained at ~/.hydra/sensors/owes/datatech.json. Tickable.
//   2. DERIVED         - gates the live catalog reports as measurable state: products
//      with no image (Nixon imagery), and the seed->live swap being unexercised
//      (Yadira export). Recomputed every run, so they can NEVER go stale. NOT tickable:
//      a derived item closes when the catalog changes, never by ticking it.
//
// If the DB is unreachable it emits WRITTEN-ONLY and says so on stderr - a sensor that
// cannot read a source must page, never fake a clean list. If BOTH sources are empty
// it emits an EMPTY sensor and says so.
//
// Data-Tech has NO todo table and must not get one: the live Supabase project is the
// RLS-hardened client customer platform. This emitter adds no schema to it.

import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const JOB = 'datatech';
const WHO = 'Data-Tech';
const HOME_REPO = { repo: 'eddiebelaval/datatech-site', kind: 'customer-platform' };
const SENSOR_DIR = join(homedir(), '.hydra', 'sensors', 'todos');
const OWES_PATH = join(homedir(), '.hydra', 'sensors', 'owes', 'datatech.json');

const PRIORITY_RANK = { urgent: 1, high: 8, normal: 20, low: 30, derived: 15 };

function sensorItem({ title, priority, rank, dueOn, pod, source, completable, id }) {
  return { title, priority, rank, dueOn: dueOn ?? null, pod: pod ?? null, source, completable, id };
}

function stamp(now) {
  const p = (n) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}T${p(now.getHours())}:${p(now.getMinutes())}`;
}

function slug(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40);
}

// ---- source 1: written / owes (human decisions) ------------------------------
function loadOwes() {
  if (!existsSync(OWES_PATH)) return [];
  try {
    const parsed = JSON.parse(readFileSync(OWES_PATH, 'utf8'));
    const rows = Array.isArray(parsed) ? parsed : Array.isArray(parsed.owes) ? parsed.owes : [];
    return rows.filter((r) => !r.done);
  } catch (e) {
    console.error(`owes: could not read ${OWES_PATH}: ${e.message}`);
    return [];
  }
}

function owesToItems(owes) {
  return owes.map((r) => {
    const priority = PRIORITY_RANK[r.priority] ? r.priority : 'high';
    return sensorItem({
      title: r.title,
      priority,
      rank: PRIORITY_RANK[priority],
      dueOn: r.dueOn ?? null,
      pod: r.owner ?? null, // reuse `pod` as owner-of-record; the master shows it in parens
      source: 'written',
      completable: true,
      id: r.id ?? `owes:${slug(r.title)}`,
    });
  });
}

// ---- source 2: derived from the live catalog (PostgREST, read-only) ----------
// Returns { items, reachable }. reachable=false means the DB could not be read, so the
// caller degrades to written-only rather than pretending the derived gates are closed.
async function deriveFromDb() {
  const base = (process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL ?? '').replace(/\/$/, '');
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!base || !key) {
    console.error('derived: no SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY - emitting written-only');
    return { items: [], reachable: false };
  }

  // Exact row count via the Content-Range header (head-style: no rows transferred).
  async function count(query) {
    const res = await fetch(`${base}/rest/v1/${query}`, {
      method: 'GET',
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        Prefer: 'count=exact',
        Range: '0-0',
      },
    });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText} on ${query}`);
    const cr = res.headers.get('content-range') || '';
    const total = cr.includes('/') ? parseInt(cr.split('/')[1], 10) : NaN;
    if (Number.isNaN(total)) throw new Error(`no count in content-range ("${cr}") on ${query}`);
    return total;
  }

  const items = [];
  try {
    const total = await count('products?select=id');
    const noImg = await count('products?select=id&image_url=is.null&or=(image_urls.is.null,image_urls.eq.{})');
    const live = await count('products?select=id&source=eq.live');

    if (noImg > 0) {
      items.push(sensorItem({
        title: `Nixon: product imagery - ${noImg} of ${total} catalog products have no image`,
        priority: 'derived',
        rank: PRIORITY_RANK.derived,
        dueOn: null,
        pod: 'Nixon',
        source: 'derived',
        completable: false,
        id: 'derived:catalog-no-image',
      }));
    }
    if (live === 0) {
      items.push(sensorItem({
        title: 'Yadira: ACCPAC export - catalog still all seed data, the source=live swap is unexercised',
        priority: 'derived',
        rank: PRIORITY_RANK.derived,
        dueOn: null,
        pod: 'Yadira',
        source: 'derived',
        completable: false,
        id: 'derived:seed-only',
      }));
    }
    return { items, reachable: true };
  } catch (e) {
    console.error(`derived: catalog query failed (${e.message}) - emitting written-only`);
    return { items, reachable: false };
  }
}

async function main() {
  const now = new Date();

  const written = owesToItems(loadOwes());
  const { items: derived, reachable } = await deriveFromDb();
  const items = [...written, ...derived].sort((a, b) => a.rank - b.rank || a.title.localeCompare(b.title));

  const sensor = {
    job: JOB,
    who: WHO,
    home: HOME_REPO,
    generatedAt: stamp(now),
    counts: { open: items.length, written: written.length, derived: derived.length },
    dbReachable: reachable,
    items,
  };

  mkdirSync(SENSOR_DIR, { recursive: true });
  const path = join(SENSOR_DIR, `${JOB}.json`);
  writeFileSync(path, JSON.stringify(sensor, null, 2));

  if (!reachable) {
    console.error('NOTE: catalog was unreachable - derived gates (imagery, live-swap) are NOT in this sensor. Fix the env/DB before trusting the list.');
  }
  if (items.length === 0) {
    console.error('NOTE: emitted an EMPTY sensor - no owes and no derived items. Honest, not broken.');
  }
  console.log(`  emitted ${JOB} sensor: ${items.length} open (${written.length} written, ${derived.length} derived, db ${reachable ? 'reachable' : 'UNREACHABLE'})`);
  console.log(`  ${path}`);
}

main().catch((e) => {
  console.error(e.stack ?? e.message ?? e);
  process.exit(1);
});
