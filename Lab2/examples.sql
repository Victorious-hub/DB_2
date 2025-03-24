-- Groups
INSERT INTO groups (name, C_VAL) VALUES ('Alpha', 100);
INSERT INTO groups (name, C_VAL) VALUES ('Beta', 200);
INSERT INTO groups (name, C_VAL) VALUES ('Gamma', 300);
INSERT INTO groups (name, C_VAL) VALUES ('Delta', 400);
INSERT INTO groups (name, C_VAL) VALUES ('Epsilon', 500);

INSERT INTO groups (id, name, C_VAL) VALUES (133, 'Alpha1', 100);

-- Users
INSERT INTO students (name, group_id) VALUES ('Alice', 1);
INSERT INTO students (name, group_id) VALUES ('Bob', 2);
INSERT INTO students (name, group_id) VALUES ('Charlie', 1);
INSERT INTO students (name, group_id) VALUES ('David', 3);
INSERT INTO students (name, group_id) VALUES ('Eve', 2);


INSERT INTO groups (id, name, C_VAL) VALUES (1001, 'Eps7ilon1', 0);

SELECT * FROM GROUPS;
INSERT INTO students (name, group_id) VALUES ('Alice1', 1001);

DELETE FROM groups
WHERE id = 1001;
SELECT * FROM STUDENTS;

UPDATE students
SET name = 'Alice Updated'
WHERE id = 7;

CALL restore_students_state('08/02/25 17:08:39.726561000');

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
