-- =====================================================================
-- schema.sql — нормализованная схема ИС «ПроектКонтур» (PostgreSQL 16)
-- 3NF/BCNF; все бизнес-правила, которые можно выразить декларативно,
-- выражены через PK / FK / UNIQUE / NOT NULL / CHECK.
-- Повторный запуск безопасен: объекты пересоздаются.
-- =====================================================================
SET client_min_messages = warning;

DROP TABLE IF EXISTS time_entry, task_status_history, task_assignment, task,
                     project_member, project, employee, department, task_status CASCADE;
DROP FUNCTION IF EXISTS trg_lead_limit() CASCADE;
DROP FUNCTION IF EXISTS trg_task_lead_limit() CASCADE;

-- ---------------------------------------------------------------------
-- 1. Справочник статусов задачи (вместо TEXT без ограничений).
--    Таблица, а не ENUM: новый статус добавляется INSERT-ом без ALTER TYPE,
--    к статусу можно привязать признаки (is_active, порядок в процессе).
-- ---------------------------------------------------------------------
CREATE TABLE task_status (
    status_code  varchar(20) PRIMARY KEY
                 CHECK (status_code = upper(status_code) AND status_code ~ '^[A-Z_]+$'),
    title        varchar(60) NOT NULL,
    sort_order   smallint    NOT NULL UNIQUE,
    is_active    boolean     NOT NULL      -- участвует в правиле «не более 2 активных задач»
);
INSERT INTO task_status VALUES
  ('NEW',         'Новая',        1, true),
  ('IN_PROGRESS', 'В работе',     2, true),
  ('REVIEW',      'На проверке',  3, true),
  ('BLOCKED',     'Заблокирована',4, true),
  ('DONE',        'Завершена',    5, false);

-- ---------------------------------------------------------------------
-- 2. Подразделение: уникальный код (бизнес-правило), суррогатный PK.
-- ---------------------------------------------------------------------
CREATE TABLE department (
    department_id  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           varchar(10)  NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{2,10}$'),
    name           varchar(120) NOT NULL CHECK (btrim(name) <> '')
);

-- ---------------------------------------------------------------------
-- 3. Сотрудник. Email уникален БЕЗ учёта регистра: функциональный
--    уникальный индекс по lower(email). Обычный UNIQUE(email) пропустил бы
--    'anna@corp.ru' и 'ANNA@corp.ru'. CHECK запрещает пробелы по краям.
-- ---------------------------------------------------------------------
CREATE TABLE employee (
    employee_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email          varchar(254) NOT NULL
                   CHECK (email = btrim(email) AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    full_name      varchar(150) NOT NULL CHECK (btrim(full_name) <> ''),
    department_id  smallint     NOT NULL REFERENCES department ON DELETE RESTRICT,
    is_active      boolean      NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX ux_employee_email_ci ON employee (lower(email));
CREATE INDEX ix_employee_department ON employee (department_id);

-- ---------------------------------------------------------------------
-- 4. Проект: код уникален, название — нет; ровно один руководитель.
-- ---------------------------------------------------------------------
CREATE TABLE project (
    project_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         varchar(20)  NOT NULL UNIQUE CHECK (code ~ '^P-[0-9]{2,}$'),
    name         varchar(200) NOT NULL CHECK (btrim(name) <> ''),
    manager_id   integer      NOT NULL REFERENCES employee ON DELETE RESTRICT,
    start_date   date         NOT NULL DEFAULT current_date
);
CREATE INDEX ix_project_manager ON project (manager_id);

-- ---------------------------------------------------------------------
-- 5. Участник проекта (M:N Project—Employee). Естественный составной PK:
--    пара уникальна по смыслу, других ссылок на строку нет.
-- ---------------------------------------------------------------------
CREATE TABLE project_member (
    project_id   integer     NOT NULL REFERENCES project  ON DELETE CASCADE,
    employee_id  integer     NOT NULL REFERENCES employee ON DELETE RESTRICT,
    member_role  varchar(20) NOT NULL DEFAULT 'MEMBER'
                 CHECK (member_role IN ('MANAGER','MEMBER','OBSERVER')),
    joined_at    date        NOT NULL DEFAULT current_date,
    PRIMARY KEY (project_id, employee_id)
);
CREATE INDEX ix_project_member_employee ON project_member (employee_id);

-- ---------------------------------------------------------------------
-- 6. Задача: относится к одному проекту. Код уникален В ПРЕДЕЛАХ проекта
--    (по данным аудита один task_code встречается в разных проектах).
--    UNIQUE (task_id, project_id) нужен как цель составного FK.
-- ---------------------------------------------------------------------
CREATE TABLE task (
    task_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id   integer      NOT NULL REFERENCES project ON DELETE RESTRICT,
    code         varchar(20)  NOT NULL CHECK (code ~ '^T-[0-9]{4,}$'),
    title        varchar(300) NOT NULL CHECK (btrim(title) <> ''),
    status_code  varchar(20)  NOT NULL DEFAULT 'NEW' REFERENCES task_status ON UPDATE CASCADE,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    due_date     date,
    CONSTRAINT uq_task_project_code UNIQUE (project_id, code),
    CONSTRAINT uq_task_id_project   UNIQUE (task_id, project_id)
);
CREATE INDEX ix_task_status ON task (status_code);

-- ---------------------------------------------------------------------
-- 7. Назначение исполнителя (M:N Task—Employee) с датой и ролью.
--    project_id дублируется намеренно, чтобы составными FK гарантировать:
--    (а) задача действительно из этого проекта; (б) исполнитель — участник
--    проекта. PK (task_id, employee_id) запрещает повторное назначение.
--    Частичный уникальный индекс: не более одного LEAD на задачу.
-- ---------------------------------------------------------------------
CREATE TABLE task_assignment (
    task_id      integer     NOT NULL,
    employee_id  integer     NOT NULL,
    project_id   integer     NOT NULL,
    role         varchar(20) NOT NULL DEFAULT 'EXECUTOR'
                 CHECK (role IN ('LEAD','EXECUTOR','REVIEWER')),
    assigned_at  date        NOT NULL DEFAULT current_date,
    PRIMARY KEY (task_id, employee_id),
    FOREIGN KEY (task_id, project_id)     REFERENCES task (task_id, project_id) ON DELETE CASCADE,
    FOREIGN KEY (project_id, employee_id) REFERENCES project_member (project_id, employee_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX ux_task_single_lead ON task_assignment (task_id) WHERE role = 'LEAD';
CREATE INDEX ix_task_assignment_employee ON task_assignment (employee_id) INCLUDE (role);
CREATE INDEX ix_task_assignment_project_employee ON task_assignment (project_id, employee_id);

-- ---------------------------------------------------------------------
-- 8. История статусов: каждое изменение — отдельная строка с датой,
--    автором, старым и новым статусом. old_status NULL = создание задачи.
--    ON DELETE RESTRICT: историю нельзя потерять каскадом.
-- ---------------------------------------------------------------------
CREATE TABLE task_status_history (
    event_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id      integer     NOT NULL REFERENCES task ON DELETE RESTRICT,
    old_status   varchar(20) REFERENCES task_status,
    new_status   varchar(20) NOT NULL REFERENCES task_status,
    changed_by   integer     NOT NULL REFERENCES employee ON DELETE RESTRICT,
    changed_at   timestamptz NOT NULL,
    is_estimated boolean     NOT NULL DEFAULT false,  -- true: время/автор восстановлены при миграции
    CONSTRAINT ck_status_really_changed CHECK (old_status IS DISTINCT FROM new_status)
);
CREATE INDEX ix_tsh_task_changed ON task_status_history (task_id, changed_at DESC, event_id DESC);
CREATE INDEX ix_tsh_changed_by ON task_status_history (changed_by);

-- ---------------------------------------------------------------------
-- 9. Учёт времени: одна запись = дата + сотрудник + задача + длительность.
--    Отрицательное и нулевое время запрещено, больше 24 ч в сутки — тоже.
-- ---------------------------------------------------------------------
CREATE TABLE time_entry (
    time_entry_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id       integer      NOT NULL REFERENCES task     ON DELETE RESTRICT,
    employee_id   integer      NOT NULL REFERENCES employee ON DELETE RESTRICT,
    work_date     date         NOT NULL,
    hours         numeric(5,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
    note          varchar(500),
    created_at    timestamptz  NOT NULL DEFAULT now()
);
-- Индексы под аналитику создаются в performance.sql (раздел «после»),
-- здесь — только индексы для FK, без которых DELETE в родителе сканирует таблицу.
CREATE INDEX ix_time_entry_task ON time_entry (task_id);
CREATE INDEX ix_time_entry_employee ON time_entry (employee_id);

-- ---------------------------------------------------------------------
-- 10. Доп. правило (бонус): сотрудник — ведущий (LEAD) не более чем
--     у двух АКТИВНЫХ задач. Проверка под блокировкой строки сотрудника
--     (SELECT ... FOR UPDATE) сериализует конкурентные назначения одного
--     сотрудника, поэтому две транзакции не могут «одновременно» пройти
--     проверку. Второй триггер закрывает обход через смену статуса
--     задачи DONE -> IN_PROGRESS.
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_lead_limit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    IF NEW.role <> 'LEAD' THEN RETURN NEW; END IF;
    PERFORM 1 FROM employee WHERE employee_id = NEW.employee_id FOR UPDATE;   -- точка сериализации
    SELECT count(*) INTO n
      FROM task_assignment a
      JOIN task t        ON t.task_id = a.task_id
      JOIN task_status s ON s.status_code = t.status_code
     WHERE a.employee_id = NEW.employee_id AND a.role = 'LEAD' AND s.is_active
       AND a.task_id <> NEW.task_id;
    IF n >= 2 AND (SELECT is_active FROM task t JOIN task_status s USING (status_code) WHERE t.task_id = NEW.task_id) THEN
        RAISE EXCEPTION 'Сотрудник % уже ведущий в % активных задачах (лимит 2)', NEW.employee_id, n
              USING ERRCODE = 'check_violation', CONSTRAINT = 'lead_active_limit';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER lead_limit BEFORE INSERT OR UPDATE OF role, employee_id ON task_assignment
    FOR EACH ROW EXECUTE FUNCTION trg_lead_limit();

CREATE FUNCTION trg_task_lead_limit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE lead_id int; n int;
BEGIN
    IF (SELECT is_active FROM task_status WHERE status_code = NEW.status_code)
       AND NOT (SELECT is_active FROM task_status WHERE status_code = OLD.status_code) THEN
        SELECT employee_id INTO lead_id FROM task_assignment WHERE task_id = NEW.task_id AND role = 'LEAD';
        IF lead_id IS NOT NULL THEN
            PERFORM 1 FROM employee WHERE employee_id = lead_id FOR UPDATE;
            SELECT count(*) INTO n FROM task_assignment a JOIN task t ON t.task_id = a.task_id
              JOIN task_status s ON s.status_code = t.status_code
             WHERE a.employee_id = lead_id AND a.role = 'LEAD' AND s.is_active AND a.task_id <> NEW.task_id;
            IF n >= 2 THEN
                RAISE EXCEPTION 'Возврат задачи % в работу нарушит лимит ведущего %', NEW.task_id, lead_id
                      USING ERRCODE = 'check_violation', CONSTRAINT = 'lead_active_limit';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER task_lead_limit BEFORE UPDATE OF status_code ON task
    FOR EACH ROW EXECUTE FUNCTION trg_task_lead_limit();

COMMENT ON TABLE task_assignment IS 'Назначения исполнителей; PK запрещает повторное назначение, ux_task_single_lead — второго ведущего';
COMMENT ON TABLE time_entry IS 'Трудозатраты; hours > 0 и <= 24; удаление задачи/сотрудника с записями запрещено (RESTRICT)';
