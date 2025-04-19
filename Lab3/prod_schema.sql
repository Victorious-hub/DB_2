DROP USER prod_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER prod_schema IDENTIFIED BY prod_password;
GRANT ALL PRIVILEGES TO PROD_SCHEMA;
GRANT CONNECT, RESOURCE TO PROD_SCHEMA;


CREATE TABLE prod_schema.TestTable (
    Company1ID INT PRIMARY KEY,
    CompanyName1 VARCHAR2(255)
);

CREATE TABLE prod_schema.Company (
    CompanyID INT PRIMARY KEY,
    CompanyName VARCHAR2(255)
);



CREATE TABLE prod_schema.Department (
    DepartmentID INT PRIMARY KEY,
    CompanyID INT,
    DepartmentName VARCHAR2(255),
    FOREIGN KEY (CompanyID) REFERENCES prod_schema.Company(CompanyID)
);

CREATE TABLE prod_schema.Employee (
    EmployeeID INT PRIMARY KEY,
    DepartmentID INT,
    Name VARCHAR2(255),
    Salary NUMBER,
    FOREIGN KEY (DepartmentID) REFERENCES prod_schema.Department(DepartmentID)
);

CREATE INDEX prod_schema.idx_employee_name ON prod_schema.Employee(Name);

CREATE OR REPLACE PROCEDURE prod_schema.AddEmployee (
    p_ID INT,
    p_DepartmentID INT,
    p_Name VARCHAR2,
    p_Salary NUMBER
) AS
BEGIN
    INSERT INTO prod_schema.Employee (EmployeeID, DepartmentID, Name, Salary)
    VALUES (p_ID, p_DepartmentID, p_Name, p_Salary);
END;
/

CREATE OR REPLACE FUNCTION prod_schema.CalcBonus (
    salary IN NUMBER, percent IN NUMBER
) RETURN NUMBER AS
BEGIN
    RETURN salary * percent / 100;
END;
/

CREATE OR REPLACE PACKAGE prod_schema.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Amount NUMBER);
END EmployeeUtils;
/

CREATE OR REPLACE PACKAGE BODY prod_schema.EmployeeUtils AS
    PROCEDURE RaiseSalary(p_EmpID INT, p_Amount NUMBER) IS
    BEGIN
        UPDATE prod_schema.Employee
        SET Salary = Salary + p_Amount
        WHERE EmployeeID = p_EmpID;
    END;
END EmployeeUtils;
/

-- Loops
CREATE TABLE prod_schema.table_a (
    id NUMBER PRIMARY KEY,
    name VARCHAR2(100)
);

CREATE TABLE prod_schema.table_b (
    id NUMBER PRIMARY KEY,
    a_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_b_a FOREIGN KEY (a_id) REFERENCES prod_schema.table_a (id)
);

CREATE TABLE prod_schema.table_c (
    id NUMBER PRIMARY KEY,
    b_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_c_b FOREIGN KEY (b_id) REFERENCES prod_schema.table_b (id)
);


CREATE TABLE prod_schema.table_d (
    id NUMBER PRIMARY KEY,
    c_id NUMBER,
    name VARCHAR2(100),
    CONSTRAINT fk_d_c FOREIGN KEY (c_id) REFERENCES prod_schema.table_c (id)
);

-- Циклическая зависимость
ALTER TABLE prod_schema.table_a
ADD CONSTRAINT fk_a_d FOREIGN KEY (id) REFERENCES prod_schema.table_d (id);
