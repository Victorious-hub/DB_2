INSERT INTO students (name, group_id) VALUES ('Bo211b', 9);
INSERT INTO students (name, group_id) VALUES ('B2o2101b', 16);

SELECT * FROM students;
INSERT INTO groups (name) VALUES ('Epsi12lon');

-- SELECT * FROM students_log;

SELECT * FROM groups;
DELETE FROM groups
WHERE id = 14;

UPDATE students
SET group_id = 14
WHERE name = 'B2o2101b';

-- CALL restore_students_state('09/03/25 11:53:43.473423000');
-- -- DELETE FROM students_log
-- -- WHERE id != 99999;
