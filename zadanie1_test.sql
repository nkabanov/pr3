BEGIN;

SELECT count(*) AS exists_task FROM task WHERE task_id = 999999;

INSERT INTO time_entry (task_id, employee_id, work_date, hours, note)
VALUES (999999, 1, DATE '2026-10-01', 2.00, 'audit_fk_test');

ROLLBACK;