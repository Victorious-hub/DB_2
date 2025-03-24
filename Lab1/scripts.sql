-- 1.Создайте таблицу MyTable(id number, val number)

CREATE TABLE MyTable (
    id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    val NUMBER
);

-- 2. Напишите анонимный блок, который записывает в таблицу MyTable 10 000 целых случайных записей.
DECLARE
    v_counter NUMBER := 1;
BEGIN
    FOR v_counter IN 1..10000 LOOP
        INSERT INTO MyTable (val) VALUES (TRUNC(DBMS_RANDOM.VALUE(1, 10000)));
    END LOOP;
    
    COMMIT;
END;

-- 3. Напишите собственную функцию, которая выводит TRUE если четных значений val в таблице MyTable больше, 
-- FALSE если больше нечетных значений и EQUAL если количество четных и нечетных равно

CREATE OR REPLACE FUNCTION check_even_odd_balance RETURN VARCHAR2 IS
    even_count NUMBER;
    odd_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO even_count FROM MyTable WHERE MOD(val, 2) = 0;
    SELECT COUNT(*) INTO odd_count FROM MyTable WHERE MOD(val, 2) <> 0;

    IF even_count > odd_count THEN
        RETURN 'TRUE';
    ELSIF even_count < odd_count THEN
        RETURN 'FALSE';
    ELSE
        RETURN 'EQUAL';
    END IF;
END check_even_odd_balance;

SELECT check_even_odd_balance FROM dual;


-- 4. Напишите функцию, которая по введенному значению ID, сгенерирует и выведет в консоль текстовое значение команды insert для вставки указанной строки

CREATE OR REPLACE FUNCTION generate_insert_statement(p_id NUMBER) RETURN VARCHAR2 IS
    v_val NUMBER;
    v_sql VARCHAR2(4000);
BEGIN
    SELECT val INTO v_val FROM MyTable WHERE id = p_id;

    v_sql := 'INSERT INTO MyTable (id, val) VALUES (' || p_id || ', ' || v_val || ');';

    DBMS_OUTPUT.PUT_LINE(v_sql);
    RETURN v_sql;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'Error: ID ' || p_id || ' not found in MyTable.';
    WHEN OTHERS THEN
        RETURN 'Error: ' || SQLERRM;
END generate_insert_statement;

-- Usage
SET SERVEROUTPUT ON;
SELECT generate_insert_statement(1) FROM dual;


-- 5. Написать процедуры, реализующие DML операции (INSERT, UPDATE, DELETE) для указанной таблицы 

CREATE OR REPLACE PROCEDURE insert_into_mytable(p_val NUMBER) AS
BEGIN
    INSERT INTO MyTable (val) VALUES (p_val);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Inserted: val = ' || p_val);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END insert_into_mytable;


-- Usage
BEGIN
    insert_into_mytable(1234);
END;
-- Usage


CREATE OR REPLACE PROCEDURE update_mytable(p_id NUMBER, p_new_val NUMBER) AS
BEGIN
    UPDATE MyTable 
    SET val = p_new_val 
    WHERE id = p_id;

    IF SQL%ROWCOUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: ID ' || p_id || ' not found.');
    ELSE
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Updated: ID = ' || p_id || ', new val = ' || p_new_val);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END update_mytable;


-- Usage
BEGIN
    update_mytable(1, 9999);
END;
-- Usage



CREATE OR REPLACE PROCEDURE delete_from_mytable(p_id NUMBER) AS
BEGIN
    DELETE FROM MyTable WHERE id = p_id;

    IF SQL%ROWCOUNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Error: ID ' || p_id || ' not found.');
    ELSE
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Deleted: ID = ' || p_id);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END delete_from_mytable;

-- Usage
BEGIN
    delete_from_mytable(1);
END;
-- Usage


-- 6. Создайте функцию, вычисляющую общее вознаграждение за год. 
-- На вход функции подаются значение месячной зарплаты и процент годовых премиальных. 
-- В общем случае общее вознаграждение= (1+ процент годовых премиальных)*12* значение месячной зарплаты. 
-- При этом предусмотреть что процент вводится как целое число, и требуется преобразовать его к дробному. 
-- Предусмотреть защиту от ввода некорректных данных.


-- recompile than
CREATE OR REPLACE FUNCTION calculate_annual_compensation(
    p_monthly_salary NUMBER,
    p_bonus_percent NUMBER
) RETURN NUMBER IS
    v_bonus_factor NUMBER;
    v_total_compensation NUMBER;
BEGIN
    IF p_monthly_salary <= 0 THEN
        RETURN NULL;
    ELSIF p_bonus_percent < 0 OR p_bonus_percent > 100 THEN
        RETURN NULL;
    END IF;

    v_bonus_factor := 1 + (p_bonus_percent / 100);
    v_total_compensation := v_bonus_factor * 12 * p_monthly_salary;
    RETURN v_total_compensation;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END calculate_annual_compensation;


-- Usage(show error)
DECLARE
    v_result NUMBER;
BEGIN
    v_result := calculate_annual_compensation(-5000, 10);
    DBMS_OUTPUT.PUT_LINE('Total Compensation: ' || v_result);
END;
