DROP USER dev_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER dev_schema IDENTIFIED BY dev_password;
GRANT CONNECT, RESOURCE TO DEV_SCHEMA;
GRANT ALL PRIVILEGES TO DEV_SCHEMA;

CREATE TABLE dev.Company (
    CompanyID INT PRIMARY KEY,
    CompanyName VARCHAR2(255),
    Industry VARCHAR2(100)
);

CREATE TABLE dev.Department (
    DepartmentID INT PRIMARY KEY,
    DepartmentName VARCHAR2(255)
);

CREATE TABLE dev.Employee (
    EmployeeID INT PRIMARY KEY,
    DepartmentID INT,
    Name VARCHAR2(255),
    Email VARCHAR2(255),
    FOREIGN KEY (DepartmentID) REFERENCES dev.Department(DepartmentID)
);

CREATE INDEX dev.idx_employee_email ON dev.Employee(Email);

CREATE OR REPLACE PROCEDURE dev.AddEmployee (
    p_ID INT,
    p_DepartmentID INT,
    p_Name VARCHAR2,
    p_Email VARCHAR2
) AS
BEGIN
    INSERT INTO dev.Employee (EmployeeID, DepartmentID, Name, Email)
    VALUES (p_ID, p_DepartmentID, p_Name, p_Email);
END;
/

CREATE OR REPLACE FUNCTION dev.CalcBonus (
    salary IN NUMBER, percent IN NUMBER
) RETURN NUMBER AS
BEGIN
    RETURN ROUND(salary * percent / 100, 2);
END;
/

CREATE OR REPLACE PACKAGE dev.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Percent NUMBER);
END EmployeeUtils;
/

CREATE OR REPLACE PACKAGE BODY dev.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Percent NUMBER) IS
    BEGIN
        UPDATE dev.Employee
        SET Email = Email
        WHERE EmployeeID = p_EmpID;
    END;
END EmployeeUtils;
/
