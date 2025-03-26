-- Student log triggers

CREATE OR REPLACE TRIGGER students_log_trigger
AFTER INSERT OR UPDATE OR DELETE ON students
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        INSERT INTO students_log (id, action, new_student_id, student_name, group_id, action_date)
        VALUES (students_log_seq.nextval, 'INSERT', :new.id, :new.name, :new.group_id, SYSTIMESTAMP);
    ELSIF UPDATING THEN
        INSERT INTO students_log (id, action, old_student_id, new_student_id, student_name, group_id, action_date)
        VALUES (students_log_seq.nextval, 'UPDATE', :old.id, :new.id, :new.name, :new.group_id, SYSTIMESTAMP);
    ELSIF DELETING THEN
        INSERT INTO students_log (id, action, old_student_id, student_name, group_id, action_date)
        VALUES (students_log_seq.nextval, 'DELETE', :old.id, :old.name, :old.group_id, SYSTIMESTAMP);
    END IF;
END;

CREATE SEQUENCE students_log_seq
START WITH 1
INCREMENT BY 1
NOCACHE NOCYCLE;