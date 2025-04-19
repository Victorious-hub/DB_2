CREATE OR REPLACE PROCEDURE Compare_Schemas(
  p_dev_schema  IN VARCHAR2,
  p_prod_schema IN VARCHAR2
)
  AUTHID CURRENT_USER
AS
  TYPE t_varchar_table IS TABLE OF VARCHAR2(128);
  v_affected_tables t_varchar_table := t_varchar_table();

  TYPE t_issue_map IS TABLE OF VARCHAR2(10) INDEX BY VARCHAR2(128);
  v_issue_map t_issue_map;

  TYPE t_dep_count_map IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
  v_dep_count t_dep_count_map;

  TYPE t_children_map IS TABLE OF t_varchar_table INDEX BY VARCHAR2(128);
  v_children t_children_map;

  v_sorted         t_varchar_table := t_varchar_table();
  v_sorted_count   PLS_INTEGER := 0;
  v_count          NUMBER;
  v_table_name     VARCHAR2(128);
  v_cycles_found   BOOLEAN := FALSE;

  v_dev_ddl        CLOB;
  v_prod_ddl       CLOB;

  FUNCTION normalize_ddl(p_ddl IN CLOB) RETURN CLOB IS
    v_normalized CLOB;
  BEGIN
    v_normalized := p_ddl;
    v_normalized := REPLACE(v_normalized, CHR(10), ' ');
    v_normalized := REPLACE(v_normalized, CHR(13), ' ');
    v_normalized := REGEXP_REPLACE(v_normalized, '\s+', ' ');
    v_normalized := TRIM(v_normalized);
    v_normalized := REGEXP_REPLACE(v_normalized, '"[^"]+"\.', '');
    v_normalized := REGEXP_REPLACE(v_normalized, 'EDITIONABLE', '');
    v_normalized := REGEXP_REPLACE(v_normalized, 'END\s+\w+;', 'END;');
    RETURN v_normalized;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN p_ddl;
  END normalize_ddl;

  FUNCTION replace_schema(p_ddl IN CLOB) RETURN CLOB IS
  BEGIN
    RETURN REPLACE(p_ddl, '"' || UPPER(p_dev_schema) || '"', '"' || UPPER(p_prod_schema) || '"');
  END replace_schema;

BEGIN
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'OID', FALSE);

  FOR rec IN (
    SELECT dt.table_name,
           CASE
             WHEN pt.table_name IS NULL THEN 'MISSING'
             WHEN (SELECT COUNT(*) FROM (
                      SELECT column_name, data_type, data_length, nullable
                      FROM all_tab_columns
                      WHERE owner = UPPER(p_dev_schema)
                        AND table_name = dt.table_name
                      MINUS
                      SELECT column_name, data_type, data_length, nullable
                      FROM all_tab_columns
                      WHERE owner = UPPER(p_prod_schema)
                        AND table_name = dt.table_name
                   )) > 0 THEN 'DIFF'
           END AS issue
    FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
    LEFT JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
      ON dt.table_name = pt.table_name
    WHERE pt.table_name IS NULL OR
          ((SELECT COUNT(*) FROM (
              SELECT column_name, data_type, data_length, nullable
              FROM all_tab_columns
              WHERE owner = UPPER(p_dev_schema)
                AND table_name = dt.table_name
              MINUS
              SELECT column_name, data_type, data_length, nullable
              FROM all_tab_columns
              WHERE owner = UPPER(p_prod_schema)
                AND table_name = dt.table_name
            )) > 0)
  ) LOOP
    v_affected_tables.EXTEND;
    v_affected_tables(v_affected_tables.COUNT) := rec.table_name;
    v_issue_map(rec.table_name) := rec.issue;
  END LOOP;

  FOR i IN 1 .. v_affected_tables.COUNT LOOP
    v_dep_count(v_affected_tables(i)) := 0;
    v_children(v_affected_tables(i)) := t_varchar_table();
  END LOOP;

  FOR i IN 1 .. v_affected_tables.COUNT LOOP
    v_table_name := v_affected_tables(i);
    SELECT COUNT(*) INTO v_count
    FROM all_tables
    WHERE owner = UPPER(p_prod_schema)
      AND table_name = v_table_name;
    DECLARE
      v_schema_for_fk VARCHAR2(30);
    BEGIN
      IF v_count > 0 THEN
        v_schema_for_fk := UPPER(p_prod_schema);
      ELSE
        v_schema_for_fk := UPPER(p_dev_schema);
      END IF;
      FOR fk_rec IN (
        SELECT a.table_name AS child, c.table_name AS parent
        FROM all_constraints a
        JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
        WHERE a.constraint_type = 'R'
          AND a.owner = v_schema_for_fk
          AND a.table_name = v_table_name
      ) LOOP
        FOR j IN 1 .. v_affected_tables.COUNT LOOP
          IF fk_rec.parent = v_affected_tables(j) THEN
            v_dep_count(v_table_name) := v_dep_count(v_table_name) + 1;
            v_children(fk_rec.parent).EXTEND;
            v_children(fk_rec.parent)(v_children(fk_rec.parent).COUNT) := v_table_name;
          END IF;
        END LOOP;
      END LOOP;
    END;
  END LOOP;

  DECLARE
    TYPE t_queue IS TABLE OF VARCHAR2(128);
    v_queue t_queue := t_queue();
    v_queue_start PLS_INTEGER := 1;
    v_queue_end   PLS_INTEGER := 0;
  BEGIN
    FOR i IN 1 .. v_affected_tables.COUNT LOOP
      IF v_dep_count(v_affected_tables(i)) = 0 THEN
        v_queue_end := v_queue_end + 1;
        v_queue.EXTEND;
        v_queue(v_queue_end) := v_affected_tables(i);
      END IF;
    END LOOP;
    WHILE v_queue_start <= v_queue_end LOOP
      DECLARE
        v_current VARCHAR2(128);
      BEGIN
        v_current := v_queue(v_queue_start);
        v_queue_start := v_queue_start + 1;
        v_sorted_count := v_sorted_count + 1;
        v_sorted.EXTEND;
        v_sorted(v_sorted_count) := v_current;
        FOR i IN 1 .. v_children(v_current).COUNT LOOP
          DECLARE
            v_child VARCHAR2(128) := v_children(v_current)(i);
          BEGIN
            v_dep_count(v_child) := v_dep_count(v_child) - 1;
            IF v_dep_count(v_child) = 0 THEN
              v_queue_end := v_queue_end + 1;
              v_queue.EXTEND;
              v_queue(v_queue_end) := v_child;
            END IF;
          END;
        END LOOP;
      END;
    END LOOP;
    IF v_sorted_count < v_affected_tables.COUNT THEN
      FOR i IN 1 .. v_affected_tables.COUNT LOOP
        IF v_dep_count(v_affected_tables(i)) > 0 THEN
          v_sorted_count := v_sorted_count + 1;
          v_sorted.EXTEND;
          v_sorted(v_sorted_count) := v_affected_tables(i);
        END IF;
      END LOOP;
    END IF;
  END;

  -- filepath: untitled:Untitled-21
FOR rec IN (
  SELECT table_name 
  FROM all_tables
  WHERE owner = UPPER(p_dev_schema)
    AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema))
) LOOP
  DBMS_OUTPUT.PUT_LINE('Таблица есть в DEV, но отсутствует в PROD: ' || rec.table_name);
END LOOP;

FOR rec IN (
  SELECT table_name 
  FROM all_tables
  WHERE owner = UPPER(p_prod_schema)
    AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
) LOOP
  DBMS_OUTPUT.PUT_LINE('Таблица есть в PROD, но отсутствует в DEV: ' || rec.table_name);
END LOOP;

FOR rec IN (
  SELECT dt.table_name
  FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
  JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
    ON dt.table_name = pt.table_name
) LOOP
  DBMS_OUTPUT.PUT_LINE('Таблица с различиями: ' || rec.table_name);
  FOR col_diff IN (
    SELECT column_name, data_type, data_length, nullable
    FROM (
      SELECT column_name, data_type, data_length, nullable
      FROM all_tab_columns
      WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
      MINUS
      SELECT column_name, data_type, data_length, nullable
      FROM all_tab_columns
      WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
    )
    UNION ALL
    SELECT column_name, data_type, data_length, nullable
    FROM (
      SELECT column_name, data_type, data_length, nullable
      FROM all_tab_columns
      WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
      MINUS
      SELECT column_name, data_type, data_length, nullable
      FROM all_tab_columns
      WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
    )
  ) LOOP
    DBMS_OUTPUT.PUT_LINE('  Различие в колонке: ' || col_diff.column_name || 
                         ' (Тип данных: ' || col_diff.data_type || 
                         ', Длина: ' || col_diff.data_length || 
                         ', Nullable: ' || col_diff.nullable || ')');
  END LOOP;
END LOOP;

  DECLARE
    TYPE t_varchar_table_all IS TABLE OF VARCHAR2(128);
    v_all_tables_prod t_varchar_table_all := t_varchar_table_all();
    TYPE t_dep_count_map_all IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
    v_all_dep_count_prod t_dep_count_map_all;
    TYPE t_children_map_all IS TABLE OF t_varchar_table_all INDEX BY VARCHAR2(128);
    v_all_children_prod t_children_map_all;
    v_all_sorted_count_prod PLS_INTEGER := 0;
  BEGIN
    FOR rec IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) LOOP
      v_all_tables_prod.EXTEND;
      v_all_tables_prod(v_all_tables_prod.COUNT) := rec.table_name;
      v_all_dep_count_prod(rec.table_name) := 0;
      v_all_children_prod(rec.table_name) := t_varchar_table_all();
    END LOOP;
    FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
      FOR fk_rec IN (
        SELECT a.table_name AS child, c.table_name AS parent
        FROM all_constraints a
        JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
        WHERE a.constraint_type = 'R'
          AND a.owner = UPPER(p_prod_schema)
          AND a.table_name = v_all_tables_prod(i)
      ) LOOP
        FOR j IN 1 .. v_all_tables_prod.COUNT LOOP
          IF fk_rec.parent = v_all_tables_prod(j) THEN
            v_all_dep_count_prod(v_all_tables_prod(i)) :=
              v_all_dep_count_prod(v_all_tables_prod(i)) + 1;
            v_all_children_prod(fk_rec.parent).EXTEND;
            v_all_children_prod(fk_rec.parent)(v_all_children_prod(fk_rec.parent).COUNT) :=
              v_all_tables_prod(i);
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    DECLARE
      TYPE t_queue_all IS TABLE OF VARCHAR2(128);
      v_queue_all t_queue_all := t_queue_all();
      v_queue_all_start PLS_INTEGER := 1;
      v_queue_all_end   PLS_INTEGER := 0;
    BEGIN
      FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
        IF v_all_dep_count_prod(v_all_tables_prod(i)) = 0 THEN
          v_queue_all_end := v_queue_all_end + 1;
          v_queue_all.EXTEND;
          v_queue_all(v_queue_all_end) := v_all_tables_prod(i);
        END IF;
      END LOOP;
      WHILE v_queue_all_start <= v_queue_all_end LOOP
        DECLARE
          v_current VARCHAR2(128);
        BEGIN
          v_current := v_queue_all(v_queue_all_start);
          v_queue_all_start := v_queue_all_start + 1;
          v_all_sorted_count_prod := v_all_sorted_count_prod + 1;
          FOR i IN 1 .. v_all_children_prod(v_current).COUNT LOOP
            DECLARE
              v_child VARCHAR2(128) := v_all_children_prod(v_current)(i);
            BEGIN
              v_all_dep_count_prod(v_child) := v_all_dep_count_prod(v_child) - 1;
              IF v_all_dep_count_prod(v_child) = 0 THEN
                v_queue_all_end := v_queue_all_end + 1;
                v_queue_all.EXTEND;
                v_queue_all(v_queue_all_end) := v_child;
              END IF;
            END;
          END LOOP;
        END;
      END LOOP;
      IF v_all_sorted_count_prod < v_all_tables_prod.COUNT THEN
      DBMS_OUTPUT.PUT_LINE('Циклические зависимости в PROD: есть');
      DBMS_OUTPUT.PUT_LINE('Следующие таблицы участвуют в цикле:');
        FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
          IF v_all_dep_count_prod(v_all_tables_prod(i)) > 0 THEN
            DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables_prod(i));
          END IF;
        END LOOP;
      ELSE
        DBMS_OUTPUT.PUT_LINE('Циклические зависимости в PROD: нет');
      END IF;
    END;
  END;

  DECLARE
    TYPE t_varchar_table_all IS TABLE OF VARCHAR2(128);
    v_all_tables_dev t_varchar_table_all := t_varchar_table_all();
    TYPE t_dep_count_map_all IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
    v_all_dep_count_dev t_dep_count_map_all;
    TYPE t_children_map_all IS TABLE OF t_varchar_table_all INDEX BY VARCHAR2(128);
    v_all_children_dev t_children_map_all;
    v_all_sorted_count_dev PLS_INTEGER := 0;
  BEGIN
    FOR rec IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) LOOP
      v_all_tables_dev.EXTEND;
      v_all_tables_dev(v_all_tables_dev.COUNT) := rec.table_name;
      v_all_dep_count_dev(rec.table_name) := 0;
      v_all_children_dev(rec.table_name) := t_varchar_table_all();
    END LOOP;
    FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
      FOR fk_rec IN (
        SELECT a.table_name AS child, c.table_name AS parent
        FROM all_constraints a
        JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
        WHERE a.constraint_type = 'R'
          AND a.owner = UPPER(p_dev_schema)
          AND a.table_name = v_all_tables_dev(i)
      ) LOOP
        FOR j IN 1 .. v_all_tables_dev.COUNT LOOP
          IF fk_rec.parent = v_all_tables_dev(j) THEN
            v_all_dep_count_dev(v_all_tables_dev(i)) :=
              v_all_dep_count_dev(v_all_tables_dev(i)) + 1;
            v_all_children_dev(fk_rec.parent).EXTEND;
            v_all_children_dev(fk_rec.parent)(v_all_children_dev(fk_rec.parent).COUNT) :=
              v_all_tables_dev(i);
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    DECLARE
      TYPE t_queue_all IS TABLE OF VARCHAR2(128);
      v_queue_all t_queue_all := t_queue_all();
      v_queue_all_start PLS_INTEGER := 1;
      v_queue_all_end   PLS_INTEGER := 0;
    BEGIN
      FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
        IF v_all_dep_count_dev(v_all_tables_dev(i)) = 0 THEN
          v_queue_all_end := v_queue_all_end + 1;
          v_queue_all.EXTEND;
          v_queue_all(v_queue_all_end) := v_all_tables_dev(i);
        END IF;
      END LOOP;
      WHILE v_queue_all_start <= v_queue_all_end LOOP
        DECLARE
          v_current VARCHAR2(128);
        BEGIN
          v_current := v_queue_all(v_queue_all_start);
          v_queue_all_start := v_queue_all_start + 1;
          v_all_sorted_count_dev := v_all_sorted_count_dev + 1;
          FOR i IN 1 .. v_all_children_dev(v_current).COUNT LOOP
            DECLARE
              v_child VARCHAR2(128) := v_all_children_dev(v_current)(i);
            BEGIN
              v_all_dep_count_dev(v_child) := v_all_dep_count_dev(v_child) - 1;
              IF v_all_dep_count_dev(v_child) = 0 THEN
                v_queue_all_end := v_queue_all_end + 1;
                v_queue_all.EXTEND;
                v_queue_all(v_queue_all_end) := v_child;
              END IF;
            END;
          END LOOP;
        END;
      END LOOP;
      IF v_all_sorted_count_dev < v_all_tables_dev.COUNT THEN
        DBMS_OUTPUT.PUT_LINE('Циклические зависимости в DEV: есть');
        DBMS_OUTPUT.PUT_LINE('Следующие таблицы участвуют в цикле:');
        FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
          IF v_all_dep_count_dev(v_all_tables_dev(i)) > 0 THEN
            DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables_dev(i));
          END IF;
        END LOOP;
      ELSE
        DBMS_OUTPUT.PUT_LINE('Циклические зависимости в DEV: нет');
      END IF;
    END;
  END;

 -- filepath: untitled:Untitled-21
DBMS_OUTPUT.PUT_LINE('Процедуры:');
FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Процедура есть в PROD, но отсутствует в DEV: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
    AND object_name IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
    )
) LOOP
  BEGIN
    v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
  EXCEPTION WHEN OTHERS THEN
    v_dev_ddl := 'NO DDL';
  END;
  BEGIN
    v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
  EXCEPTION WHEN OTHERS THEN
    v_prod_ddl := 'NO DDL';
  END;
  IF v_prod_ddl = 'NO DDL' THEN
    DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
  ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
    DBMS_OUTPUT.PUT_LINE('Процедура с различиями: ' || rec.object_name);
    DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
    DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
  END IF;
END LOOP;

DBMS_OUTPUT.PUT_LINE('Функции:');
FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Функция есть в PROD, но отсутствует в DEV: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
    AND object_name IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
    )
) LOOP
  BEGIN
    v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
  EXCEPTION WHEN OTHERS THEN
    v_dev_ddl := 'NO DDL';
  END;
  BEGIN
    v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
  EXCEPTION WHEN OTHERS THEN
    v_prod_ddl := 'NO DDL';
  END;
  IF v_prod_ddl = 'NO DDL' THEN
    DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
  ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
    DBMS_OUTPUT.PUT_LINE('Функция с различиями: ' || rec.object_name);
    DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
    DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
  END IF;
END LOOP;

  DBMS_OUTPUT.PUT_LINE('Пакеты:');
FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
    AND object_name NOT IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Пакет есть в PROD, но отсутствует в DEV: ' || rec.object_name);
END LOOP;

FOR rec IN (
  SELECT object_name 
  FROM all_objects
  WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
    AND object_name IN (
      SELECT object_name 
      FROM all_objects
      WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
    )
) LOOP
  BEGIN
    v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
  EXCEPTION WHEN OTHERS THEN
    v_dev_ddl := 'NO DDL';
  END;
  BEGIN
    v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
  EXCEPTION WHEN OTHERS THEN
    v_prod_ddl := 'NO DDL';
  END;
  IF v_prod_ddl = 'NO DDL' THEN
    DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
  ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
    DBMS_OUTPUT.PUT_LINE('Пакет с различиями: ' || rec.object_name);
    DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
    DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
  END IF;
END LOOP;

  DBMS_OUTPUT.PUT_LINE('Индексы:');
FOR rec IN (
  SELECT index_name 
  FROM all_indexes
  WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
    AND index_name NOT IN (
      SELECT index_name 
      FROM all_indexes
      WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
END LOOP;

FOR rec IN (
  SELECT index_name 
  FROM all_indexes
  WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
    AND index_name NOT IN (
      SELECT index_name 
      FROM all_indexes
      WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
    )
) LOOP
  DBMS_OUTPUT.PUT_LINE('Индекс есть в PROD, но отсутствует в DEV: ' || rec.index_name);
END LOOP;

FOR rec IN (
  SELECT index_name 
  FROM all_indexes
  WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
    AND index_name IN (
      SELECT index_name 
      FROM all_indexes
      WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
    )
) LOOP
  BEGIN
    v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
  EXCEPTION WHEN OTHERS THEN
    v_dev_ddl := 'NO DDL';
  END;
  BEGIN
    v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
  EXCEPTION WHEN OTHERS THEN
    v_prod_ddl := 'NO DDL';
  END;
  IF v_prod_ddl = 'NO DDL' THEN
    DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
  ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
    DBMS_OUTPUT.PUT_LINE('Индекс с различиями: ' || rec.index_name);
    DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
    DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
  END IF;
END LOOP;

  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', TRUE);
  DBMS_OUTPUT.PUT_LINE('Скрипт чтобы привести ' || p_prod_schema || ' к ' || p_dev_schema);
  FOR rec IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
  LOOP
    BEGIN
      v_dev_ddl := DBMS_METADATA.GET_DDL('TABLE', rec.table_name, UPPER(p_dev_schema));
    EXCEPTION WHEN OTHERS THEN
      v_dev_ddl := 'NO DDL';
    END;
    BEGIN
      v_prod_ddl := DBMS_METADATA.GET_DDL('TABLE', rec.table_name, UPPER(p_prod_schema));
    EXCEPTION WHEN OTHERS THEN
      v_prod_ddl := 'NO DDL';
    END;
    IF v_prod_ddl = 'NO DDL' THEN
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS;');
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    END IF;
  END LOOP;
  FOR rec IN (
    SELECT table_name FROM all_tables
    WHERE owner = UPPER(p_prod_schema)
      AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
  )
  LOOP
    DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS;');
  END LOOP;

  FOR rec IN (SELECT object_name FROM all_objects
              WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE')
  LOOP
    BEGIN
      v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
    EXCEPTION WHEN OTHERS THEN
      v_dev_ddl := 'NO DDL';
    END;
    BEGIN
      v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
    EXCEPTION WHEN OTHERS THEN
      v_prod_ddl := 'NO DDL';
    END;
    IF v_prod_ddl = 'NO DDL' THEN
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    END IF;
  END LOOP;
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
      AND object_name NOT IN (
        SELECT object_name FROM all_objects
        WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
      )
  )
  LOOP
    DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
  END LOOP;

  FOR rec IN (SELECT object_name FROM all_objects
              WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION')
  LOOP
    BEGIN
      v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
    EXCEPTION WHEN OTHERS THEN
      v_dev_ddl := 'NO DDL';
    END;
    BEGIN
      v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
    EXCEPTION WHEN OTHERS THEN
      v_prod_ddl := 'NO DDL';
    END;
    IF v_prod_ddl = 'NO DDL' THEN
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    END IF;
  END LOOP;
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
      AND object_name NOT IN (
        SELECT object_name FROM all_objects
        WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
      )
  )
  LOOP
    DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
  END LOOP;

  FOR rec IN (SELECT object_name FROM all_objects
              WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE')
  LOOP
    BEGIN
      v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
    EXCEPTION WHEN OTHERS THEN
      v_dev_ddl := 'NO DDL';
    END;
    BEGIN
      v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
    EXCEPTION WHEN OTHERS THEN
      v_prod_ddl := 'NO DDL';
    END;
    IF v_prod_ddl = 'NO DDL' THEN
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    END IF;
  END LOOP;
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
      AND object_name NOT IN (
        SELECT object_name FROM all_objects
        WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
      )
  )
  LOOP
    DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
  END LOOP;

  FOR rec IN (SELECT index_name FROM all_indexes
              WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%')
  LOOP
    BEGIN
      v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
    EXCEPTION WHEN OTHERS THEN
      v_dev_ddl := 'NO DDL';
    END;
    BEGIN
      v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
    EXCEPTION WHEN OTHERS THEN
      v_prod_ddl := 'NO DDL';
    END;
    IF v_prod_ddl = 'NO DDL' THEN
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
      DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
    END IF;
  END LOOP;
  FOR rec IN (
    SELECT index_name FROM all_indexes
    WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
      AND index_name NOT IN (
        SELECT index_name FROM all_indexes
        WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
      )
  )
  LOOP
    DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
  END LOOP;
END;

BEGIN
  Compare_Schemas('DEV_SCHEMA', 'PROD_SCHEMA');
END;




----------
-- CREATE OR REPLACE PROCEDURE Compare_Schemas(
--   p_dev_schema  IN VARCHAR2,
--   p_prod_schema IN VARCHAR2
-- )
--   AUTHID CURRENT_USER
-- AS
--   TYPE t_varchar_table IS TABLE OF VARCHAR2(128);
--   v_affected_tables t_varchar_table := t_varchar_table(); -- таблицы где есть проблемы(отличаются например отсутсвуют и тж)

--   TYPE t_issue_map IS TABLE OF VARCHAR2(10) INDEX BY VARCHAR2(128);
--   v_issue_map t_issue_map; -- маппинг типов проблем для каждой таблицы

--   TYPE t_dep_count_map IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--   v_dep_count t_dep_count_map;

--   TYPE t_children_map IS TABLE OF t_varchar_table INDEX BY VARCHAR2(128);
--   v_children t_children_map;

--   v_sorted         t_varchar_table := t_varchar_table();
--   v_sorted_count   PLS_INTEGER := 0;
--   v_count          NUMBER;
--   v_table_name     VARCHAR2(128);
--   v_cycles_found   BOOLEAN := FALSE;

--   v_dev_ddl        CLOB;
--   v_prod_ddl       CLOB;

--   FUNCTION normalize_ddl(p_ddl IN CLOB) RETURN CLOB IS
--     v_normalized CLOB;
--   BEGIN
--     v_normalized := p_ddl;
--     v_normalized := REPLACE(v_normalized, CHR(10), ' ');
--     v_normalized := REPLACE(v_normalized, CHR(13), ' ');
--     v_normalized := REGEXP_REPLACE(v_normalized, '\s+', ' ');
--     v_normalized := TRIM(v_normalized);
--     v_normalized := REGEXP_REPLACE(v_normalized, '"[^"]+"\.', '');
--     v_normalized := REGEXP_REPLACE(v_normalized, 'EDITIONABLE', '');
--     v_normalized := REGEXP_REPLACE(v_normalized, 'END\s+\w+;', 'END;');
--     RETURN v_normalized;
--   EXCEPTION
--     WHEN OTHERS THEN
--       RETURN p_ddl;
--   END normalize_ddl;

--   FUNCTION replace_schema(p_ddl IN CLOB) RETURN CLOB IS
--   BEGIN
--     RETURN REPLACE(p_ddl, '"' || UPPER(p_dev_schema) || '"', '"' || UPPER(p_prod_schema) || '"');
--   END replace_schema;

-- BEGIN
--   -- метаданные для упрощенного ичистого вывода DDL
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'OID', FALSE);

--   FOR rec IN (
--     SELECT dt.table_name,
--            CASE
--              WHEN pt.table_name IS NULL THEN 'MISSING'
--              WHEN (SELECT COUNT(*) FROM (
--                       SELECT column_name, data_type, data_length, nullable
--                       FROM all_tab_columns
--                       WHERE owner = UPPER(p_dev_schema)
--                         AND table_name = dt.table_name
--                       MINUS
--                       SELECT column_name, data_type, data_length, nullable
--                       FROM all_tab_columns
--                       WHERE owner = UPPER(p_prod_schema)
--                         AND table_name = dt.table_name
--                    )) > 0 THEN 'DIFF'
--            END AS issue
--     FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
--     LEFT JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
--       ON dt.table_name = pt.table_name
--     WHERE pt.table_name IS NULL OR
--           ((SELECT COUNT(*) FROM (
--               SELECT column_name, data_type, data_length, nullable
--               FROM all_tab_columns
--               WHERE owner = UPPER(p_dev_schema)
--                 AND table_name = dt.table_name
--               MINUS
--               SELECT column_name, data_type, data_length, nullable
--               FROM all_tab_columns
--               WHERE owner = UPPER(p_prod_schema)
--                 AND table_name = dt.table_name
--             )) > 0)
--   ) LOOP
--     v_affected_tables.EXTEND;
--     v_affected_tables(v_affected_tables.COUNT) := rec.table_name;
--     v_issue_map(rec.table_name) := rec.issue;
--   END LOOP;

--   FOR i IN 1 .. v_affected_tables.COUNT LOOP
--     v_dep_count(v_affected_tables(i)) := 0; -- счетчик зависимостей для таблиц
--     v_children(v_affected_tables(i)) := t_varchar_table(); -- для хранения дочерних объектов, зависимых таблиц 
--   END LOOP;
 
--   -- анализ зависимостей между таблицами
--   FOR i IN 1 .. v_affected_tables.COUNT LOOP
--     v_table_name := v_affected_tables(i);
--     SELECT COUNT(*) INTO v_count
--     FROM all_tables
--     WHERE owner = UPPER(p_prod_schema) -- check if table exists in schemas
--       AND table_name = v_table_name;
--     DECLARE
--       v_schema_for_fk VARCHAR2(30);
--     BEGIN
--       IF v_count > 0 THEN -- счетчик увеличивается если таблица найдена в проде
--         v_schema_for_fk := UPPER(p_prod_schema);
--       ELSE
--         v_schema_for_fk := UPPER(p_dev_schema);
--       END IF;
--       FOR fk_rec IN (
--         SELECT a.table_name AS child, c.table_name AS parent
--         FROM all_constraints a
--         JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--         WHERE a.constraint_type = 'R' -- referential проверяет чтобы была ссылачная связь между таблицами если внешний ключ есть
--           AND a.owner = v_schema_for_fk
--           AND a.table_name = v_table_name
--       ) LOOP
--         FOR j IN 1 .. v_affected_tables.COUNT LOOP
--           IF fk_rec.parent = v_affected_tables(j) THEN
--             v_dep_count(v_table_name) := v_dep_count(v_table_name) + 1; -- if found parent table in all of them
--             v_children(fk_rec.parent).EXTEND;
--             v_children(fk_rec.parent)(v_children(fk_rec.parent).COUNT) := v_table_name; -- add ref to parent table, that they are collacated
--           END IF;
--         END LOOP;
--       END LOOP;
--     END;
--   END LOOP;

--   DECLARE
--     TYPE t_queue IS TABLE OF VARCHAR2(128);
--     v_queue t_queue := t_queue();
--     v_queue_start PLS_INTEGER := 1;
--     v_queue_end   PLS_INTEGER := 0;
--   BEGIN
--     FOR i IN 1 .. v_affected_tables.COUNT LOOP -- first add tables without any deps in foreign relations. if v_dep_count(v_affected_tables(i)) = 0, store in queue
--       IF v_dep_count(v_affected_tables(i)) = 0 THEN
--         v_queue_end := v_queue_end + 1;
--         v_queue.EXTEND;
--         v_queue(v_queue_end) := v_affected_tables(i);
--       END IF;
--     END LOOP;
--     WHILE v_queue_start <= v_queue_end LOOP -- get child table from current and dec dep count. if v_dep_count(v_child) = 0 store in queue
--       DECLARE
--         v_current VARCHAR2(128);
--       BEGIN
--         v_current := v_queue(v_queue_start);
--         v_queue_start := v_queue_start + 1;
--         v_sorted_count := v_sorted_count + 1;
--         v_sorted.EXTEND;
--         v_sorted(v_sorted_count) := v_current;
--         FOR i IN 1 .. v_children(v_current).COUNT LOOP
--           DECLARE
--             v_child VARCHAR2(128) := v_children(v_current)(i);
--           BEGIN
--             v_dep_count(v_child) := v_dep_count(v_child) - 1;
--             IF v_dep_count(v_child) = 0 THEN
--               v_queue_end := v_queue_end + 1;
--               v_queue.EXTEND;
--               v_queue(v_queue_end) := v_child;
--             END IF;
--           END;
--         END LOOP;
--       END;
--     END LOOP;
--     IF v_sorted_count < v_affected_tables.COUNT THEN -- if count > 0, store in the end of sorted list. There are loop deps
--       FOR i IN 1 .. v_affected_tables.COUNT LOOP
--         IF v_dep_count(v_affected_tables(i)) > 0 THEN
--           v_sorted_count := v_sorted_count + 1;
--           v_sorted.EXTEND;
--           v_sorted(v_sorted_count) := v_affected_tables(i);
--         END IF;
--       END LOOP;
--     END IF;
--   END;

--   -- filepath: untitled:Untitled-21
-- FOR rec IN (
--   SELECT table_name 
--   FROM all_tables
--   WHERE owner = UPPER(p_dev_schema)
--     AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema))
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица есть в DEV, но отсутствует в PROD: ' || rec.table_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT table_name 
--   FROM all_tables
--   WHERE owner = UPPER(p_prod_schema)
--     AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица есть в PROD, но отсутствует в DEV: ' || rec.table_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT dt.table_name
--   FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
--   JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
--     ON dt.table_name = pt.table_name
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица с различиями: ' || rec.table_name);
--   FOR col_diff IN (
--     SELECT column_name, data_type, data_length, nullable
--     FROM (
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
--       MINUS
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
--     )
--     UNION ALL
--     SELECT column_name, data_type, data_length, nullable
--     FROM (
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
--       MINUS
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
--     )
--   ) LOOP
--     DBMS_OUTPUT.PUT_LINE('  Различие в колонке: ' || col_diff.column_name || 
--                          ' (Тип данных: ' || col_diff.data_type || 
--                          ', Длина: ' || col_diff.data_length || 
--                          ', Nullable: ' || col_diff.nullable || ')');
--   END LOOP;
-- END LOOP;

--   DECLARE
--     TYPE t_varchar_table_all IS TABLE OF VARCHAR2(128);
--     v_all_tables_prod t_varchar_table_all := t_varchar_table_all();
--     TYPE t_dep_count_map_all IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--     v_all_dep_count_prod t_dep_count_map_all;
--     TYPE t_children_map_all IS TABLE OF t_varchar_table_all INDEX BY VARCHAR2(128);
--     v_all_children_prod t_children_map_all;
--     v_all_sorted_count_prod PLS_INTEGER := 0;
--   BEGIN
--     FOR rec IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) LOOP
--       v_all_tables_prod.EXTEND;
--       v_all_tables_prod(v_all_tables_prod.COUNT) := rec.table_name;
--       v_all_dep_count_prod(rec.table_name) := 0;
--       v_all_children_prod(rec.table_name) := t_varchar_table_all();
--     END LOOP;
--     FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
--       FOR fk_rec IN (
--         SELECT a.table_name AS child, c.table_name AS parent
--         FROM all_constraints a
--         JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--         WHERE a.constraint_type = 'R'
--           AND a.owner = UPPER(p_prod_schema)
--           AND a.table_name = v_all_tables_prod(i)
--       ) LOOP
--         FOR j IN 1 .. v_all_tables_prod.COUNT LOOP
--           IF fk_rec.parent = v_all_tables_prod(j) THEN
--             v_all_dep_count_prod(v_all_tables_prod(i)) :=
--               v_all_dep_count_prod(v_all_tables_prod(i)) + 1;
--             v_all_children_prod(fk_rec.parent).EXTEND;
--             v_all_children_prod(fk_rec.parent)(v_all_children_prod(fk_rec.parent).COUNT) :=
--               v_all_tables_prod(i);
--           END IF;
--         END LOOP;
--       END LOOP;
--     END LOOP;
--     DECLARE
--       TYPE t_queue_all IS TABLE OF VARCHAR2(128);
--       v_queue_all t_queue_all := t_queue_all();
--       v_queue_all_start PLS_INTEGER := 1;
--       v_queue_all_end   PLS_INTEGER := 0;
--     BEGIN
--       FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
--         IF v_all_dep_count_prod(v_all_tables_prod(i)) = 0 THEN
--           v_queue_all_end := v_queue_all_end + 1;
--           v_queue_all.EXTEND;
--           v_queue_all(v_queue_all_end) := v_all_tables_prod(i);
--         END IF;
--       END LOOP;
--       WHILE v_queue_all_start <= v_queue_all_end LOOP
--         DECLARE
--           v_current VARCHAR2(128);
--         BEGIN
--           v_current := v_queue_all(v_queue_all_start);
--           v_queue_all_start := v_queue_all_start + 1;
--           v_all_sorted_count_prod := v_all_sorted_count_prod + 1;
--           FOR i IN 1 .. v_all_children_prod(v_current).COUNT LOOP
--             DECLARE
--               v_child VARCHAR2(128) := v_all_children_prod(v_current)(i);
--             BEGIN
--               v_all_dep_count_prod(v_child) := v_all_dep_count_prod(v_child) - 1;
--               IF v_all_dep_count_prod(v_child) = 0 THEN
--                 v_queue_all_end := v_queue_all_end + 1;
--                 v_queue_all.EXTEND;
--                 v_queue_all(v_queue_all_end) := v_child;
--               END IF;
--             END;
--           END LOOP;
--         END;
--       END LOOP;
--       IF v_all_sorted_count_prod < v_all_tables_prod.COUNT THEN
--       DBMS_OUTPUT.PUT_LINE('Циклические зависимости в PROD: есть');
--       DBMS_OUTPUT.PUT_LINE('Следующие таблицы участвуют в цикле:');
--         FOR i IN 1 .. v_all_tables_prod.COUNT LOOP
--           IF v_all_dep_count_prod(v_all_tables_prod(i)) > 0 THEN
--             DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables_prod(i));
--           END IF;
--         END LOOP;
--       ELSE
--         DBMS_OUTPUT.PUT_LINE('Циклические зависимости в PROD: нет');
--       END IF;
--     END;
--   END;

--   DECLARE
--     TYPE t_varchar_table_all IS TABLE OF VARCHAR2(128);
--     v_all_tables_dev t_varchar_table_all := t_varchar_table_all();
--     TYPE t_dep_count_map_all IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--     v_all_dep_count_dev t_dep_count_map_all;
--     TYPE t_children_map_all IS TABLE OF t_varchar_table_all INDEX BY VARCHAR2(128);
--     v_all_children_dev t_children_map_all;
--     v_all_sorted_count_dev PLS_INTEGER := 0;
--   BEGIN
--     FOR rec IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) LOOP
--       v_all_tables_dev.EXTEND;
--       v_all_tables_dev(v_all_tables_dev.COUNT) := rec.table_name;
--       v_all_dep_count_dev(rec.table_name) := 0;
--       v_all_children_dev(rec.table_name) := t_varchar_table_all();
--     END LOOP;
--     FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
--       FOR fk_rec IN (
--         SELECT a.table_name AS child, c.table_name AS parent
--         FROM all_constraints a
--         JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--         WHERE a.constraint_type = 'R'
--           AND a.owner = UPPER(p_dev_schema)
--           AND a.table_name = v_all_tables_dev(i)
--       ) LOOP
--         FOR j IN 1 .. v_all_tables_dev.COUNT LOOP
--           IF fk_rec.parent = v_all_tables_dev(j) THEN
--             v_all_dep_count_dev(v_all_tables_dev(i)) :=
--               v_all_dep_count_dev(v_all_tables_dev(i)) + 1;
--             v_all_children_dev(fk_rec.parent).EXTEND;
--             v_all_children_dev(fk_rec.parent)(v_all_children_dev(fk_rec.parent).COUNT) :=
--               v_all_tables_dev(i);
--           END IF;
--         END LOOP;
--       END LOOP;
--     END LOOP;
--     DECLARE
--       TYPE t_queue_all IS TABLE OF VARCHAR2(128);
--       v_queue_all t_queue_all := t_queue_all();
--       v_queue_all_start PLS_INTEGER := 1;
--       v_queue_all_end   PLS_INTEGER := 0;
--     BEGIN
--       FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
--         IF v_all_dep_count_dev(v_all_tables_dev(i)) = 0 THEN
--           v_queue_all_end := v_queue_all_end + 1;
--           v_queue_all.EXTEND;
--           v_queue_all(v_queue_all_end) := v_all_tables_dev(i);
--         END IF;
--       END LOOP;
--       WHILE v_queue_all_start <= v_queue_all_end LOOP
--         DECLARE
--           v_current VARCHAR2(128);
--         BEGIN
--           v_current := v_queue_all(v_queue_all_start);
--           v_queue_all_start := v_queue_all_start + 1;
--           v_all_sorted_count_dev := v_all_sorted_count_dev + 1;
--           FOR i IN 1 .. v_all_children_dev(v_current).COUNT LOOP
--             DECLARE
--               v_child VARCHAR2(128) := v_all_children_dev(v_current)(i);
--             BEGIN
--               v_all_dep_count_dev(v_child) := v_all_dep_count_dev(v_child) - 1;
--               IF v_all_dep_count_dev(v_child) = 0 THEN
--                 v_queue_all_end := v_queue_all_end + 1;
--                 v_queue_all.EXTEND;
--                 v_queue_all(v_queue_all_end) := v_child;
--               END IF;
--             END;
--              END LOOP;
--         END;
--       END LOOP;
--       IF v_all_sorted_count_dev < v_all_tables_dev.COUNT THEN
--         DBMS_OUTPUT.PUT_LINE('Циклические зависимости в DEV: есть');
--         DBMS_OUTPUT.PUT_LINE('Следующие таблицы участвуют в цикле:');
--         FOR i IN 1 .. v_all_tables_dev.COUNT LOOP
--           IF v_all_dep_count_dev(v_all_tables_dev(i)) > 0 THEN
--             DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables_dev(i));
--           END IF;
--         END LOOP;
--       ELSE
--         DBMS_OUTPUT.PUT_LINE('Циклические зависимости в DEV: нет');
--       END IF;
--     END;
--   END;

-- DBMS_OUTPUT.PUT_LINE('Процедуры:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Процедура есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Процедура с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

-- DBMS_OUTPUT.PUT_LINE('Функции:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Функция есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Функция с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

--   DBMS_OUTPUT.PUT_LINE('Пакеты:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Пакет есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Пакет с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

--   DBMS_OUTPUT.PUT_LINE('Индексы:');
-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name NOT IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name NOT IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Индекс есть в PROD, но отсутствует в DEV: ' || rec.index_name);
-- END LOOP;
-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Индекс с различиями: ' || rec.index_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;


--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', TRUE);
--   DBMS_OUTPUT.PUT_LINE('Скрипт чтобы привести ' || p_prod_schema || ' к ' || p_dev_schema);
--   FOR i IN 1 .. v_sorted.COUNT LOOP
--     DECLARE
--       v_dev_ddl CLOB;
--       v_prod_ddl CLOB;
--     BEGIN
--       BEGIN
--         v_dev_ddl := DBMS_METADATA.GET_DDL('TABLE', v_sorted(i), UPPER(p_dev_schema));
--       EXCEPTION WHEN OTHERS THEN
--         v_dev_ddl := 'NO DDL';
--       END;
--       BEGIN
--         v_prod_ddl := DBMS_METADATA.GET_DDL('TABLE', v_sorted(i), UPPER(p_prod_schema));
--       EXCEPTION WHEN OTHERS THEN
--         v_prod_ddl := 'NO DDL';
--       END;
--       IF v_prod_ddl = 'NO DDL' THEN
--         DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--       ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--         DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || v_sorted(i) || ' CASCADE CONSTRAINTS;');
--         DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--       END IF;
--     END;
--   END LOOP;
--   FOR rec IN (
--     SELECT table_name FROM all_tables
--     WHERE owner = UPPER(p_prod_schema)
--       AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS;');
--   END LOOP;

--   FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
--   END LOOP;
--    FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
--   END LOOP;

--   FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
--   END LOOP;

--   FOR rec IN (SELECT index_name FROM all_indexes
--               WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT index_name FROM all_indexes
--     WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--       AND index_name NOT IN (
--         SELECT index_name FROM all_indexes
--         WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
--   END LOOP;
-- END;

-- BEGIN
--   Compare_Schemas('DEV_SCHEMA', 'PROD_SCHEMA');
-- END;


-- new
-- CREATE OR REPLACE PROCEDURE Compare_Schemas(
--   p_dev_schema  IN VARCHAR2,
--   p_prod_schema IN VARCHAR2
-- )
--   AUTHID CURRENT_USER
-- AS
--   TYPE t_varchar_table IS TABLE OF VARCHAR2(128);
--   v_affected_tables t_varchar_table := t_varchar_table(); -- таблицы где есть проблемы(отличаются например отсутсвуют и тж)

--   TYPE t_issue_map IS TABLE OF VARCHAR2(10) INDEX BY VARCHAR2(128);
--   v_issue_map t_issue_map; -- маппинг типов проблем для каждой таблицы

--   TYPE t_dep_count_map IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--   v_dep_count t_dep_count_map;

--   TYPE t_children_map IS TABLE OF t_varchar_table INDEX BY VARCHAR2(128);
--   v_children t_children_map;

--   v_sorted         t_varchar_table := t_varchar_table();
--   v_sorted_count   PLS_INTEGER := 0;
--   v_count          NUMBER;
--   v_table_name     VARCHAR2(128);
--   v_cycles_found   BOOLEAN := FALSE;

--   v_dev_ddl        CLOB;
--   v_prod_ddl       CLOB;

--   FUNCTION normalize_ddl(p_ddl IN CLOB) RETURN CLOB IS
--     v_normalized CLOB;
--   BEGIN
--     v_normalized := p_ddl;
--     v_normalized := REPLACE(v_normalized, CHR(10), ' ');
--     v_normalized := REPLACE(v_normalized, CHR(13), ' ');
--     v_normalized := REGEXP_REPLACE(v_normalized, '\s+', ' ');
--     v_normalized := TRIM(v_normalized);
--     v_normalized := REGEXP_REPLACE(v_normalized, '"[^"]+"\.', '');
--     v_normalized := REGEXP_REPLACE(v_normalized, 'EDITIONABLE', '');
--     v_normalized := REGEXP_REPLACE(v_normalized, 'END\s+\w+;', 'END;');
--     RETURN v_normalized;
--   EXCEPTION
--     WHEN OTHERS THEN
--       RETURN p_ddl;
--   END normalize_ddl;

--   FUNCTION replace_schema(p_ddl IN CLOB) RETURN CLOB IS
--   BEGIN
--     RETURN REPLACE(p_ddl, '"' || UPPER(p_dev_schema) || '"', '"' || UPPER(p_prod_schema) || '"');
--   END replace_schema;

-- BEGIN
--   -- метаданные для упрощенного ичистого вывода DDL
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', FALSE);
--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'OID', FALSE);

--   FOR rec IN (
--     SELECT dt.table_name,
--            CASE
--              WHEN pt.table_name IS NULL THEN 'MISSING'
--              WHEN (SELECT COUNT(*) FROM (
--                       SELECT column_name, data_type, data_length, nullable
--                       FROM all_tab_columns
--                       WHERE owner = UPPER(p_dev_schema)
--                         AND table_name = dt.table_name
--                       MINUS
--                       SELECT column_name, data_type, data_length, nullable
--                       FROM all_tab_columns
--                       WHERE owner = UPPER(p_prod_schema)
--                         AND table_name = dt.table_name
--                    )) > 0 THEN 'DIFF'
--            END AS issue
--     FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
--     LEFT JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
--       ON dt.table_name = pt.table_name
--     WHERE pt.table_name IS NULL OR
--           ((SELECT COUNT(*) FROM (
--               SELECT column_name, data_type, data_length, nullable
--               FROM all_tab_columns
--               WHERE owner = UPPER(p_dev_schema)
--                 AND table_name = dt.table_name
--               MINUS
--               SELECT column_name, data_type, data_length, nullable
--               FROM all_tab_columns
--               WHERE owner = UPPER(p_prod_schema)
--                 AND table_name = dt.table_name
--             )) > 0)
--   ) LOOP
--     v_affected_tables.EXTEND;
--     v_affected_tables(v_affected_tables.COUNT) := rec.table_name;
--     v_issue_map(rec.table_name) := rec.issue;
--   END LOOP;

--   FOR i IN 1 .. v_affected_tables.COUNT LOOP
--     v_dep_count(v_affected_tables(i)) := 0; -- счетчик зависимостей для таблиц
--     v_children(v_affected_tables(i)) := t_varchar_table(); -- для хранения дочерних объектов, зависимых таблиц 
--   END LOOP;
 
--   -- анализ зависимостей между таблицами
--   FOR i IN 1 .. v_affected_tables.COUNT LOOP
--     v_table_name := v_affected_tables(i);
--     SELECT COUNT(*) INTO v_count
--     FROM all_tables
--     WHERE owner = UPPER(p_prod_schema) -- check if table exists in schemas
--       AND table_name = v_table_name;
--     DECLARE
--       v_schema_for_fk VARCHAR2(30);
--     BEGIN
--       IF v_count > 0 THEN -- счетчик увеличивается если таблица найдена в проде
--         v_schema_for_fk := UPPER(p_prod_schema);
--       ELSE
--         v_schema_for_fk := UPPER(p_dev_schema);
--       END IF;
--       FOR fk_rec IN (
--         SELECT a.table_name AS child, c.table_name AS parent
--         FROM all_constraints a
--         JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--         WHERE a.constraint_type = 'R' -- referential проверяет чтобы была ссылачная связь между таблицами если внешний ключ есть
--           AND a.owner = v_schema_for_fk
--           AND a.table_name = v_table_name
--       ) LOOP
--         FOR j IN 1 .. v_affected_tables.COUNT LOOP
--           IF fk_rec.parent = v_affected_tables(j) THEN
--             v_dep_count(v_table_name) := v_dep_count(v_table_name) + 1; -- if found parent table in all of them
--             v_children(fk_rec.parent).EXTEND;
--             v_children(fk_rec.parent)(v_children(fk_rec.parent).COUNT) := v_table_name; -- add ref to parent table, that they are collacated
--           END IF;
--         END LOOP;
--       END LOOP;
--     END;
--   END LOOP;

--   DECLARE
--     TYPE t_queue IS TABLE OF VARCHAR2(128);
--     v_queue t_queue := t_queue();
--     v_queue_start PLS_INTEGER := 1;
--     v_queue_end   PLS_INTEGER := 0;
--   BEGIN
--     FOR i IN 1 .. v_affected_tables.COUNT LOOP -- first add tables without any deps in foreign relations. if v_dep_count(v_affected_tables(i)) = 0, store in queue
--       IF v_dep_count(v_affected_tables(i)) = 0 THEN
--         v_queue_end := v_queue_end + 1;
--         v_queue.EXTEND;
--         v_queue(v_queue_end) := v_affected_tables(i);
--       END IF;
--     END LOOP;
--     WHILE v_queue_start <= v_queue_end LOOP -- get child table from current and dec dep count. if v_dep_count(v_child) = 0 store in queue
--       DECLARE
--         v_current VARCHAR2(128);
--       BEGIN
--         v_current := v_queue(v_queue_start);
--         v_queue_start := v_queue_start + 1;
--         v_sorted_count := v_sorted_count + 1;
--         v_sorted.EXTEND;
--         v_sorted(v_sorted_count) := v_current;
--         FOR i IN 1 .. v_children(v_current).COUNT LOOP
--           DECLARE
--             v_child VARCHAR2(128) := v_children(v_current)(i);
--           BEGIN
--             v_dep_count(v_child) := v_dep_count(v_child) - 1;
--             IF v_dep_count(v_child) = 0 THEN
--               v_queue_end := v_queue_end + 1;
--               v_queue.EXTEND;
--               v_queue(v_queue_end) := v_child;
--             END IF;
--           END;
--         END LOOP;
--       END;
--     END LOOP;
--     IF v_sorted_count < v_affected_tables.COUNT THEN -- if count > 0, store in the end of sorted list. There are loop deps
--       FOR i IN 1 .. v_affected_tables.COUNT LOOP
--         IF v_dep_count(v_affected_tables(i)) > 0 THEN
--           v_sorted_count := v_sorted_count + 1;
--           v_sorted.EXTEND;
--           v_sorted(v_sorted_count) := v_affected_tables(i);
--         END IF;
--       END LOOP;
--     END IF;
--   END;

--   -- filepath: untitled:Untitled-21
-- FOR rec IN (
--   SELECT table_name 
--   FROM all_tables
--   WHERE owner = UPPER(p_dev_schema)
--     AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema))
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица есть в DEV, но отсутствует в PROD: ' || rec.table_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT table_name 
--   FROM all_tables
--   WHERE owner = UPPER(p_prod_schema)
--     AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица есть в PROD, но отсутствует в DEV: ' || rec.table_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT dt.table_name
--   FROM (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema)) dt
--   JOIN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_prod_schema)) pt
--     ON dt.table_name = pt.table_name
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Таблица с различиями: ' || rec.table_name);
--   FOR col_diff IN (
--     SELECT column_name, data_type, data_length, nullable
--     FROM (
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
--       MINUS
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
--     )
--     UNION ALL
--     SELECT column_name, data_type, data_length, nullable
--     FROM (
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_prod_schema) AND table_name = rec.table_name
--       MINUS
--       SELECT column_name, data_type, data_length, nullable
--       FROM all_tab_columns
--       WHERE owner = UPPER(p_dev_schema) AND table_name = rec.table_name
--     )
--   ) LOOP
--     DBMS_OUTPUT.PUT_LINE('  Различие в колонке: ' || col_diff.column_name || 
--                          ' (Тип данных: ' || col_diff.data_type || 
--                          ', Длина: ' || col_diff.data_length || 
--                          ', Nullable: ' || col_diff.nullable || ')');
--   END LOOP;
-- END LOOP;

--   DECLARE
--   TYPE t_varchar_table IS TABLE OF VARCHAR2(128);
--   v_all_tables        t_varchar_table := t_varchar_table();
--   v_has_deps          t_varchar_table := t_varchar_table();
--   v_cycle_tables      t_varchar_table := t_varchar_table();

--   TYPE t_dep_count IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--   v_dep_count         t_dep_count;

--   TYPE t_children IS TABLE OF t_varchar_table INDEX BY VARCHAR2(128);
--   v_children          t_children;

--   v_sorted_count      PLS_INTEGER := 0;
--   p_schema            VARCHAR2(30) := UPPER(p_prod_schema);
-- BEGIN
--   -- 1. Собираем все таблицы схемы
--   FOR rec IN (SELECT table_name FROM all_tables WHERE owner = p_schema) LOOP
--     v_all_tables.EXTEND;
--     v_all_tables(v_all_tables.COUNT) := rec.table_name;
--     v_dep_count(rec.table_name) := 0;
--     v_children(rec.table_name) := t_varchar_table();
--   END LOOP;

--   -- 2. Строим граф зависимостей
--   FOR i IN 1 .. v_all_tables.COUNT LOOP
--     FOR fk IN (
--       SELECT a.table_name AS child, c.table_name AS parent
--       FROM all_constraints a
--       JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--       WHERE a.constraint_type = 'R'
--         AND a.owner = p_schema
--         AND a.table_name = v_all_tables(i)
--     ) LOOP
--       FOR j IN 1 .. v_all_tables.COUNT LOOP
--         IF fk.parent = v_all_tables(j) THEN
--           v_dep_count(v_all_tables(i)) := v_dep_count(v_all_tables(i)) + 1;
--           v_children(fk.parent).EXTEND;
--           v_children(fk.parent)(v_children(fk.parent).COUNT) := v_all_tables(i);
--         END IF;
--       END LOOP;

--       -- Отмечаем, что у таблицы есть зависимости
--       v_has_deps.EXTEND;
--       v_has_deps(v_has_deps.COUNT) := v_all_tables(i);
--     END LOOP;
--   END LOOP;

--   -- 3. Топологическая сортировка
--   DECLARE
--     TYPE t_queue IS TABLE OF VARCHAR2(128);
--     v_queue t_queue := t_queue();
--     v_start PLS_INTEGER := 1;
--     v_end   PLS_INTEGER := 0;
--   BEGIN
--     FOR i IN 1 .. v_all_tables.COUNT LOOP
--       IF v_dep_count(v_all_tables(i)) = 0 THEN
--         v_end := v_end + 1;
--         v_queue.EXTEND;
--         v_queue(v_end) := v_all_tables(i);
--       END IF;
--     END LOOP;

--     WHILE v_start <= v_end LOOP
--       DECLARE
--         v_current VARCHAR2(128);
--       BEGIN
--         v_current := v_queue(v_start);
--         v_start := v_start + 1;
--         v_sorted_count := v_sorted_count + 1;

--         FOR i IN 1 .. v_children(v_current).COUNT LOOP
--           DECLARE
--             v_child VARCHAR2(128) := v_children(v_current)(i);
--           BEGIN
--             v_dep_count(v_child) := v_dep_count(v_child) - 1;
--             IF v_dep_count(v_child) = 0 THEN
--               v_end := v_end + 1;
--               v_queue.EXTEND;
--               v_queue(v_end) := v_child;
--             END IF;
--           END;
--         END LOOP;
--       END;
--     END LOOP;

--     -- 4. Выводим результат
--     DBMS_OUTPUT.PUT_LINE(CHR(10) || '📌 Таблицы с внешними ключами:');
--     FOR i IN 1 .. v_has_deps.COUNT LOOP
--       DBMS_OUTPUT.PUT_LINE('- ' || v_has_deps(i));
--     END LOOP;

--     IF v_sorted_count < v_all_tables.COUNT THEN
--       DBMS_OUTPUT.PUT_LINE(CHR(10) || '❌ Циклические зависимости найдены. Таблицы, участвующие в цикле:');
--       FOR i IN 1 .. v_all_tables.COUNT LOOP
--         IF v_dep_count(v_all_tables(i)) > 0 THEN
--           v_cycle_tables.EXTEND;
--           v_cycle_tables(v_cycle_tables.COUNT) := v_all_tables(i);
--           DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables(i));
--         END IF;
--       END LOOP;
--     ELSE
--       DBMS_OUTPUT.PUT_LINE(CHR(10) || '✅ Циклических зависимостей не обнаружено.');
--     END IF;
--   END;
-- END;


-- DECLARE
--   TYPE t_varchar_table IS TABLE OF VARCHAR2(128);
--   v_all_tables        t_varchar_table := t_varchar_table();
--   v_has_deps          t_varchar_table := t_varchar_table();
--   v_cycle_tables      t_varchar_table := t_varchar_table();

--   TYPE t_dep_count IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
--   v_dep_count         t_dep_count;

--   TYPE t_children IS TABLE OF t_varchar_table INDEX BY VARCHAR2(128);
--   v_children          t_children;

--   v_sorted_count      PLS_INTEGER := 0;
--   p_schema            VARCHAR2(30) := UPPER(p_dev_schema);
-- BEGIN
--   -- 1. Собираем все таблицы схемы
--   FOR rec IN (SELECT table_name FROM all_tables WHERE owner = p_schema) LOOP
--     v_all_tables.EXTEND;
--     v_all_tables(v_all_tables.COUNT) := rec.table_name;
--     v_dep_count(rec.table_name) := 0;
--     v_children(rec.table_name) := t_varchar_table();
--   END LOOP;

--   -- 2. Строим граф зависимостей
--   FOR i IN 1 .. v_all_tables.COUNT LOOP
--     FOR fk IN (
--       SELECT a.table_name AS child, c.table_name AS parent
--       FROM all_constraints a
--       JOIN all_constraints c ON a.r_constraint_name = c.constraint_name AND a.owner = c.owner
--       WHERE a.constraint_type = 'R'
--         AND a.owner = p_schema
--         AND a.table_name = v_all_tables(i)
--     ) LOOP
--       FOR j IN 1 .. v_all_tables.COUNT LOOP
--         IF fk.parent = v_all_tables(j) THEN
--           v_dep_count(v_all_tables(i)) := v_dep_count(v_all_tables(i)) + 1;
--           v_children(fk.parent).EXTEND;
--           v_children(fk.parent)(v_children(fk.parent).COUNT) := v_all_tables(i);

--           -- Запоминаем, что таблица имеет зависимости
--           v_has_deps.EXTEND;
--           v_has_deps(v_has_deps.COUNT) := v_all_tables(i);
--         END IF;
--       END LOOP;
--     END LOOP;
--   END LOOP;

--   -- 3. Топологическая сортировка
--   DECLARE
--     TYPE t_queue IS TABLE OF VARCHAR2(128);
--     v_queue t_queue := t_queue();
--     v_start PLS_INTEGER := 1;
--     v_end   PLS_INTEGER := 0;
--   BEGIN
--     FOR i IN 1 .. v_all_tables.COUNT LOOP
--       IF v_dep_count(v_all_tables(i)) = 0 THEN
--         v_end := v_end + 1;
--         v_queue.EXTEND;
--         v_queue(v_end) := v_all_tables(i);
--       END IF;
--     END LOOP;

--     WHILE v_start <= v_end LOOP
--       DECLARE
--         v_current VARCHAR2(128);
--       BEGIN
--         v_current := v_queue(v_start);
--         v_start := v_start + 1;
--         v_sorted_count := v_sorted_count + 1;

--         FOR i IN 1 .. v_children(v_current).COUNT LOOP
--           DECLARE
--             v_child VARCHAR2(128) := v_children(v_current)(i);
--           BEGIN
--             v_dep_count(v_child) := v_dep_count(v_child) - 1;
--             IF v_dep_count(v_child) = 0 THEN
--               v_end := v_end + 1;
--               v_queue.EXTEND;
--               v_queue(v_end) := v_child;
--             END IF;
--           END;
--         END LOOP;
--       END;
--     END LOOP;

--     -- 4. Вывод
--     DBMS_OUTPUT.PUT_LINE(CHR(10) || '📌 Таблицы с внешними ключами:');
--     FOR i IN 1 .. v_has_deps.COUNT LOOP
--       DBMS_OUTPUT.PUT_LINE('- ' || v_has_deps(i));
--     END LOOP;

--     IF v_sorted_count < v_all_tables.COUNT THEN
--       DBMS_OUTPUT.PUT_LINE(CHR(10) || '❌ Циклические зависимости в DEV: есть');
--       DBMS_OUTPUT.PUT_LINE('Следующие таблицы участвуют в цикле:');
--       FOR i IN 1 .. v_all_tables.COUNT LOOP
--         IF v_dep_count(v_all_tables(i)) > 0 THEN
--           v_cycle_tables.EXTEND;
--           v_cycle_tables(v_cycle_tables.COUNT) := v_all_tables(i);
--           DBMS_OUTPUT.PUT_LINE('- ' || v_all_tables(i));
--         END IF;
--       END LOOP;
--     ELSE
--       DBMS_OUTPUT.PUT_LINE(CHR(10) || '✅ Циклических зависимостей в DEV не обнаружено.');
--     END IF;
--   END;
-- END;


-- DBMS_OUTPUT.PUT_LINE('Процедуры:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Процедура есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Процедура есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Процедура с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

-- DBMS_OUTPUT.PUT_LINE('Функции:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Функция есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Функция есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Функция с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

--   DBMS_OUTPUT.PUT_LINE('Пакеты:');
-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     AND object_name NOT IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Пакет есть в PROD, но отсутствует в DEV: ' || rec.object_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT object_name 
--   FROM all_objects
--   WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--     AND object_name IN (
--       SELECT object_name 
--       FROM all_objects
--       WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Пакет есть в DEV, но отсутствует в PROD: ' || rec.object_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Пакет с различиями: ' || rec.object_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;

--   DBMS_OUTPUT.PUT_LINE('Индексы:');
-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name NOT IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
-- END LOOP;

-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name NOT IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   DBMS_OUTPUT.PUT_LINE('Индекс есть в PROD, но отсутствует в DEV: ' || rec.index_name);
-- END LOOP;
-- FOR rec IN (
--   SELECT index_name 
--   FROM all_indexes
--   WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--     AND index_name IN (
--       SELECT index_name 
--       FROM all_indexes
--       WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--     )
-- ) LOOP
--   BEGIN
--     v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_dev_ddl := 'NO DDL';
--   END;
--   BEGIN
--     v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
--   EXCEPTION WHEN OTHERS THEN
--     v_prod_ddl := 'NO DDL';
--   END;
--   IF v_prod_ddl = 'NO DDL' THEN
--     DBMS_OUTPUT.PUT_LINE('Индекс есть в DEV, но отсутствует в PROD: ' || rec.index_name);
--   ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--     DBMS_OUTPUT.PUT_LINE('Индекс с различиями: ' || rec.index_name);
--     DBMS_OUTPUT.PUT_LINE('  DDL в DEV: ' || SUBSTR(v_dev_ddl, 1, 4000));
--     DBMS_OUTPUT.PUT_LINE('  DDL в PROD: ' || SUBSTR(v_prod_ddl, 1, 4000));
--   END IF;
-- END LOOP;


--   DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', TRUE);
--   DBMS_OUTPUT.PUT_LINE('Скрипт чтобы привести ' || p_prod_schema || ' к ' || p_dev_schema);
--   FOR i IN 1 .. v_sorted.COUNT LOOP
--     DECLARE
--       v_dev_ddl CLOB;
--       v_prod_ddl CLOB;
--     BEGIN
--       BEGIN
--         v_dev_ddl := DBMS_METADATA.GET_DDL('TABLE', v_sorted(i), UPPER(p_dev_schema));
--       EXCEPTION WHEN OTHERS THEN
--         v_dev_ddl := 'NO DDL';
--       END;
--       BEGIN
--         v_prod_ddl := DBMS_METADATA.GET_DDL('TABLE', v_sorted(i), UPPER(p_prod_schema));
--       EXCEPTION WHEN OTHERS THEN
--         v_prod_ddl := 'NO DDL';
--       END;
--       IF v_prod_ddl = 'NO DDL' THEN
--         DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--       ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--         DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || v_sorted(i) || ' CASCADE CONSTRAINTS;');
--         DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--       END IF;
--     END;
--   END LOOP;
--   FOR rec IN (
--     SELECT table_name FROM all_tables
--     WHERE owner = UPPER(p_prod_schema)
--       AND table_name NOT IN (SELECT table_name FROM all_tables WHERE owner = UPPER(p_dev_schema))
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS;');
--   END LOOP;

--   FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('PROCEDURE', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'PROCEDURE'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP PROCEDURE ' || rec.object_name || ';');
--   END LOOP;
--    FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('FUNCTION', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'FUNCTION'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP FUNCTION ' || rec.object_name || ';');
--   END LOOP;

--   FOR rec IN (SELECT object_name FROM all_objects
--               WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('PACKAGE', rec.object_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT object_name FROM all_objects
--     WHERE owner = UPPER(p_prod_schema) AND object_type = 'PACKAGE'
--       AND object_name NOT IN (
--         SELECT object_name FROM all_objects
--         WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP PACKAGE ' || rec.object_name || ';');
--   END LOOP;

--   FOR rec IN (SELECT index_name FROM all_indexes
--               WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%')
--   LOOP
--     BEGIN
--       v_dev_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_dev_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_dev_ddl := 'NO DDL';
--     END;
--     BEGIN
--       v_prod_ddl := DBMS_METADATA.GET_DDL('INDEX', rec.index_name, UPPER(p_prod_schema));
--     EXCEPTION WHEN OTHERS THEN
--       v_prod_ddl := 'NO DDL';
--     END;
--     IF v_prod_ddl = 'NO DDL' THEN
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     ELSIF normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
--       DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
--       DBMS_OUTPUT.PUT_LINE(replace_schema(v_dev_ddl) || ';');
--     END IF;
--   END LOOP;
--   FOR rec IN (
--     SELECT index_name FROM all_indexes
--     WHERE owner = UPPER(p_prod_schema) AND index_name NOT LIKE 'SYS_%'
--       AND index_name NOT IN (
--         SELECT index_name FROM all_indexes
--         WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
--       )
--   )
--   LOOP
--     DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || rec.index_name || ';');
--   END LOOP;
-- END;

-- BEGIN
--   Compare_Schemas('DEV_SCHEMA', 'PROD_SCHEMA');
-- END;


