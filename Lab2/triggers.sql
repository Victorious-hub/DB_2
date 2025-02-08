-- Student autoincrement with seq + trigger
CREATE SEQUENCE students_seq 
    START WITH 1 
    INCREMENT BY 1 
    NOCACHE 
    NOCYCLE;

CREATE OR REPLACE TRIGGER students_trg BEFORE
    INSERT ON students
FOR EACH ROW
    WHEN (NEW.id IS NULL)
BEGIN
    SELECT students_seq.NEXTVAL INTO :NEW.id FROM dual;
END;

-- Group autoincrement with seq + trigger
CREATE SEQUENCE group_seq 
    START WITH 1 
    INCREMENT BY 1 
    NOCACHE 
    NOCYCLE;

CREATE OR REPLACE TRIGGER groups_trg BEFORE
    INSERT ON groups
FOR EACH ROW
    WHEN (NEW.id IS NULL)
BEGIN
    SELECT group_seq.NEXTVAL INTO :NEW.id FROM dual;
END;


-- Cascadian delete foreign key
CREATE OR REPLACE TRIGGER cascade_delete_students
    BEFORE DELETE ON groups
    FOR EACH ROW
BEGIN
    DELETE FROM students
    WHERE group_id = :old.id;
END;


-- c_val update

CREATE OR REPLACE TRIGGER update_c_val_trigger
AFTER INSERT OR UPDATE OR DELETE ON students
FOR EACH ROW
DECLARE
  new_group_id NUMBER;
  old_group_id NUMBER;
  v_exists NUMBER;
BEGIN
  IF inserting THEN
    UPDATE groups
    SET c_val = c_val + 1
    WHERE id = :new.group_id;

  ELSIF updating THEN
    new_group_id := :new.group_id;
    old_group_id := :old.group_id;

    IF new_group_id <> old_group_id THEN
      UPDATE groups
      SET c_val = c_val + 1
      WHERE id = new_group_id;

      UPDATE groups
      SET c_val = c_val - 1
      WHERE id = old_group_id;
    END IF;

  ELSIF deleting THEN
    SELECT COUNT(*) INTO v_exists FROM groups WHERE id = :old.group_id;

    IF v_exists > 0 THEN
      UPDATE groups
      SET c_val = c_val - 1
      WHERE id = :old.group_id;
    END IF;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error updating c_val: ' || SQLERRM);
END;


-- Check if student id unique

CREATE OR REPLACE TRIGGER check_student_id_uniqueness
BEFORE INSERT ON students
FOR EACH ROW
DECLARE
    duplicate_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO duplicate_count
    FROM students
    WHERE id = :new.id;

    IF duplicate_count > 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Student ID must be unique ' || :new.id);
    END IF;
END;


-- Check if group name or id unique

CREATE OR REPLACE TRIGGER check_group_id_name_uniqueness
BEFORE INSERT OR UPDATE ON groups
FOR EACH ROW
DECLARE
    duplicate_id_count NUMBER;
    duplicate_name_count NUMBER;
BEGIN
    IF INSERTING OR UPDATING('ID') THEN
        SELECT COUNT(*) INTO duplicate_id_count
        FROM groups
        WHERE id = :new.id;

        IF duplicate_id_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'group_id must be unique');
        END IF;
    END IF;

    IF INSERTING OR UPDATING('GROUP_NAME') THEN
        SELECT COUNT(*) INTO duplicate_name_count
        FROM groups
        WHERE LOWER(name) = LOWER(:new.name);

        IF duplicate_name_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'group_name must be unique');
        END IF;
    END IF;
END;


-- Check if group id exists, when create or update student row

CREATE OR REPLACE TRIGGER check_group_exists
BEFORE INSERT OR UPDATE ON students
FOR EACH ROW
DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count 
    FROM groups 
    WHERE id = :NEW.group_id;

    IF v_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Exception: group_id does not exist');
    END IF;
END;


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