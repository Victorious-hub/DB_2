-- DEPRECATED! Legacy

CREATE USER admin_schema IDENTIFIED BY admin_password;
GRANT CONNECT, RESOURCE TO admin_schema;
GRANT SELECT ANY DICTIONARY TO admin_schema;
GRANT ALL PRIVILEGES TO ADMIN_SCHEMA;
SET SERVEROUTPUT ON;

ALTER SESSION SET CURRENT_SCHEMA = admin_schema;

CREATE USER dev_schema IDENTIFIED BY dev_password;
CREATE USER prod_schema IDENTIFIED BY prod_password;
GRANT CONNECT, RESOURCE TO dev_schema, prod_schema;


ALTER SESSION SET CURRENT_SCHEMA = dev_schema;

CREATE TABLE dev_table1 (
    id NUMBER,
    name VARCHAR2(100)
);
CREATE TABLE dev_table2 (
    id NUMBER,
    description VARCHAR2(200)
);
CREATE TABLE common_table (
    id NUMBER,
    name VARCHAR2(100),
    age NUMBER
);

CREATE OR REPLACE PROCEDURE hello_world IS 
BEGIN
    DBMS_OUTPUT.PUT_LINE('Привет, мир!');
END hello_world;


ALTER SESSION SET CURRENT_SCHEMA = prod_schema;

CREATE TABLE prod_table1 (
    id NUMBER,
    name VARCHAR2(100)
);
CREATE TABLE prod_table3 (
    id NUMBER,
    details VARCHAR2(200)
);
CREATE TABLE common_table (
    id NUMBER,
    name VARCHAR2(100),
    email VARCHAR2(100) 
);


ALTER SESSION SET CURRENT_SCHEMA = dev_schema;

CREATE TABLE departments (
    department_id NUMBER PRIMARY KEY,
    department_name VARCHAR2(100) NOT NULL
);

CREATE TABLE employees (
    employee_id NUMBER PRIMARY KEY,
    employee_name VARCHAR2(100) NOT NULL,
    department_id NUMBER,
    CONSTRAINT fk_department FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

CREATE TABLE projects (
    project_id NUMBER PRIMARY KEY,
    project_name VARCHAR2(100) NOT NULL,
    employee_id NUMBER,
    CONSTRAINT fk_employee FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
);

CREATE TABLE team_leads (
    lead_id NUMBER PRIMARY KEY,
    lead_name VARCHAR2(100) NOT NULL,
    team_id NUMBER
);

CREATE TABLE teams (
    team_id NUMBER PRIMARY KEY,
    team_name VARCHAR2(100) NOT NULL,
    lead_id NUMBER
);

ALTER TABLE team_leads
ADD CONSTRAINT fk_team FOREIGN KEY (team_id) REFERENCES teams(team_id);

ALTER TABLE teams
ADD CONSTRAINT fk_lead FOREIGN KEY (lead_id) REFERENCES team_leads(lead_id);