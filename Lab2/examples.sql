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
