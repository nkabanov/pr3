-- =====================================================================
-- tests.sql — отрицательные тесты целостности (запуск после schema.sql + seed.sql)
-- Каждый тест выполняется в отдельной подтранзакции и ОТКАТЫВАЕТСЯ,
-- данные seed не меняются. Итог — таблица «ожидалось / получено».
-- =====================================================================
\set ON_ERROR_STOP on

CREATE TEMP TABLE test_result (
    n int, test text, expected_state text, actual_state text, constraint_name text, message text, passed boolean);

CREATE OR REPLACE FUNCTION pg_temp.neg(p_n int, p_name text, p_expected text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE st text; cn text; msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    -- если дошли сюда — ограничение НЕ сработало
    INSERT INTO test_result VALUES (p_n, p_name, p_expected, '00000 (успех!)', NULL, 'оператор выполнен без ошибки', false);
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '__rollback__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, cn = CONSTRAINT_NAME, msg = MESSAGE_TEXT;
    IF msg <> '__rollback__' THEN
      INSERT INTO test_result VALUES (p_n, p_name, p_expected, st, cn, msg, st = p_expected);
    END IF;
  END;
END $$;

-- Исходные объекты для тестов
SELECT e.email AS existing_email FROM employee e WHERE e.employee_id = 1;
\o /dev/null

-- 1. Повтор email с другим регистром (emp01@corp.ru уже есть)
SELECT pg_temp.neg(1, 'Повтор email в другом регистре', '23505',
  $q$INSERT INTO employee (email, full_name, department_id) VALUES ('EMP01@CORP.RU', 'Двойник', 1)$q$);

-- 2. Несуществующий внешний ключ (задачи 999999 нет)
SELECT pg_temp.neg(2, 'Несуществующий FK (task_id=999999)', '23503',
  $q$INSERT INTO time_entry (task_id, employee_id, work_date, hours) VALUES (999999, 1, '2026-10-01', 2)$q$);

-- 3. Отрицательное время
SELECT pg_temp.neg(3, 'Отрицательные трудозатраты (-4 ч)', '23514',
  $q$INSERT INTO time_entry (task_id, employee_id, work_date, hours)
     SELECT task_id, employee_id, '2026-10-01', -4 FROM task_assignment LIMIT 1$q$);

-- 4. Недопустимый статус
SELECT pg_temp.neg(4, 'Недопустимый статус UNKNOWN', '23503',
  $q$UPDATE task SET status_code = 'UNKNOWN' WHERE task_id = 1$q$);

-- 5. Повторное назначение того же исполнителя на ту же задачу
SELECT pg_temp.neg(5, 'Повторное назначение (task, employee)', '23505',
  $q$INSERT INTO task_assignment (task_id, employee_id, project_id, role)
     SELECT task_id, employee_id, project_id, 'EXECUTOR' FROM task_assignment WHERE role = 'EXECUTOR' LIMIT 1$q$);

-- 6. Удаление родительской записи с зависимостями (задача с трудозатратами и историей)
SELECT pg_temp.neg(6, 'DELETE задачи с трудозатратами', '23503',
  $q$DELETE FROM task WHERE task_id = (SELECT task_id FROM time_entry LIMIT 1)$q$);

-- Дополнительные тесты
SELECT pg_temp.neg(7, 'Email с пробелами по краям', '23514',
  $q$INSERT INTO employee (email, full_name, department_id) VALUES (' new@corp.ru ', 'Пробел', 1)$q$);
SELECT pg_temp.neg(8, 'Нулевые трудозатраты (0 ч)', '23514',
  $q$INSERT INTO time_entry (task_id, employee_id, work_date, hours) SELECT task_id, employee_id, '2026-10-01', 0 FROM task_assignment LIMIT 1$q$);
SELECT pg_temp.neg(9, 'Второй LEAD на задачу', '23505',
  $q$UPDATE task_assignment SET role = 'LEAD'
     WHERE (task_id, employee_id) = (SELECT task_id, employee_id FROM task_assignment a WHERE role='EXECUTOR'
                                      AND EXISTS (SELECT 1 FROM task t JOIN task_status s USING(status_code) WHERE t.task_id=a.task_id AND NOT s.is_active) LIMIT 1)$q$);
SELECT pg_temp.neg(10, 'Исполнитель не участник проекта', '23503',
  $q$INSERT INTO task_assignment (task_id, employee_id, project_id)
     SELECT t.task_id, e.employee_id, t.project_id FROM task t, employee e
      WHERE NOT EXISTS (SELECT 1 FROM project_member m WHERE m.project_id=t.project_id AND m.employee_id=e.employee_id) LIMIT 1$q$);
SELECT pg_temp.neg(11, 'Дубль кода задачи внутри проекта', '23505',
  $q$INSERT INTO task (project_id, code, title) SELECT project_id, code, 'Копия' FROM task LIMIT 1$q$);
SELECT pg_temp.neg(12, 'Задача ссылается на чужой проект (составной FK)', '23503',
  $q$INSERT INTO task_assignment (task_id, employee_id, project_id)
     SELECT a.task_id, m.employee_id, m.project_id FROM task_assignment a
       JOIN task t ON t.task_id=a.task_id JOIN project_member m ON m.project_id <> t.project_id LIMIT 1$q$);
SELECT pg_temp.neg(13, 'Удаление сотрудника с историей/временем', '23503',
  $q$DELETE FROM employee WHERE employee_id = (SELECT employee_id FROM time_entry LIMIT 1)$q$);
SELECT pg_temp.neg(14, 'Событие истории без смены статуса', '23514',
  $q$INSERT INTO task_status_history (task_id, old_status, new_status, changed_by, changed_at) VALUES (1,'NEW','NEW',1,now())$q$);
SELECT pg_temp.neg(15, 'Третья активная LEAD-задача сотрудника (бонус)', '23514',
  $q$WITH e AS (SELECT a.employee_id, a.project_id FROM task_assignment a JOIN task t USING(task_id) JOIN task_status s USING(status_code)
              WHERE a.role='LEAD' AND s.is_active GROUP BY 1,2 HAVING count(*) = 2 LIMIT 1),
          nt AS (INSERT INTO task (project_id, code, title, status_code) SELECT project_id, 'T-9999', 'Тест лимита', 'IN_PROGRESS' FROM e RETURNING task_id, project_id)
     INSERT INTO task_assignment (task_id, employee_id, project_id, role) SELECT nt.task_id, e.employee_id, nt.project_id, 'LEAD' FROM nt, e$q$);

\o
SELECT n AS "№", test AS "тест", expected_state AS "ожид. SQLSTATE", actual_state AS "факт. SQLSTATE",
       constraint_name AS "ограничение", left(message, 90) AS "сообщение СУБД",
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS "итог"
FROM test_result ORDER BY n;

SELECT count(*) FILTER (WHERE passed) AS passed, count(*) AS total FROM test_result;

-- Контроль: данные не изменились
SELECT (SELECT count(*) FROM employee) employees, (SELECT count(*) FROM task) tasks,
       (SELECT count(*) FROM time_entry) time_entries, (SELECT count(*) FROM task_assignment) assignments;
