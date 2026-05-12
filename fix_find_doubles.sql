-- Fix: use positional ORDER BY inside UNION ALL
-- (PostgreSQL can't reference RETURNS TABLE column names inside the function body)

CREATE OR REPLACE FUNCTION find_doubles(
  p_club_ids    INTEGER[],
  p_day         TEXT,
  p_cat1        TEXT,
  p_cat2        TEXT,
  p_max_gap     INTEGER  DEFAULT 30,
  p_pair_order  TEXT     DEFAULT 'either',
  p_win_start   INTEGER  DEFAULT 300,
  p_win_end     INTEGER  DEFAULT 1380
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
    (b.start_mins - a.end_mins),
    (a.club_id = b.club_id)
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
    (a.start_mins - b.end_mins),
    (a.club_id = b.club_id)
  FROM slot2 b
  JOIN slot1 a
    ON a.start_mins > b.end_mins
   AND (a.start_mins - b.end_mins) <= p_max_gap
   AND NOT (a.club_id = b.club_id AND a.start_mins = b.start_mins AND a.class_name = b.class_name)
  WHERE p_pair_order IN ('either', '2first')

  ORDER BY 5, 15  -- first_start ASC, gap_minutes ASC
$$;
