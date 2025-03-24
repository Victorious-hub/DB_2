-- c_val update
CREATE OR REPLACE TRIGGER update_c_val_trigger
AFTER INSERT OR UPDATE ON students
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
      SELECT COUNT(*) INTO v_exists FROM groups WHERE id = new_group_id;
      IF v_exists > 0 THEN
        UPDATE groups
        SET c_val = c_val + 1
        WHERE id = new_group_id;
      END IF;

      SELECT COUNT(*) INTO v_exists FROM groups WHERE id = old_group_id;
      IF v_exists > 0 THEN
        UPDATE groups
        SET c_val = c_val - 1
        WHERE id = old_group_id;
      END IF;
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
