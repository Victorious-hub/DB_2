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

  DBMS_OUTPUT.PUT_LINE('Перечень таблиц (либо отсутствуют в PROD, либо отличаются по структуре),');
  DBMS_OUTPUT.PUT_LINE('отсортированные по порядку создания:');
  FOR i IN 1 .. v_sorted_count LOOP
    DBMS_OUTPUT.PUT_LINE('  ' || v_sorted(i));
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
      ELSE
        DBMS_OUTPUT.PUT_LINE('Циклические зависимости в DEV: нет');
      END IF;
    END;
  END;

  DBMS_OUTPUT.PUT_LINE('Процедуры:');
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_dev_schema) AND object_type = 'PROCEDURE'
    ORDER BY object_name
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
    IF v_prod_ddl = 'NO DDL' OR normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('  ' || rec.object_name);
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Функции:');
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_dev_schema) AND object_type = 'FUNCTION'
    ORDER BY object_name
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
    IF v_prod_ddl = 'NO DDL' OR normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('  ' || rec.object_name);
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Пакеты:');
  FOR rec IN (
    SELECT object_name FROM all_objects
    WHERE owner = UPPER(p_dev_schema) AND object_type = 'PACKAGE'
    ORDER BY object_name
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
    IF v_prod_ddl = 'NO DDL' OR normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('  ' || rec.object_name || ' (PACKAGE)');
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Индексы:');
  FOR rec IN (
    SELECT index_name FROM all_indexes
    WHERE owner = UPPER(p_dev_schema) AND index_name NOT LIKE 'SYS_%'
    ORDER BY index_name
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
    IF v_prod_ddl = 'NO DDL' OR normalize_ddl(v_dev_ddl) <> normalize_ddl(v_prod_ddl) THEN
      DBMS_OUTPUT.PUT_LINE('  ' || rec.index_name);
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