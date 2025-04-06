DROP USER prod_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER prod_schema IDENTIFIED BY prod_password;
GRANT ALL PRIVILEGES TO PROD_SCHEMA;
GRANT CONNECT, RESOURCE TO PROD_SCHEMA;

CREATE TABLE prod.Company (
    CompanyID INT PRIMARY KEY,
    CompanyName VARCHAR2(255)
);

CREATE TABLE prod.Department (
    DepartmentID INT PRIMARY KEY,
    CompanyID INT,
    DepartmentName VARCHAR2(255),
    FOREIGN KEY (CompanyID) REFERENCES prod.Company(CompanyID)
);

CREATE TABLE prod.Employee (
    EmployeeID INT PRIMARY KEY,
    DepartmentID INT,
    Name VARCHAR2(255),
    Salary NUMBER,
    FOREIGN KEY (DepartmentID) REFERENCES prod.Department(DepartmentID)
);

CREATE INDEX prod.idx_employee_name ON prod.Employee(Name);

CREATE OR REPLACE PROCEDURE prod.AddEmployee (
    p_ID INT,
    p_DepartmentID INT,
    p_Name VARCHAR2,
    p_Salary NUMBER
) AS
BEGIN
    INSERT INTO prod.Employee (EmployeeID, DepartmentID, Name, Salary)
    VALUES (p_ID, p_DepartmentID, p_Name, p_Salary);
END;
/

CREATE OR REPLACE FUNCTION prod.CalcBonus (
    salary IN NUMBER, percent IN NUMBER
) RETURN NUMBER AS
BEGIN
    RETURN salary * percent / 100;
END;
/

CREATE OR REPLACE PACKAGE prod.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Amount NUMBER);
END EmployeeUtils;
/

CREATE OR REPLACE PACKAGE BODY prod.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Amount NUMBER) IS
    BEGIN
        UPDATE prod.Employee
        SET Salary = Salary + p_Amount
        WHERE EmployeeID = p_EmpID;
    END;
END EmployeeUtils;
/
