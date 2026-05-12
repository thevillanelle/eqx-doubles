-- ═══════════════════════════════════════════════════════════
-- EQX Doubles — Supabase Schema
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ═══════════════════════════════════════════════════════════

-- ── 1. CLUBS (static seed data) ──────────────────────────
CREATE TABLE IF NOT EXISTS clubs (
  id           INTEGER PRIMARY KEY,
  name         TEXT    NOT NULL,
  neighborhood TEXT    NOT NULL,
  lat          NUMERIC(10,7) NOT NULL,
  lng          NUMERIC(10,7) NOT NULL
);

INSERT INTO clubs (id, name, neighborhood, lat, lng) VALUES
  (110,'Wall Street',       'Downtown & Tribeca',    40.7074,-74.0113),
  (128,'Brookfield Place',  'Downtown & Tribeca',    40.7136,-74.0150),
  (111,'Tribeca',           'Downtown & Tribeca',    40.7163,-74.0086),
  (122,'Orchard Street',    'LES & SoHo',            40.7194,-73.9884),
  (114,'SoHo',              'LES & SoHo',            40.7230,-73.9997),
  (135,'Bond Street',       'LES & SoHo',            40.7264,-73.9924),
  (124,'Printing House',    'West Village & Chelsea',40.7262,-74.0081),
  (162,'Hudson Square',     'West Village & Chelsea',40.7278,-74.0072),
  (112,'Greenwich Avenue',  'West Village & Chelsea',40.7350,-74.0021),
  (116,'High Line',         'West Village & Chelsea',40.7484,-74.0048),
  (102,'Flatiron',          'Flatiron & Nomad',      40.7393,-73.9908),
  (136,'Gramercy',          'Flatiron & Nomad',      40.7385,-73.9840),
  (160,'Nomad',             'Flatiron & Nomad',      40.7448,-73.9882),
  (138,'Hudson Yards',      'Hudson Yards',          40.7540,-74.0009),
  (127,'Bryant Park',       'Midtown South',         40.7540,-73.9836),
  (108,'East 43rd Street',  'Midtown South',         40.7521,-73.9754),
  (109,'East 44th Street',  'Midtown South',         40.7536,-73.9739),
  (126,'Rockefeller Center','Midtown South',         40.7587,-73.9787),
  (133,'East 53rd Street',  'Midtown East',          40.7591,-73.9736),
  (106,'East 54th Street',  'Midtown East',          40.7593,-73.9716),
  (115,'Park Avenue',       'Midtown East',          40.7605,-73.9726),
  (139,'E Madison Avenue',  'Midtown East',          40.7640,-73.9721),
  (107,'West 50th Street',  'Midtown West',          40.7616,-73.9866),
  (113,'Columbus Circle',   'Midtown West',          40.7680,-73.9819),
  (132,'East 61st Street',  'Upper East Side',       40.7629,-73.9660),
  (105,'East 63rd Street',  'Upper East Side',       40.7648,-73.9649),
  (117,'East 74th Street',  'Upper East Side',       40.7732,-73.9561),
  (104,'East 85th Street',  'Upper East Side',       40.7780,-73.9547),
  (129,'East 92nd Street',  'Upper East Side',       40.7815,-73.9502),
  (131,'Sports Club NY',    'Upper West Side',       40.7650,-73.9820),
  (121,'West 76th Street',  'Upper West Side',       40.7818,-73.9803),
  (103,'West 92nd Street',  'Upper West Side',       40.7873,-73.9742),
  (130,'Brooklyn Heights',  'Brooklyn',              40.6936,-73.9926),
  (134,'DUMBO',             'Brooklyn',              40.7034,-73.9892),
  (161,'Domino',            'Brooklyn',              40.7134,-73.9647),
  (137,'Williamsburg',      'Brooklyn',              40.7081,-73.9571)
ON CONFLICT (id) DO NOTHING;


-- ── 2. CLASSES (refreshed nightly by GitHub Action) ──────
CREATE TABLE IF NOT EXISTS classes (
  id           UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  club_id      INTEGER NOT NULL REFERENCES clubs(id),
  class_name   TEXT    NOT NULL,
  -- canonical category used for filtering (see CATEGORY_MAP in ingest.js)
  category     TEXT    NOT NULL DEFAULT 'other',
  instructor   TEXT,
  day_of_week  TEXT    NOT NULL,  -- 'MONDAY', 'TUESDAY', etc.
  start_mins   INTEGER NOT NULL,  -- minutes since midnight (e.g. 390 = 6:30 AM)
  end_mins     INTEGER NOT NULL,
  -- which weekly PDF this came from (prevents mixing stale + fresh data)
  pdf_fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (club_id, day_of_week, start_mins, class_name)
);

CREATE INDEX IF NOT EXISTS idx_classes_club     ON classes(club_id);
CREATE INDEX IF NOT EXISTS idx_classes_day      ON classes(day_of_week);
CREATE INDEX IF NOT EXISTS idx_classes_category ON classes(category);
CREATE INDEX IF NOT EXISTS idx_classes_time     ON classes(start_mins);


-- ── 3. ROW LEVEL SECURITY ─────────────────────────────────
-- Schedules are public info — anyone can read, only service role can write.
ALTER TABLE clubs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE classes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public read clubs"   ON clubs;
DROP POLICY IF EXISTS "public read classes" ON classes;

CREATE POLICY "public read clubs"   ON clubs   FOR SELECT USING (true);
CREATE POLICY "public read classes" ON classes FOR SELECT USING (true);


-- ── 4. find_doubles() RPC ─────────────────────────────────
-- Called from the frontend as: supabase.rpc('find_doubles', { ... })
-- Does all the heavy lifting server-side so the browser just renders results.
--
-- Category aliases (p_cat1 / p_cat2 values):
--   any, barre-all, true-barre, pilates, figure4,
--   sculpt-all, sculpt, hiit, strength,
--   cardio-all, cycling, running, boxing, dance,
--   yoga-all, stretch, meditation, swim

CREATE OR REPLACE FUNCTION find_doubles(
  p_club_ids    INTEGER[],
  p_day         TEXT,        -- 'MONDAY', 'TUESDAY', etc.
  p_cat1        TEXT,
  p_cat2        TEXT,
  p_max_gap     INTEGER  DEFAULT 30,   -- minutes
  p_pair_order  TEXT     DEFAULT 'either',  -- 'either' | '1first' | '2first'
  p_win_start   INTEGER  DEFAULT 300,  -- minutes since midnight (5:00 AM)
  p_win_end     INTEGER  DEFAULT 1380  -- minutes since midnight (11:00 PM)
)
RETURNS TABLE (
  first_club_id    INTEGER,
  first_club_name  TEXT,
  first_club_nbhd  TEXT,
  first_class_name TEXT,
  first_start      INTEGER,
  first_end        INTEGER,
  first_instructor TEXT,
  second_club_id   INTEGER,
  second_club_name TEXT,
  second_club_nbhd TEXT,
  second_class_name TEXT,
  second_start     INTEGER,
  second_end       INTEGER,
  second_instructor TEXT,
  gap_minutes      INTEGER,
  same_club        BOOLEAN
) LANGUAGE sql STABLE AS $$
  WITH
  -- Expand category aliases to canonical category names
  expand_cat(alias, cats) AS (VALUES
    ('any',        ARRAY['barre','pilates','figure4','sculpt','hiit','strength','cycling','running','boxing','dance','yoga','stretch','meditation','swim','other']),
    ('barre-all',  ARRAY['barre','pilates','figure4']),
    ('true-barre', ARRAY['barre']),
    ('pilates',    ARRAY['pilates']),
    ('figure4',    ARRAY['figure4']),
    ('sculpt-all', ARRAY['sculpt','hiit','strength']),
    ('sculpt',     ARRAY['sculpt']),
    ('hiit',       ARRAY['hiit']),
    ('strength',   ARRAY['strength']),
    ('cardio-all', ARRAY['cycling','running','boxing','dance']),
    ('cycling',    ARRAY['cycling']),
    ('running',    ARRAY['running']),
    ('boxing',     ARRAY['boxing']),
    ('dance',      ARRAY['dance']),
    ('yoga-all',   ARRAY['yoga','stretch','meditation']),
    ('yoga',       ARRAY['yoga']),
    ('stretch',    ARRAY['stretch']),
    ('meditation', ARRAY['meditation']),
    ('swim',       ARRAY['swim']),
    ('other',      ARRAY['other'])
  ),
  cats1 AS (
    SELECT UNNEST(COALESCE(
      (SELECT cats FROM expand_cat WHERE alias = p_cat1),
      ARRAY[p_cat1]
    )) AS cat
  ),
  cats2 AS (
    SELECT UNNEST(COALESCE(
      (SELECT cats FROM expand_cat WHERE alias = p_cat2),
      ARRAY[p_cat2]
    )) AS cat
  ),
  -- Classes in slot 1
  slot1 AS (
    SELECT c.club_id, cl.name AS club_name, cl.neighborhood AS club_nbhd,
           c.class_name, c.start_mins, c.end_mins, c.instructor
    FROM classes c
    JOIN clubs cl ON cl.id = c.club_id
    WHERE c.club_id = ANY(p_club_ids)
      AND c.day_of_week = p_day
      AND c.category IN (SELECT cat FROM cats1)
      AND c.start_mins >= p_win_start
      AND c.end_mins   <= p_win_end
  ),
  -- Classes in slot 2
  slot2 AS (
    SELECT c.club_id, cl.name AS club_name, cl.neighborhood AS club_nbhd,
           c.class_name, c.start_mins, c.end_mins, c.instructor
    FROM classes c
    JOIN clubs cl ON cl.id = c.club_id
    WHERE c.club_id = ANY(p_club_ids)
      AND c.day_of_week = p_day
      AND c.category IN (SELECT cat FROM cats2)
      AND c.start_mins >= p_win_start
      AND c.end_mins   <= p_win_end
  )
  -- cat1 first → cat2 after
  SELECT
    a.club_id, a.club_name, a.club_nbhd,
    a.class_name, a.start_mins, a.end_mins, a.instructor,
    b.club_id, b.club_name, b.club_nbhd,
    b.class_name, b.start_mins, b.end_mins, b.instructor,
    (b.start_mins - a.end_mins) AS gap_minutes,
    (a.club_id = b.club_id) AS same_club
  FROM slot1 a
  JOIN slot2 b
    ON b.start_mins > a.end_mins
   AND (b.start_mins - a.end_mins) <= p_max_gap
   AND NOT (a.club_id = b.club_id AND a.start_mins = b.start_mins AND a.class_name = b.class_name)
  WHERE p_pair_order IN ('either', '1first')

  UNION ALL

  -- cat2 first → cat1 after
  SELECT
    b.club_id, b.club_name, b.club_nbhd,
    b.class_name, b.start_mins, b.end_mins, b.instructor,
    a.club_id, a.club_name, a.club_nbhd,
    a.class_name, a.start_mins, a.end_mins, a.instructor,
    (a.start_mins - b.end_mins) AS gap_minutes,
    (a.club_id = b.club_id) AS same_club
  FROM slot2 b
  JOIN slot1 a
    ON a.start_mins > b.end_mins
   AND (a.start_mins - b.end_mins) <= p_max_gap
   AND NOT (a.club_id = b.club_id AND a.start_mins = b.start_mins AND a.class_name = b.class_name)
  WHERE p_pair_order IN ('either', '2first')

  ORDER BY first_start, gap_minutes
$$;
