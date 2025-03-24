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

-- check if c_val equal to zero
CREATE OR REPLACE TRIGGER check_group_c_val_value
BEFORE INSERT ON groups
FOR EACH ROW
BEGIN
    IF :NEW.c_val <> 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'c_val must be 0 upon insertion');
    END IF;
END;