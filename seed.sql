-- =====================================================================
-- seed.sql — детерминированные тестовые данные (запуск после schema.sql)
-- Объём: 6 подразделений, 40 сотрудников, 12 проектов, 90 задач,
--        >=180 назначений, 400 записей времени, >=250 событий истории.
-- Специально заложенные граничные случаи для analytics.sql:
--   * P-11 — проект без задач (доля завершённых = NULL/0, не деление на 0);
--   * P-12 — проект с задачами, но без трудозатрат (нулевые часы в рейтинге);
--   * задачи T-0005, T-0015, T-0025 «прыгали» REVIEW<->IN_PROGRESS > 3 раз за неделю;
--   * сотрудники, участвующие в 3 проектах.
-- =====================================================================
BEGIN;
SELECT setseed(0.42);

INSERT INTO department (code, name) VALUES
 ('DEV','Разработка'), ('BI','Аналитика'), ('OPS','Эксплуатация'),
 ('QA','Тестирование'), ('SEC','Информационная безопасность'), ('PMO','Проектный офис');

-- 40 сотрудников: 1..35 — исполнители (по 7 в DEV/BI/OPS/QA/SEC), 36..40 — руководители (PMO)
INSERT INTO employee (email, full_name, department_id)
SELECT format('emp%s@corp.ru', lpad(i::text, 2, '0')),
       (ARRAY['Анна','Борис','Виктор','Галина','Дмитрий','Елена','Жанна','Илья','Кира','Лев'])[1 + (i-1) % 10]
         || ' ' ||
       (ARRAY['Иванов','Петров','Сидоров','Кузнецов','Смирнов','Попов','Волков','Зайцев'])[1 + (i-1) % 8]
         || CASE WHEN (i-1) % 10 IN (0,3,5,6,8) THEN 'а' ELSE '' END,
       CASE WHEN i <= 35 THEN 1 + (i-1) % 5 ELSE 6 END
FROM generate_series(1, 40) i;

-- 12 проектов; руководители — сотрудники 36..40
INSERT INTO project (code, name, manager_id, start_date)
SELECT format('P-%s', lpad(p::text, 2, '0')),
       (ARRAY['Портал','Аналитика','Документооборот','Сервис-деск','Интеграционная шина','Мобильный кабинет',
              'Мониторинг','Управление доступом','Хранилище данных','Биллинг','Пилот R&D','Архив'])[p],
       36 + (p-1) % 5,
       date '2026-07-01' + (p * 3)
FROM generate_series(1, 12) p;

-- Участники: руководитель — MANAGER; исполнитель i — в трёх проектах из P-01..P-10;
-- в P-11 — 4 участника, в P-12 — 11 участников дополнительно.
INSERT INTO project_member (project_id, employee_id, member_role, joined_at)
SELECT project_id, manager_id, 'MANAGER', start_date FROM project;

INSERT INTO project_member (project_id, employee_id, member_role, joined_at)
SELECT DISTINCT ON (p, i) p, i, 'MEMBER', date '2026-07-15'
FROM generate_series(1, 35) i,
     LATERAL (VALUES (1 + i % 10), (1 + (i + 3) % 10), (1 + (i + 6) % 10)) v(p)
ON CONFLICT DO NOTHING;

INSERT INTO project_member (project_id, employee_id, joined_at)
SELECT p, i, date '2026-08-01' FROM (VALUES (11),(12)) v(p), generate_series(1, 35) i
WHERE (p = 11 AND i % 9 = 2) OR (p = 12 AND i % 3 = 0)
ON CONFLICT DO NOTHING;

-- 90 задач: 80 в P-01..P-10, 10 в P-12; в P-11 задач нет
INSERT INTO task (project_id, code, title, status_code, created_at, due_date)
SELECT CASE WHEN n <= 80 THEN 1 + (n-1) % 10 ELSE 12 END,
       format('T-%s', lpad(n::text, 4, '0')),
       (ARRAY['API','Интеграция','Интерфейс','Миграция','Отчёт','Тестирование'])[1 + n % 6] || ' ' || format('T-%s', lpad(n::text, 4, '0')),
       CASE WHEN n IN (5,15,25) THEN 'DONE'
            ELSE (ARRAY['NEW','IN_PROGRESS','REVIEW','BLOCKED','DONE','DONE','DONE','IN_PROGRESS'])[1 + n % 8] END,
       timestamptz '2026-08-01 09:00+03' + ((n * 17) % 75) * interval '1 day',
       date '2026-11-15' + (n % 30)
FROM generate_series(1, 90) n;

-- Назначения: один LEAD (участник с наименьшим числом активных LEAD-задач,
-- чтобы соблюдалось правило «<= 2 активных») и 1–2 исполнителя.
DO $$
DECLARE t record; lead_emp int;
BEGIN
  FOR t IN SELECT task_id, project_id, created_at::date d, status_code FROM task ORDER BY task_id LOOP
    SELECT m.employee_id INTO lead_emp
      FROM project_member m
      LEFT JOIN task_assignment a ON a.employee_id = m.employee_id AND a.role = 'LEAD'
      LEFT JOIN task x ON x.task_id = a.task_id
      LEFT JOIN task_status s ON s.status_code = x.status_code AND s.is_active
     WHERE m.project_id = t.project_id AND m.member_role = 'MEMBER'
     GROUP BY m.employee_id
     ORDER BY count(s.status_code), m.employee_id
     LIMIT 1;
    INSERT INTO task_assignment (task_id, employee_id, project_id, role, assigned_at)
    VALUES (t.task_id, lead_emp, t.project_id, 'LEAD', t.d);

    INSERT INTO task_assignment (task_id, employee_id, project_id, role, assigned_at)
    SELECT t.task_id, m.employee_id, t.project_id,
           CASE WHEN rn = 2 AND t.task_id % 4 = 0 THEN 'REVIEWER' ELSE 'EXECUTOR' END, t.d + 1
      FROM (SELECT employee_id, row_number() OVER (ORDER BY (employee_id * 7 + t.task_id * 13) % 37) rn
              FROM project_member WHERE project_id = t.project_id AND member_role = 'MEMBER'
               AND employee_id <> lead_emp) m
     WHERE rn <= 1 + t.task_id % 2;
  END LOOP;
END $$;

-- История статусов: путь от создания до текущего статуса, автор — ведущий исполнитель.
WITH paths(status_code, path) AS (VALUES
   ('NEW',         ARRAY['NEW']),
   ('IN_PROGRESS', ARRAY['NEW','IN_PROGRESS']),
   ('REVIEW',      ARRAY['NEW','IN_PROGRESS','REVIEW']),
   ('BLOCKED',     ARRAY['NEW','IN_PROGRESS','BLOCKED']),
   ('DONE',        ARRAY['NEW','IN_PROGRESS','REVIEW','DONE'])),
pp AS (
  SELECT t.task_id, t.created_at, t.code,
         CASE WHEN t.code IN ('T-0005','T-0015','T-0025')     -- «пинг-понг» на проверке
              THEN ARRAY['NEW','IN_PROGRESS','REVIEW','IN_PROGRESS','REVIEW','IN_PROGRESS','REVIEW','DONE']
              ELSE p.path END AS path
  FROM task t JOIN paths p USING (status_code))
INSERT INTO task_status_history (task_id, old_status, new_status, changed_by, changed_at)
SELECT pp.task_id,
       CASE WHEN k = 1 THEN NULL ELSE pp.path[k-1] END,
       pp.path[k],
       a.employee_id,
       pp.created_at + CASE WHEN pp.code IN ('T-0005','T-0015','T-0025')
                            THEN (k - 1) * interval '19 hours'
                            ELSE (k - 1) * interval '2 days 3 hours' END
FROM pp
JOIN task_assignment a ON a.task_id = pp.task_id AND a.role = 'LEAD',
     generate_series(1, array_length(pp.path, 1)) k;

-- 400 записей трудозатрат: исполнители задач (кроме задач P-12), даты — от создания задачи до 31.10.2026
INSERT INTO time_entry (task_id, employee_id, work_date, hours, note)
SELECT a.task_id, a.employee_id,
       least(date '2026-10-31', t.created_at::date + (g * 7 + a.employee_id) % 60),
       round((0.5 + random() * 7.5)::numeric, 1),
       'seed'
FROM generate_series(1, 400) g
JOIN LATERAL (SELECT a.* FROM task_assignment a JOIN task x USING (task_id)
               WHERE x.project_id <> 12
               ORDER BY a.task_id, a.employee_id
               OFFSET (g * 31) % (SELECT count(*) FROM task_assignment a2 JOIN task x2 USING (task_id) WHERE x2.project_id <> 12)
               LIMIT 1) a ON true
JOIN task t ON t.task_id = a.task_id;

COMMIT;

SELECT 'department' t, count(*) FROM department UNION ALL
SELECT 'employee', count(*) FROM employee UNION ALL
SELECT 'project', count(*) FROM project UNION ALL
SELECT 'project_member', count(*) FROM project_member UNION ALL
SELECT 'task', count(*) FROM task UNION ALL
SELECT 'task_assignment', count(*) FROM task_assignment UNION ALL
SELECT 'time_entry', count(*) FROM time_entry UNION ALL
SELECT 'task_status_history', count(*) FROM task_status_history;
