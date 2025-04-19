BEGIN
   EXECUTE IMMEDIATE 'DROP TABLE table_c CASCADE CONSTRAINTS';
EXCEPTION
   WHEN OTHERS THEN NULL;
END;
/
BEGIN
   EXECUTE IMMEDIATE 'DROP TABLE table_b CASCADE CONSTRAINTS';
EXCEPTION
   WHEN OTHERS THEN NULL;
END;
/
BEGIN
   EXECUTE IMMEDIATE 'DROP TABLE table_a CASCADE CONSTRAINTS';
EXCEPTION
   WHEN OTHERS THEN NULL;
END;
/

BEGIN
  FOR rec IN (SELECT object_name, object_type
                FROM user_objects 
               WHERE object_name IN ('TABLE_A','TABLE_B','TABLE_C','AUDIT_LOG','REPORT_LOG',
                                       'SEQ_AUDIT_LOG','PKG_AUDIT_MAINT'))
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP ' || rec.object_type || ' ' || rec.object_name;
    END;
  END LOOP;
END;
/

CREATE TABLE TABLE_A (
    ID           NUMBER PRIMARY KEY,
    NAME         VARCHAR2(50) NOT NULL,
    VAL          NUMBER,
    CREATED_AT   TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE TABLE_B (
    ID           NUMBER PRIMARY KEY,
    A_ID         NUMBER NOT NULL,
    DESCRIPTION  VARCHAR2(100),
    AMOUNT       NUMBER,
    CREATED_AT   TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT FK_B_A FOREIGN KEY (A_ID) REFERENCES TABLE_A(ID)
);

CREATE TABLE TABLE_C (
    ID           NUMBER PRIMARY KEY,
    B_ID         NUMBER NOT NULL,
    DESCRIPTION      VARCHAR2(200),
    QUANTITY     NUMBER,
    CREATED_AT   TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT FK_C_B FOREIGN KEY (B_ID) REFERENCES TABLE_B(ID)
);


CREATE TABLE AUDIT_LOG (
    LOG_ID      NUMBER PRIMARY KEY,
    TABLE_NAME  VARCHAR2(30),
    OPERATION   VARCHAR2(10), -- 'INSERT', 'UPDATE', 'DELETE'
    OP_DATE     TIMESTAMP DEFAULT SYSTIMESTAMP,
    REVERT_SQL  CLOB, 
    ROLLBACKED  CHAR(1) DEFAULT 'N'  -- 'N', 'Y' 
);

CREATE SEQUENCE SEQ_AUDIT_LOG START WITH 1;


CREATE TABLE REPORT_LOG (
    REPORT_TIME TIMESTAMP
);


CREATE OR REPLACE TRIGGER trg_audit_table_a
AFTER INSERT OR UPDATE OR DELETE ON TABLE_A
FOR EACH ROW
DECLARE
    v_revert_sql CLOB;
BEGIN
    IF INSERTING THEN
      v_revert_sql := 'DELETE FROM TABLE_A WHERE ID = ' || :NEW.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_A', 'INSERT', v_revert_sql);
    ELSIF UPDATING THEN
      v_revert_sql := 'UPDATE TABLE_A SET ' ||
                      'NAME = ''' || REPLACE(:OLD.NAME, '''', '''''') || ''', ' ||
                      'VAL = ' || :OLD.VAL || ', ' ||
                      'CREATED_AT = TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF'') ' ||
                      'WHERE ID = ' || :OLD.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_A', 'UPDATE', v_revert_sql);
    ELSIF DELETING THEN
      v_revert_sql := 'INSERT INTO TABLE_A (ID, NAME, VAL, CREATED_AT) VALUES (' ||
                      :OLD.ID || ', ''' || REPLACE(:OLD.NAME, '''', '''''') || ''', ' ||
                      :OLD.VAL || ', TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF''))';
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_A', 'DELETE', v_revert_sql);
    END IF;
END;
/
  
CREATE OR REPLACE TRIGGER trg_audit_table_b
AFTER INSERT OR UPDATE OR DELETE ON TABLE_B
FOR EACH ROW
DECLARE
    v_revert_sql CLOB;
BEGIN
    IF INSERTING THEN
      v_revert_sql := 'DELETE FROM TABLE_B WHERE ID = ' || :NEW.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_B', 'INSERT', v_revert_sql);
    ELSIF UPDATING THEN
      v_revert_sql := 'UPDATE TABLE_B SET ' ||
                      'A_ID = ' || :OLD.A_ID || ', ' ||
                      'DESCRIPTION = ''' || REPLACE(:OLD.DESCRIPTION, '''', '''''') || ''', ' ||
                      'AMOUNT = ' || :OLD.AMOUNT || ', ' ||
                      'CREATED_AT = TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF'') ' ||
                      'WHERE ID = ' || :OLD.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_B', 'UPDATE', v_revert_sql);
    ELSIF DELETING THEN
      v_revert_sql := 'INSERT INTO TABLE_B (ID, A_ID, DESCRIPTION, AMOUNT, CREATED_AT) VALUES (' ||
                      :OLD.ID || ', ' || :OLD.A_ID || ', ''' ||
                      REPLACE(:OLD.DESCRIPTION, '''', '''''') || ''', ' ||
                      :OLD.AMOUNT || ', TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF''))';
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_B', 'DELETE', v_revert_sql);
    END IF;
END;
/
  
CREATE OR REPLACE TRIGGER trg_audit_table_c
AFTER INSERT OR UPDATE OR DELETE ON TABLE_C
FOR EACH ROW
DECLARE
    v_revert_sql CLOB;
BEGIN
    IF INSERTING THEN
      v_revert_sql := 'DELETE FROM TABLE_C WHERE ID = ' || :NEW.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_C', 'INSERT', v_revert_sql);
    ELSIF UPDATING THEN
      v_revert_sql := 'UPDATE TABLE_C SET ' ||
                      'B_ID = ' || :OLD.B_ID || ', ' ||
                      'DESCRIPTION = ''' || REPLACE(:OLD.DESCRIPTION, '''', '''''') || ''', ' ||
                      'QUANTITY = ' || :OLD.QUANTITY || ', ' ||
                      'CREATED_AT = TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF'') ' ||
                      'WHERE ID = ' || :OLD.ID;
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_C', 'UPDATE', v_revert_sql);
    ELSIF DELETING THEN
      v_revert_sql := 'INSERT INTO TABLE_C (ID, B_ID, DESCRIPTION, QUANTITY, CREATED_AT) VALUES (' ||
                      :OLD.ID || ', ' || :OLD.B_ID || ', ''' ||
                      REPLACE(:OLD.DESCRIPTION, '''', '''''') || ''', ' ||
                      :OLD.QUANTITY || ', TO_TIMESTAMP(''' || TO_CHAR(:OLD.CREATED_AT, 'YYYY-MM-DD HH24:MI:SS.FF') ||
                      ''', ''YYYY-MM-DD HH24:MI:SS.FF''))';
      INSERT INTO AUDIT_LOG (LOG_ID, TABLE_NAME, OPERATION, REVERT_SQL)
      VALUES (SEQ_AUDIT_LOG.NEXTVAL, 'TABLE_C', 'DELETE', v_revert_sql);
    END IF;
END;
/
  

CREATE OR REPLACE PACKAGE PKG_AUDIT_MAINT AS
  PROCEDURE ROLLBACK_CHANGES(p_target_time IN TIMESTAMP);
  PROCEDURE ROLLBACK_CHANGES(p_interval_ms IN NUMBER);

  PROCEDURE GENERATE_AUDIT_REPORT(p_start_time IN TIMESTAMP DEFAULT NULL, p_report_html OUT CLOB);
END PKG_AUDIT_MAINT;
/
  
CREATE OR REPLACE PACKAGE BODY PKG_AUDIT_MAINT AS
  PROCEDURE process_revert(p_log_id IN NUMBER, p_revert_sql IN CLOB) IS
    v_sql VARCHAR2(32767);
  BEGIN
    v_sql := DBMS_LOB.SUBSTR(p_revert_sql, 32767, 1);
    EXECUTE IMMEDIATE v_sql;
    UPDATE AUDIT_LOG SET ROLLBACKED = 'Y' WHERE LOG_ID = p_log_id;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE;
  END process_revert;

  PROCEDURE ROLLBACK_CHANGES(p_target_time IN TIMESTAMP) IS
    cur_time TIMESTAMP DEFAULT SYSTIMESTAMP;
    CURSOR cur_op IS
      SELECT LOG_ID, TABLE_NAME, REVERT_SQL
      FROM AUDIT_LOG
      WHERE OP_DATE > p_target_time AND OP_DATE <= cur_time AND ROLLBACKED = 'N'
      ORDER BY 
         OP_DATE DESC;
  BEGIN
    FOR rec IN cur_op LOOP
      process_revert(rec.LOG_ID, rec.REVERT_SQL);
    END LOOP;

    DELETE FROM AUDIT_LOG WHERE OP_DATE > cur_time;

    COMMIT;
  END ROLLBACK_CHANGES;
  
  PROCEDURE ROLLBACK_CHANGES(p_interval_ms IN NUMBER) IS
    v_target_time TIMESTAMP;
  BEGIN
    v_target_time := SYSTIMESTAMP - NUMTODSINTERVAL(p_interval_ms/1000, 'SECOND');
    ROLLBACK_CHANGES(v_target_time);
  END ROLLBACK_CHANGES;
  
  PROCEDURE GENERATE_AUDIT_REPORT(p_start_time IN TIMESTAMP DEFAULT NULL, p_report_html OUT CLOB) IS
    v_start_time TIMESTAMP;
    v_curr_time TIMESTAMP := SYSTIMESTAMP;
    v_cnt_insert_table_a NUMBER;
    v_cnt_update_table_a NUMBER;
    v_cnt_delete_table_a NUMBER;
    v_cnt_insert_table_b NUMBER;
    v_cnt_update_table_b NUMBER;
    v_cnt_delete_table_b NUMBER;
    v_cnt_insert_table_c NUMBER;
    v_cnt_update_table_c NUMBER;
    v_cnt_delete_table_c NUMBER;
  BEGIN
    IF p_start_time IS NOT NULL THEN
      v_start_time := p_start_time;
    ELSE
      SELECT NVL(MAX(REPORT_TIME), SYSTIMESTAMP - INTERVAL '1' DAY)
      INTO v_start_time
      FROM REPORT_LOG;
    END IF;
    
    SELECT COUNT(CASE WHEN OPERATION = 'INSERT' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'UPDATE' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'DELETE' THEN 1 END)
      INTO v_cnt_insert_table_a, v_cnt_update_table_a, v_cnt_delete_table_a
      FROM AUDIT_LOG
     WHERE TABLE_NAME = 'TABLE_A' 
       AND OP_DATE > v_start_time 
       AND ROLLBACKED = 'N';
    
    SELECT COUNT(CASE WHEN OPERATION = 'INSERT' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'UPDATE' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'DELETE' THEN 1 END)
      INTO v_cnt_insert_table_b, v_cnt_update_table_b, v_cnt_delete_table_b
      FROM AUDIT_LOG
     WHERE TABLE_NAME = 'TABLE_B' 
       AND OP_DATE > v_start_time 
       AND ROLLBACKED = 'N';
    
    SELECT COUNT(CASE WHEN OPERATION = 'INSERT' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'UPDATE' THEN 1 END),
           COUNT(CASE WHEN OPERATION = 'DELETE' THEN 1 END)
      INTO v_cnt_insert_table_c, v_cnt_update_table_c, v_cnt_delete_table_c
      FROM AUDIT_LOG
     WHERE TABLE_NAME = 'TABLE_C' 
       AND OP_DATE > v_start_time 
       AND ROLLBACKED = 'N';

    p_report_html :=
       '<html>' ||
       '<head>' ||
       '<meta charset="UTF-8">' ||
       '<meta name="viewport" content="width=device-width, initial-scale=1.0">' ||
       '<title>Отчёт по изменениям</title>' ||
       '<style>table { border-collapse: collapse; width:100%; } ' ||
                       'th, td { border: 1px solid #ccc; padding: 8px; text-align: center; } ' ||
                       'th { background-color: #f2f2f2; }' ||
       '</style>' ||
       '</head>' ||
       '<body>' ||
       '<h2>Отчёт по изменениям с ' || TO_CHAR(v_start_time, 'YYYY-MM-DD HH24:MI:SS') || ' по ' || 
          TO_CHAR(v_curr_time, 'YYYY-MM-DD HH24:MI:SS') || '</h2>' ||
       '<table>' ||
         '<tr>' ||
           '<th>Таблица</th><th>INSERT</th><th>UPDATE</th><th>DELETE</th>' ||
         '</tr>' ||
         '<tr>' ||
           '<td>TABLE_A</td>' ||
           '<td>' || v_cnt_insert_table_a || '</td>' ||
           '<td>' || v_cnt_update_table_a || '</td>' ||
           '<td>' || v_cnt_delete_table_a || '</td>' ||
         '</tr>' ||
         '<tr>' ||
           '<td>TABLE_B</td>' ||
           '<td>' || v_cnt_insert_table_b || '</td>' ||
           '<td>' || v_cnt_update_table_b || '</td>' ||
           '<td>' || v_cnt_delete_table_b || '</td>' ||
         '</tr>' ||
         '<tr>' ||
           '<td>TABLE_C</td>' ||
           '<td>' || v_cnt_insert_table_c || '</td>' ||
           '<td>' || v_cnt_update_table_c || '</td>' ||
           '<td>' || v_cnt_delete_table_c || '</td>' ||
         '</tr>' ||
       '</table>' ||
       '</body>' ||
       '</html>';

    INSERT INTO REPORT_LOG (REPORT_TIME) VALUES (v_curr_time);
    COMMIT;
  END GENERATE_AUDIT_REPORT;
  
END PKG_AUDIT_MAINT;
/
  
--------

TRUNCATE TABLE TABLE_C;
TRUNCATE TABLE TABLE_B;
TRUNCATE TABLE TABLE_A;
TRUNCATE TABLE AUDIT_LOG;

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET LONG 1000000;
SET PAGESIZE 0;

INSERT INTO TABLE_A (ID, NAME, VAL) VALUES (1, 'Alpha', 100);
INSERT INTO TABLE_A (ID, NAME, VAL) VALUES (2, 'Beta', 200);
COMMIT;

INSERT INTO TABLE_B (ID, A_ID, DESCRIPTION, AMOUNT) VALUES (10, 1, 'Alpha-Desc', 1000);
INSERT INTO TABLE_B (ID, A_ID, DESCRIPTION, AMOUNT) VALUES (11, 2, 'Beta-Desc', 2000);
COMMIT;

INSERT INTO TABLE_C (ID, B_ID, DESCRIPTION, QUANTITY) VALUES (100, 10, 'Alpha Comment 1', 10);
INSERT INTO TABLE_C (ID, B_ID, DESCRIPTION, QUANTITY) VALUES (101, 10, 'Alpha Comment 2', 20);
INSERT INTO TABLE_C (ID, B_ID, DESCRIPTION, QUANTITY) VALUES (102, 11, 'Beta Comment', 30);
COMMIT;

UPDATE TABLE_A 
   SET VAL = 150 
 WHERE ID = 1;

UPDATE TABLE_B 
   SET AMOUNT = 1100 
 WHERE ID = 10;

DELETE FROM TABLE_C 
 WHERE ID = 101;
COMMIT;

VARIABLE html_report CLOB
EXEC PKG_AUDIT_MAINT.GENERATE_AUDIT_REPORT(NULL, :html_report);
PRINT html_report;

SELECT SYSTIMESTAMP AS PIVOT_TIMESTAMP FROM DUAL;

INSERT INTO TABLE_A (ID, NAME, VAL) VALUES (3, 'Gamma', 300);
INSERT INTO TABLE_B (ID, A_ID, DESCRIPTION, AMOUNT) VALUES (12, 3, 'Gamma-Desc', 3000);
INSERT INTO TABLE_C (ID, B_ID, DESCRIPTION, QUANTITY) VALUES (103, 12, 'Gamma Comment', 40);
COMMIT;

UPDATE TABLE_A 
   SET VAL = 175 
 WHERE ID = 1;

UPDATE TABLE_B 
   SET AMOUNT = 1150 
 WHERE ID = 10;

DELETE FROM TABLE_C 
 WHERE ID = 102;
COMMIT;

-----

---- EXEC PKG_AUDIT_MAINT.ROLLBACK_CHANGES(TO_TIMESTAMP('2025-04-06 10:30:00.000000','YYYY-MM-DD HH24:MI:SS.FF'));
---COMMIT;

EXEC PKG_AUDIT_MAINT.ROLLBACK_CHANGES(30000000);
COMMIT;

SELECT * FROM TABLE_A;
SELECT * FROM TABLE_B;
SELECT * FROM TABLE_C;

VARIABLE html_report CLOB
EXEC PKG_AUDIT_MAINT.GENERATE_AUDIT_REPORT(NULL, :html_report);
PRINT html_report;