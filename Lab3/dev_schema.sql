DROP USER dev_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER dev_schema IDENTIFIED BY dev_password;
GRANT CONNECT, RESOURCE TO DEV_SCHEMA;
GRANT ALL PRIVILEGES TO DEV_SCHEMA;

CREATE TABLE dev_schema.dev_table1 (
    id NUMBER,
    name VARCHAR2(100)
);

CREATE TABLE dev_schema.Company (
    CompanyID INT PRIMARY KEY,
    CompanyName VARCHAR2(255),
    Industry VARCHAR2(100)
);

CREATE TABLE dev_schema.Department (
    DepartmentID INT PRIMARY KEY,
    DepartmentName VARCHAR2(255)
);

CREATE TABLE dev_schema.Employee (
    EmployeeID INT PRIMARY KEY,
    DepartmentID INT,
    Name VARCHAR2(255),
    Email VARCHAR2(255),
    FOREIGN KEY (DepartmentID) REFERENCES dev_schema.Department(DepartmentID)
);

CREATE INDEX dev_schema.idx_employee_email ON dev_schema.Employee(Email);

CREATE OR REPLACE PROCEDURE dev_schema.AddEmployee (
    p_ID INT,
    p_DepartmentID INT,
    p_Name VARCHAR2,
    p_Email VARCHAR2
) AS
BEGIN
    INSERT INTO dev_schema.Employee (EmployeeID, DepartmentID, Name, Email)
    VALUES (p_ID, p_DepartmentID, p_Name, p_Email);
END;
/

CREATE OR REPLACE FUNCTION dev_schema.CalcBonus (
    salary IN NUMBER, percent IN NUMBER
) RETURN NUMBER AS
BEGIN
    RETURN ROUND(salary * percent / 100, 2);
END;
/

CREATE OR REPLACE PACKAGE dev_schema.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Percent NUMBER);
END EmployeeUtils;
/

CREATE OR REPLACE PACKAGE BODY dev_schema.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Percent NUMBER) IS
    BEGIN
        UPDATE dev_schema.Employee
        SET Email = Email
        WHERE EmployeeID = p_EmpID;
    END;
END EmployeeUtils;
/


CREATE TABLE dev_schema.table_a (
    id NUMBER PRIMARY KEY,
    name VARCHAR2(100)
);

CREATE TABLE dev_schema.table_b (
    id NUMBER PRIMARY KEY,
    a_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_b_a FOREIGN KEY (a_id) REFERENCES dev_schema.table_a (id)
);

CREATE TABLE dev_schema.table_c (
    id NUMBER PRIMARY KEY,
    b_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_c_b FOREIGN KEY (b_id) REFERENCES dev_schema.table_b (id)
);

CREATE TABLE dev_schema.table_d (
    id NUMBER PRIMARY KEY,
    c_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_d_c FOREIGN KEY (c_id) REFERENCES dev_schema.table_c (id)
);

ALTER TABLE dev_schema.table_a
ADD CONSTRAINT fk_a_d FOREIGN KEY (id) REFERENCES dev_schema.table_d (id);


-- Циклические зависимости и порядок создания
CREATE TABLE dev_schema.departments (
    department_id NUMBER PRIMARY KEY,
    department_name VARCHAR2(100) NOT NULL
);

CREATE TABLE dev_schema.employees (
    employee_id NUMBER PRIMARY KEY,
    employee_name VARCHAR2(100) NOT NULL,
    department_id NUMBER,
    CONSTRAINT fk_department FOREIGN KEY (department_id) REFERENCES dev_schema.departments(department_id)
);

CREATE TABLE dev_schema.projects (
    project_id NUMBER PRIMARY KEY,
    project_name VARCHAR2(100) NOT NULL,
    employee_id NUMBER,
    CONSTRAINT fk_employee FOREIGN KEY (employee_id) REFERENCES dev_schema.employees(employee_id)
);

CREATE TABLE dev_schema.team_leads (
    lead_id NUMBER PRIMARY KEY,
    lead_name VARCHAR2(100) NOT NULL,
    team_id NUMBER
);

CREATE TABLE dev_schema.teams (
    team_id NUMBER PRIMARY KEY,
    team_name VARCHAR2(100) NOT NULL,
    lead_id NUMBER
);

ALTER TABLE dev_schema.team_leads
ADD CONSTRAINT fk_team FOREIGN KEY (team_id) REFERENCES dev_schema.teams(team_id);

ALTER TABLE dev_schema.teams
ADD CONSTRAINT fk_lead FOREIGN KEY (lead_id) REFERENCES dev_schema.team_leads(lead_id);