-- Cascadian delete foreign key
CREATE OR REPLACE PACKAGE global_vars AS
  g_deleting_group NUMBER;
END global_vars;

CREATE OR REPLACE TRIGGER update_c_val_trigger
AFTER DELETE ON students
BEGIN
  IF global_vars.g_deleting_group IS NULL THEN
    UPDATE groups
    SET c_val = (SELECT COUNT(*) FROM students WHERE group_id = groups.id);
  END IF;
  global_vars.g_deleting_group := NULL;
END;


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
    IF global_vars.g_deleting_group IS NULL THEN
        UPDATE groups
        SET c_val = (SELECT COUNT(*) FROM students WHERE group_id = groups.id);
    END IF;
    global_vars.g_deleting_group := NULL;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error updating c_val: ' || SQLERRM);
END;