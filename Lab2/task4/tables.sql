CREATE TABLE students_log (
    id NUMBER PRIMARY KEY NOT NULL,
    action VARCHAR2(6) NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    new_student_id NUMBER,
    old_student_id NUMBER,
    student_name VARCHAR2(20) NOT NULL,
    group_id NUMBER NOT NULL,
    action_date TIMESTAMP NOT NULL
);
