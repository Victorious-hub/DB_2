-- c_val update
CREATE OR REPLACE TRIGGER update_c_val_trigger
AFTER DELETE ON students
BEGIN
  IF global_vars.g_deleting_group IS NULL THEN
    UPDATE groups
    SET c_val = (SELECT COUNT(*) FROM students WHERE group_id = groups.id);
  END IF;
  global_vars.g_deleting_group := NULL;
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
