-- =====================================================================
-- performance.sql — объём >= 100 000 TimeEntry, EXPLAIN до/после индексов
-- Запуск: psql -d pm_demo -f performance.sql   (после schema.sql, seed.sql)
-- Сценарий конкурентности (5.3) и бонус — в concurrency/*.sql + run_concurrency.sh
-- =====================================================================
\set ON_ERROR_STOP on
\timing off

-- ---------------------------------------------------------------------
-- 1. Наращивание объёма: +150 000 записей за период 2025-01-01 .. 2026-10-31
--    (только по реальным назначениям — связи корректны)
-- ---------------------------------------------------------------------
SELECT setseed(0.7);
WITH a AS (SELECT row_number() OVER (ORDER BY task_id, employee_id) AS rn, task_id, employee_id
             FROM task_assignment a0 JOIN task t0 USING (task_id) WHERE t0.project_id <> 12),
     n AS (SELECT count(*) AS c FROM a)
INSERT INTO time_entry (task_id, employee_id, work_date, hours, note)
SELECT a.task_id, a.employee_id,
       date '2025-01-01' + (random() * 668)::int,
       round((0.25 + random() * 7.75)::numeric, 2),
       'bulk'
FROM generate_series(1, 150000) g
JOIN n ON true
JOIN a ON a.rn = 1 + (g * 7919) % n.c;

-- ---------------------------------------------------------------------
-- 2. Состояние «ДО»: на time_entry только PK (FK-индексы тоже снимаем,
--    чтобы честно сравнить «без индексов» и «с индексами»)
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_time_entry_task, ix_time_entry_employee,
                     ix_te_date_task_incl, ix_te_employee_date, ix_te_task_date;
VACUUM ANALYZE time_entry;
VACUUM ANALYZE task;

SELECT count(*) AS time_entry_rows, pg_size_pretty(pg_total_relation_size('time_entry')) AS size FROM time_entry;

-- Запрос А: рейтинг проектов за месяц (Q1 из analytics.sql)
\set qa 'SELECT t.project_id, sum(te.hours) FROM time_entry te JOIN task t ON t.task_id = te.task_id WHERE te.work_date >= date ''2026-10-01'' AND te.work_date < date ''2026-11-01'' GROUP BY t.project_id ORDER BY 2 DESC LIMIT 5'
-- Запрос Б: последние 20 записей сотрудника за квартал (экран «Мои трудозатраты»)
\set qb 'SELECT te.work_date, te.task_id, te.hours FROM time_entry te WHERE te.employee_id = 7 AND te.work_date >= date ''2026-07-01'' AND te.work_date < date ''2026-10-01'' ORDER BY te.work_date DESC LIMIT 20'
-- Запрос В: сумма часов по сотрудникам за всё время (Q6) — индекс не поможет
\set qc 'SELECT employee_id, sum(hours) FROM time_entry GROUP BY employee_id'

-- прогрев кэша, затем замер
SELECT count(*) FROM time_entry;
\echo '##### ДО: запрос А'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qa;
\echo '##### ДО: запрос Б'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qb;
\echo '##### ДО: запрос В'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qc;

\echo '##### ДО: 10 000 вставок (только PK)'
\timing on
INSERT INTO time_entry (task_id, employee_id, work_date, hours, note)
SELECT task_id, employee_id, date '2026-10-15', 1, 'write-cost'
FROM task_assignment, generate_series(1, 45) LIMIT 10000;
\timing off
DELETE FROM time_entry WHERE note = 'write-cost';
VACUUM ANALYZE time_entry;

-- ---------------------------------------------------------------------
-- 3. Индексы
--  (1) (work_date, task_id) INCLUDE (hours): условие WHERE — диапазон по дате,
--      поэтому дата первой; task_id нужен для JOIN, hours — в INCLUDE,
--      чтобы выполнить Index Only Scan без обращения к таблице.
--  (2) (employee_id, work_date DESC): сначала столбец с равенством, затем
--      диапазон + ORDER BY work_date DESC LIMIT — сортировка не нужна,
--      чтение останавливается после 20 строк. Обратный порядок
--      (work_date, employee_id) читал бы весь квартал всех сотрудников.
--  (3) (task_id, work_date): FK-индекс для DELETE/UPDATE задачи и для
--      «часы по задаче за период»; заменяет одиночный ix_time_entry_task.
--  (+) уже в schema.sql: task_status_history (task_id, changed_at DESC, event_id DESC)
--      — под ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY changed_at DESC).
-- ---------------------------------------------------------------------
CREATE INDEX ix_te_date_task_incl ON time_entry (work_date, task_id) INCLUDE (hours);
CREATE INDEX ix_te_employee_date  ON time_entry (employee_id, work_date DESC);
CREATE INDEX ix_te_task_date      ON time_entry (task_id, work_date);
VACUUM ANALYZE time_entry;

SELECT indexrelname AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'time_entry' ORDER BY 1;

\echo '##### ПОСЛЕ: запрос А'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qa;
\echo '##### ПОСЛЕ: запрос Б'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qb;
\echo '##### ПОСЛЕ: запрос В'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) :qc;

-- ---------------------------------------------------------------------
-- 4. Когда индекс не помогает: низкая селективность (почти весь период)
-- ---------------------------------------------------------------------
\echo '##### ПОСЛЕ: запрос А за 22 месяца (низкая селективность)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT t.project_id, sum(te.hours) FROM time_entry te JOIN task t ON t.task_id = te.task_id
WHERE te.work_date >= date '2025-01-01' AND te.work_date < date '2026-11-01'
GROUP BY t.project_id ORDER BY 2 DESC LIMIT 5;

-- ---------------------------------------------------------------------
-- 5. Цена индексов на запись: те же 10 000 вставок, но уже с тремя индексами
-- ---------------------------------------------------------------------
\echo '##### ПОСЛЕ: 10 000 вставок (PK + 3 индекса)'
\timing on
INSERT INTO time_entry (task_id, employee_id, work_date, hours, note)
SELECT task_id, employee_id, date '2026-10-15', 1, 'write-cost'
FROM task_assignment, generate_series(1, 45) LIMIT 10000;
\timing off
DELETE FROM time_entry WHERE note = 'write-cost';
