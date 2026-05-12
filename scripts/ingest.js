/**
 * EQX Doubles — Nightly Schedule Ingest
 *
 * Fetches the weekly PDF for every NYC Equinox club,
 * parses the schedule, and upserts into Supabase.
 *
 * Usage:
 *   node ingest.js                        # all 36 clubs
 *   node ingest.js --club 102,110,116     # specific clubs only
 *
 * Required env vars (set as GitHub Secrets):
 *   SUPABASE_URL        https://hprkoonlydcjqxrgjwtr.supabase.co
 *   SUPABASE_SECRET_KEY sb_secret_...
 */

import { createClient } from '@supabase/supabase-js';
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs';

// ─────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SECRET_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
  console.error('Missing SUPABASE_URL or SUPABASE_SECRET_KEY env vars');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

const PDF_URL = (id) =>
  `https://www.equinox.com/groupfitness/classes/download/${id}/pdf`;

const CONCURRENCY = 5;   // parallel PDF fetches
const FETCH_TIMEOUT_MS = 25_000;

// All NYC club IDs
const ALL_CLUB_IDS = [
  110, 128, 111, 122, 114, 135, 124, 162, 112, 116,
  102, 136, 160, 138, 127, 108, 109, 126, 133, 106,
  115, 139, 107, 113, 132, 105, 117, 104, 129, 131,
  121, 103, 130, 134, 161, 137,
];

// ─────────────────────────────────────────────────────────
// CATEGORY MAPPING
// Each class name is matched against these keywords (first match wins).
// Must stay in sync with the CATEGORIES constant in index.html.
// ─────────────────────────────────────────────────────────
const CATEGORY_MAP = [
  { cat: 'barre',      kw: ['true barre', 'barre', 'off the barre'] },
  { cat: 'pilates',    kw: ['pilates mat', 'pilates fusion', 'pilates rise', 'pilates at the barre', 'precision pilates', 're-formation pilates', 'pilates'] },
  { cat: 'figure4',    kw: ['figure 4'] },
  { cat: 'sculpt',     kw: ['cardio sculpt', 'body sculpt', 'rhythmic sculpt', 'barefoot sculpt', 'hydro sculpt', 'tai sculpt', 'vipr sculpt', 'sculpt'] },
  { cat: 'hiit',       kw: ['metcon', 'tabata', 'quick hiit', 'hiit', 'core6', 'atletica', 'stronger', '360 strength', 'stacked', 'circuit training', 'trx max', 'ropes and rowers', 'superset athlete', 'the cut', 'firestarter', 'impact!', 'whipped'] },
  { cat: 'strength',   kw: ['pure strength', 'upper body pump', 'lower body blast', 'ultimate resistance', 'forza', 'athletic conditioning'] },
  { cat: 'cycling',    kw: ['beats ride', 'rhythm ride', 'anthem ride', 'theme ride', 'endurance ride', 'precision ride', 'ride', 'cycle', 'spin', 'pursuit'] },
  { cat: 'running',    kw: ['precision run', 'vessel run', 'precision walk', 'switch up: run', 'tread'] },
  { cat: 'boxing',     kw: ['rounds: boxing', 'rounds: kickboxing', 'rounds: bags', 'rounds: pro', 'rounds: mitts', 'rounds', 'cardio kickboxing', 'kickbox burn', 'knockout', 'powerstrike', 'shadow-do', 'muay thai', 'zen combat'] },
  { cat: 'dance',      kw: ['cardio dance', 'studio dance', 'feel good friday', 'calvinography', '305 dance', 'latin beats', 'zumba', 'danceo', 'nyc dance', 'jazz', 'contemporary'] },
  { cat: 'yoga',       kw: ['amplified vinyasa', 'inner power', 'inner warrior', 'ignite flow', 'sunrise vinyasa', 'sculpted yoga', 'slow flow', 'vinyasa', 'ashtanga', 'hatha', 'yoga'] },
  { cat: 'stretch',    kw: ['best stretch', 'athletic stretch', 'weekend wind down', 'yin/yang', 'gentle yoga', 'yin yoga', 'pure: restorative', 'pure: yin', 'restorative', 'stretch'] },
  { cat: 'meditation', kw: ['sonic meditation', 'yin yoga meditation', 'yin yoga + sound', 'pure: meditation', 'meditation'] },
  { cat: 'swim',       kw: ['aqua sport', 'h2sho', 'hydro athlete', 'swim'] },
];

function categorize(className) {
  const lower = className.toLowerCase();
  for (const { cat, kw } of CATEGORY_MAP) {
    if (kw.some((k) => lower.includes(k))) return cat;
  }
  return 'other';
}

// ─────────────────────────────────────────────────────────
// PDF PARSER  (ported directly from index.html parseSchedule())
// ─────────────────────────────────────────────────────────
const DAYS = new Set(['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY']);
const TIME_RE = /^(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$/;
const STU_RE  = /^[A-Z]{1,3}\s*\*?\s*$|^[A-Z]{1,3}\s+\*$/;
const SKIP    = new Set(['BOLD', '*', 'KEY']);
const SKIP_RE = /^(VISIT EQUINOX|SCHEDULE EFFECTIVE|Studio key|New\/Updated|Advance sign)/i;

function resolveHour(h, m, dayLastMins) {
  if (h === 12) return { mins: 720 + m, dayLastMins: 720 + m };
  const amMins = h * 60 + m;
  const pmMins = amMins + 720;
  if (h >= 1 && h <= 4) return { mins: pmMins, dayLastMins: pmMins };
  if (dayLastMins !== null && dayLastMins >= 720) return { mins: pmMins, dayLastMins: pmMins };
  if (dayLastMins !== null && amMins < dayLastMins - 60) return { mins: pmMins, dayLastMins: pmMins };
  return { mins: amMins, dayLastMins: amMins };
}

function parseTimePair(raw, dayLastMins) {
  const parts = raw.split('-');
  const [sh, sm] = parts[0].split(':').map(Number);
  const [eh, em] = parts[1].split(':').map(Number);
  const s = resolveHour(sh, sm, dayLastMins);
  const e = resolveHour(eh, em, s.dayLastMins);
  return {
    sMins: s.mins,
    eMins: e.mins > s.mins ? e.mins : s.mins + 45,
    dayLastMins: e.dayLastMins,
  };
}

function parseSchedule(text, clubId) {
  const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 1);
  const out = [];
  let day = null;
  let dayLastMins = null;
  let i = 0;

  while (i < lines.length) {
    const l = lines[i];

    if (DAYS.has(l.toUpperCase())) {
      day = l.toUpperCase();
      dayLastMins = null;
      i++;
      continue;
    }

    const tm = l.match(TIME_RE);
    if (tm && day) {
      const parsed = parseTimePair(l, dayLastMins);
      dayLastMins = parsed.dayLastMins;
      i++;

      let name = '', instructor = '';
      while (i < lines.length) {
        const ln = lines[i];
        if (DAYS.has(ln.toUpperCase()) || ln.match(TIME_RE)) break;
        if (ln.match(STU_RE)) {
          i++;
          if (
            i < lines.length &&
            !lines[i].match(TIME_RE) &&
            !DAYS.has(lines[i].toUpperCase()) &&
            !lines[i].match(STU_RE)
          ) {
            instructor = lines[i];
            i++;
          }
          break;
        }
        if (!SKIP.has(ln.toUpperCase()) && !SKIP_RE.test(ln)) {
          name += (name ? ' ' : '') + ln;
        }
        i++;
      }

      if (name.length > 1) {
        out.push({
          club_id: clubId,
          class_name: name.trim(),
          category: categorize(name.trim()),
          instructor: instructor.trim() || null,
          day_of_week: day,
          start_mins: parsed.sMins,
          end_mins: parsed.eMins,
          pdf_fetched_at: new Date().toISOString(),
        });
      }
      continue;
    }
    i++;
  }
  return out;
}

// ─────────────────────────────────────────────────────────
// PDF FETCH
// ─────────────────────────────────────────────────────────
async function fetchAndParse(clubId) {
  const url = PDF_URL(clubId);
  const res = await fetch(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`HTTP ${res.status} for club ${clubId}`);

  const buf = await res.arrayBuffer();
  if (buf.byteLength < 1000) throw new Error(`PDF too small for club ${clubId}`);

  const pdf = await pdfjs.getDocument({ data: new Uint8Array(buf) }).promise;
  let text = '';
  for (let p = 1; p <= pdf.numPages; p++) {
    const page = await pdf.getPage(p);
    const tc = await page.getTextContent();
    text += tc.items.filter((i) => i.str.trim()).map((i) => i.str).join('\n') + '\n';
  }

  return parseSchedule(text, clubId);
}

// ─────────────────────────────────────────────────────────
// SUPABASE UPSERT
// ─────────────────────────────────────────────────────────
async function upsertClub(clubId, rows) {
  if (!rows.length) {
    console.log(`  [${clubId}] 0 classes parsed — skipping`);
    return;
  }

  // Delete old rows for this club so stale classes don't linger.
  // (upsert ON CONFLICT won't remove classes that no longer exist)
  await supabase.from('classes').delete().eq('club_id', clubId);

  const { error } = await supabase
    .from('classes')
    .insert(rows);

  if (error) throw new Error(`Supabase insert failed for club ${clubId}: ${error.message}`);
  console.log(`  [${clubId}] ✓ ${rows.length} classes`);
}

// ─────────────────────────────────────────────────────────
// CONCURRENCY HELPER
// ─────────────────────────────────────────────────────────
async function withConcurrency(ids, limit, fn) {
  const results = new Array(ids.length);
  let idx = 0;
  async function worker() {
    while (idx < ids.length) {
      const i = idx++;
      try { results[i] = { ok: true, value: await fn(ids[i]) }; }
      catch (e) { results[i] = { ok: false, error: e }; }
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, ids.length) }, worker));
  return results;
}

// ─────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────
async function main() {
  // Allow --club 102,110 to run specific clubs only
  const clubArg = process.argv.indexOf('--club');
  const clubIds =
    clubArg !== -1
      ? process.argv[clubArg + 1].split(',').map(Number)
      : ALL_CLUB_IDS;

  console.log(`\nEQX Doubles — ingesting ${clubIds.length} clubs\n`);
  const start = Date.now();

  const results = await withConcurrency(clubIds, CONCURRENCY, async (id) => {
    process.stdout.write(`  [${id}] fetching…\r`);
    const rows = await fetchAndParse(id);
    await upsertClub(id, rows);
    return rows.length;
  });

  const failed = results
    .map((r, i) => (!r.ok ? clubIds[i] : null))
    .filter(Boolean);

  const total = results.reduce((sum, r) => sum + (r.ok ? r.value : 0), 0);
  const elapsed = ((Date.now() - start) / 1000).toFixed(1);

  console.log(`\n─────────────────────────────────`);
  console.log(`✓ ${total} classes upserted in ${elapsed}s`);
  if (failed.length) console.warn(`✗ Failed clubs: ${failed.join(', ')}`);
  console.log(`─────────────────────────────────\n`);

  if (failed.length === clubIds.length) process.exit(1);
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
