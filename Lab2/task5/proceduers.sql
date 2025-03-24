-- Procedure to restore student's data
CREATE OR REPLACE PROCEDURE restore_students_state(p_timestamp TIMESTAMP) IS
     cur_time TIMESTAMP;
BEGIN
    cur_time := SYSTIMESTAMP;
    DELETE FROM students;

    FOR lg IN (
        SELECT *
        FROM students_log
        WHERE action_date <= p_timestamp
        ORDER BY action_date
    ) LOOP
        IF lg.action = 'INSERT' THEN
            INSERT INTO students (id, name, group_id)
            VALUES (lg.new_student_id, lg.student_name, lg.group_id);
        ELSIF lg.action = 'UPDATE' THEN
            UPDATE students
            SET name = lg.student_name, group_id = lg.group_id, id = lg.new_student_id
            WHERE id = lg.old_student_id;
        ELSIF lg.action = 'DELETE' THEN
            DELETE FROM students
            WHERE id = lg.old_student_id;
        END IF;
    END LOOP;

    DELETE FROM students_log
    WHERE action_date >= cur_time;
END;