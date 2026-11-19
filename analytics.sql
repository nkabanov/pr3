-- =====================================================================
-- analytics.sql — аналитические запросы (БД pm_demo после seed.sql)
-- Параметры: месяц отчёта и окно «недели».
--   psql -d pm_demo -v month=2026-10-01 -f analytics.sql
-- =====================================================================
\if :{?month}
\else
  \set month '2026-10-01'
\endif

-- ---------------------------------------------------------------------
-- Q1. Бизнес-вопрос: какие 5 проектов потребили больше всего часов в месяце
--     и по каким проектам в этом месяце трудозатрат не было вовсе?
-- Граничные случаи: проект без задач (P-11) и проект без записей времени
-- (P-12) должны попасть в выборку с 0 ч — поэтому LEFT JOIN от project и
-- coalesce; равные суммы получают одинаковый ранг (DENSE_RANK); фильтр по
-- месяцу — полуинтервал [начало; начало + 1 мес), чтобы не терять 31-е число.
-- ---------------------------------------------------------------------
\echo '=== Q1. Рейтинг проектов по трудозатратам за месяц ' :month
WITH month_hours AS (
    SELECT t.project_id, sum(te.hours) AS hours, count(*) AS entries
    FROM time_entry te
    JOIN task t ON t.task_id = te.task_id
    WHERE te.work_date >= date :'month'
      AND te.work_date <  date :'month' + interval '1 month'
    GROUP BY t.project_id
), ranked AS (
    SELECT p.code, p.name,
           coalesce(mh.hours, 0)   AS hours,
           coalesce(mh.entries, 0) AS entries,
           dense_rank() OVER (ORDER BY coalesce(mh.hours, 0) DESC) AS rnk
    FROM project p LEFT JOIN month_hours mh ON mh.project_id = p.project_id
)
SELECT rnk AS "место", code AS "проект", name AS "название", hours AS "часы", entries AS "записей",
       CASE WHEN hours = 0 THEN 'нулевые трудозатраты' WHEN rnk <= 5 THEN 'топ-5' END AS "категория"
FROM ranked
WHERE rnk <= 5 OR hours = 0
ORDER BY hours DESC, code;

-- ---------------------------------------------------------------------
-- Q2. Бизнес-вопрос: кто из сотрудников «распылён» — назначен на задачи
--     сразу в трёх и более проектах?
-- Граничные случаи: несколько задач одного проекта считаются одним проектом
-- (COUNT DISTINCT); руководство проектом (project_member) не считается
-- назначением — учитываются только task_assignment.
-- ---------------------------------------------------------------------
\echo '=== Q2. Сотрудники с назначениями в >= 3 проектах'
SELECT e.full_name AS "сотрудник", d.code AS "подр.",
       count(DISTINCT a.project_id) AS "проектов",
       count(*) AS "назначений",
       string_agg(DISTINCT p.code, ', ' ORDER BY p.code) AS "проекты"
FROM task_assignment a
JOIN employee e   ON e.employee_id = a.employee_id
JOIN department d ON d.department_id = e.department_id
JOIN project p    ON p.project_id = a.project_id
GROUP BY e.employee_id, e.full_name, d.code
HAVING count(DISTINCT a.project_id) >= 3
ORDER BY "проектов" DESC, "назначений" DESC, e.full_name
LIMIT 15;

SELECT count(*) AS "всего сотрудников с >= 3 проектами" FROM (
  SELECT employee_id FROM task_assignment GROUP BY 1 HAVING count(DISTINCT project_id) >= 3) s;

-- ---------------------------------------------------------------------
-- Q3. Бизнес-вопрос: какие задачи «лихорадит» — статус менялся более
--     трёх раз в течение любых 7 дней (скользящее окно, а не календарная неделя)?
-- Граничные случаи: событие создания (old_status IS NULL) — не смена статуса;
-- окно RANGE считает события в [t; t + 7 дней], поэтому серия, пересекающая
-- границу календарной недели, не теряется.
-- ---------------------------------------------------------------------
\echo '=== Q3. Задачи, менявшие статус > 3 раз за 7 дней'
WITH changes AS (
    SELECT h.task_id, h.changed_at,
           count(*) OVER (PARTITION BY h.task_id ORDER BY h.changed_at
                          RANGE BETWEEN CURRENT ROW AND INTERVAL '7 days' FOLLOWING) AS changes_in_7d
    FROM task_status_history h
    WHERE h.old_status IS NOT NULL
)
SELECT t.code AS "задача", p.code AS "проект", max(c.changes_in_7d) AS "макс. смен за 7 дн.",
       min(c.changed_at) FILTER (WHERE c.changes_in_7d = (SELECT max(c2.changes_in_7d) FROM changes c2 WHERE c2.task_id = c.task_id))
           AS "начало окна",
       (SELECT string_agg(coalesce(old_status, '∅') || '→' || new_status, ' ' ORDER BY changed_at, event_id)
          FROM task_status_history x WHERE x.task_id = t.task_id) AS "цепочка"
FROM changes c
JOIN task t    ON t.task_id = c.task_id
JOIN project p ON p.project_id = t.project_id
GROUP BY t.task_id, t.code, p.code, c.task_id
HAVING max(c.changes_in_7d) > 3
ORDER BY "макс. смен за 7 дн." DESC, t.code;

-- ---------------------------------------------------------------------
-- Q4. Бизнес-вопрос: какая доля задач каждого проекта завершена?
-- Граничные случаи: проект без задач — деление на ноль исключено через
-- NULLIF, результат NULL и явная пометка «нет задач»; LEFT JOIN не теряет
-- такие проекты; доля считается по текущему статусу задачи.
-- ---------------------------------------------------------------------
\echo '=== Q4. Доля завершённых задач по проектам'
SELECT p.code AS "проект", p.name AS "название",
       count(t.task_id) AS "задач",
       count(t.task_id) FILTER (WHERE t.status_code = 'DONE') AS "завершено",
       round(100.0 * count(t.task_id) FILTER (WHERE t.status_code = 'DONE')
                   / nullif(count(t.task_id), 0), 1) AS "доля, %",
       CASE WHEN count(t.task_id) = 0 THEN 'нет задач' END AS "примечание"
FROM project p
LEFT JOIN task t ON t.project_id = p.project_id
GROUP BY p.project_id, p.code, p.name
ORDER BY "доля, %" DESC NULLS LAST, p.code;

-- ---------------------------------------------------------------------
-- Q5. Бизнес-вопрос: когда, кем и на какой статус последний раз менялась
--     каждая задача? Совпадает ли это с текущим статусом в task?
-- Граничные случаи: несколько событий с одинаковым changed_at — порядок
-- детерминирован вторым ключом event_id; задачи без истории — LEFT JOIN
-- (в корректных данных их нет, запрос это проверяет).
-- ---------------------------------------------------------------------
\echo '=== Q5. Последнее изменение статуса каждой задачи (ROW_NUMBER)'
WITH last_change AS (
    SELECT h.*, row_number() OVER (PARTITION BY h.task_id ORDER BY h.changed_at DESC, h.event_id DESC) AS rn
    FROM task_status_history h
)
SELECT t.code AS "задача", lc.old_status AS "было", lc.new_status AS "стало",
       to_char(lc.changed_at, 'YYYY-MM-DD HH24:MI') AS "когда", e.full_name AS "автор",
       CASE WHEN lc.new_status IS DISTINCT FROM t.status_code THEN 'РАСХОЖДЕНИЕ' ELSE 'ok' END AS "сверка"
FROM task t
LEFT JOIN last_change lc ON lc.task_id = t.task_id AND lc.rn = 1
LEFT JOIN employee e ON e.employee_id = lc.changed_by
ORDER BY lc.changed_at DESC NULLS LAST, t.code
LIMIT 12;

SELECT count(*) AS "задач всего",
       count(*) FILTER (WHERE lc.new_status IS DISTINCT FROM t.status_code) AS "расхождений с task.status_code"
FROM task t
LEFT JOIN (SELECT DISTINCT ON (task_id) task_id, new_status FROM task_status_history
           ORDER BY task_id, changed_at DESC, event_id DESC) lc ON lc.task_id = t.task_id;

-- ---------------------------------------------------------------------
-- Q6. Бизнес-вопрос: кто работает больше среднего по своему подразделению?
-- Граничные случаи: сотрудники без трудозатрат входят в среднее с 0 ч
-- (иначе среднее завышается); подразделение без трудозатрат (PMO) не даёт
-- деления на 0 — сравнение «> 0 = 0» просто ложно.
-- ---------------------------------------------------------------------
\echo '=== Q6. Сотрудники с трудозатратами выше среднего по подразделению (CTE)'
WITH emp_hours AS (
    SELECT e.employee_id, e.full_name, e.department_id, coalesce(sum(te.hours), 0) AS hours
    FROM employee e
    LEFT JOIN time_entry te ON te.employee_id = e.employee_id
    GROUP BY e.employee_id, e.full_name, e.department_id
), dept_avg AS (
    SELECT department_id, avg(hours) AS avg_hours, count(*) AS staff
    FROM emp_hours GROUP BY department_id
)
SELECT d.code AS "подр.", eh.full_name AS "сотрудник", eh.hours AS "часы",
       round(da.avg_hours, 1) AS "среднее по подр.",
       round(eh.hours - da.avg_hours, 1) AS "превышение",
       rank() OVER (PARTITION BY d.code ORDER BY eh.hours DESC) AS "место в подр."
FROM emp_hours eh
JOIN dept_avg da  ON da.department_id = eh.department_id
JOIN department d ON d.department_id = eh.department_id
WHERE eh.hours > da.avg_hours
ORDER BY d.code, eh.hours DESC;
