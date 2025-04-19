from datetime import datetime
import oracledb
import json

# Utility Classes
class JoinBlock:
    def __init__(self, join_type, table, on):
        self.join_type = join_type
        self.table = table
        self.on = on

class FilterCondition:
    def __init__(self, expression=None, operator=None, subquery=None,
                 logical_connector=None, sub_filters=None):
        self.expression = expression
        self.operator = operator
        self.subquery = subquery
        self.logical_connector = logical_connector
        self.sub_filters = sub_filters or []

class SelectCommand:
    def __init__(self, query_type, columns, tables, joins=None, filters=None):
        self.query_type = query_type
        self.columns = columns
        self.tables = tables
        self.joins = joins or []
        self.filters = filters or []

class DmlCommand:
    def __init__(self, query_type, operation, table, columns=None, values=None, set_=None, filters=None):
        self.query_type = query_type
        self.operation = operation
        self.table = table
        self.columns = columns or []
        self.values = values or []
        self.set = set_
        self.filters = filters or []

class DdlField:
    def __init__(self, name, type_, primary_key=False):
        self.name = name
        self.type = type_
        self.primary_key = primary_key

class DdlCommand:
    def __init__(self, query_type, operation, table, fields=None):
        self.query_type = query_type
        self.operation = operation
        self.table = table
        self.fields = fields or []

# Filter Builder
def build_filter(fc: dict):
    parts = []

    # Handle expression with subquery and operator (e.g., "ID IN (SELECT ...)")
    if fc.get("expression") and fc.get("subquery") and fc.get("operator"):
        sub_query_sql = build_select_query(fc["subquery"])
        parts.append(f"{fc['expression']} {fc['operator']} ({sub_query_sql})")

    # Handle basic expression only
    elif fc.get("expression"):
        parts.append(fc["expression"])

    # Handle subquery only (no expression/operator)
    elif fc.get("subquery"):
        sub_query_sql = build_select_query(fc["subquery"])
        parts.append(f"({sub_query_sql})")

    # Handle nested filters
    if fc.get("sub_filters"):
        sub_parts = [build_filter(sub) for sub in fc["sub_filters"] if sub]
        connector = f" {fc.get('logical_connector', 'AND')} "
        joined = connector.join(sub_parts)
        parts.append(f"({joined})")

    # Combine all parts with logical connector if needed
    if len(parts) > 1:
        logical_connector = fc.get("logical_connector", "AND")
        return f"({f' {logical_connector} '.join(parts)})"
    return parts[0] if parts else ""

# SELECT Builder
def build_select_query(cmd: dict):
    query = f"SELECT {', '.join(cmd['columns'])} FROM {', '.join(cmd['tables'])}"
    if cmd.get("joins"):
        for j in cmd["joins"]:
            query += f" {j['join_type']} {j['table']} ON {j['on']}"
    if cmd.get("filters"):
        filter_parts = [build_filter(f) for f in cmd["filters"]]
        query += " WHERE " + " AND ".join(filter_parts)
    return query

# SELECT Execution
def execute_select(conn, json_data):
    cmd = json.loads(json_data)
    query = build_select_query(cmd)
    print("Executing SELECT:", query)
    with conn.cursor() as cursor:
        cursor.execute(query)
        columns = [col[0] for col in cursor.description]
        for row in cursor:
            print(dict(zip(columns, row)))

# DML Execution
def execute_dml(conn, json_data):
    cmd = json.loads(json_data)
    operation = cmd["operation"].upper()

    if operation == "INSERT":
        query = f"INSERT INTO {cmd['table']} ({', '.join(cmd['columns'])}) VALUES ({', '.join(cmd['values'])})"
    elif operation == "UPDATE":
        query = f"UPDATE {cmd['table']} SET {cmd['set']}"
    elif operation == "DELETE":
        query = f"DELETE FROM {cmd['table']}"
    else:
        raise ValueError("Unsupported DML operation")

    if cmd.get("filters"):
        filter_parts = [build_filter(f) for f in cmd["filters"]]
        query += " WHERE " + " AND ".join(filter_parts)

    print("Executing DML:", query)
    with conn.cursor() as cursor:
        cursor.execute(query)
        print("Rows affected:", cursor.rowcount)
    conn.commit()

# DDL Execution
def execute_ddl(conn, json_data):
    cmd = json.loads(json_data)
    operation = cmd["operation"].upper()
    table_name = cmd["table"]

    def drop_sequence_and_trigger(cursor, fields):
        for f in fields:
            if f.get("primary_key"):
                seq_name = f"{table_name}_{f['name']}_seq"
                trg_name = f"{table_name}_{f['name']}_trg"
                try:
                    cursor.execute(f"DROP SEQUENCE {seq_name}")
                    print(f"Dropped sequence: {seq_name}")
                except oracledb.DatabaseError as e:
                    if "ORA-02289" not in str(e):  # sequence does not exist
                        raise
                try:
                    cursor.execute(f"DROP TRIGGER {trg_name}")
                    print(f"Dropped trigger: {trg_name}")
                except oracledb.DatabaseError as e:
                    if "ORA-04080" not in str(e):  # trigger does not exist
                        raise

    # DROP TABLE + associated sequence/trigger if specified
    if operation == "DROP_TABLE":
        with conn.cursor() as cursor:
            try:
                cursor.execute(f"DROP TABLE {table_name} CASCADE CONSTRAINTS")
                print(f"Dropped table: {table_name}")
            except oracledb.DatabaseError as e:
                if "ORA-00942" not in str(e):  # table does not exist
                    raise
            drop_sequence_and_trigger(cursor, cmd.get("fields", []))
        conn.commit()
        return

    # CREATE TABLE
    if operation == "CREATE_TABLE":
        if not cmd["fields"]:
            raise ValueError("Fields required for CREATE_TABLE")
        with conn.cursor() as cursor:
            try:
                cursor.execute(f"DROP TABLE {table_name} CASCADE CONSTRAINTS")
                print(f"Dropped table before create: {table_name}")
            except oracledb.DatabaseError as e:
                if "ORA-00942" not in str(e):
                    raise
            drop_sequence_and_trigger(cursor, cmd["fields"])

        # Build and execute CREATE TABLE statement
        field_defs = []
        pk_fields = []
        for f in cmd["fields"]:
            field_defs.append(f"{f['name']} {f['type']}")
            if f.get("primary_key"):
                pk_fields.append(f["name"])
        query = f"CREATE TABLE {table_name} ({', '.join(field_defs)}"
        if pk_fields:
            query += f", PRIMARY KEY ({', '.join(pk_fields)})"
        query += ")"

        print(f"Executing DDL: {query}")
        with conn.cursor() as cursor:
            cursor.execute(query)

        # Add sequence and trigger
        for f in cmd["fields"]:
            if f.get("primary_key"):
                seq = f"{table_name}_{f['name']}_seq"
                trg = f"{table_name}_{f['name']}_trg"

                print(f"Creating sequence: {seq}")
                with conn.cursor() as cursor:
                    cursor.execute(f"CREATE SEQUENCE {seq} START WITH 1 INCREMENT BY 1")

                print(f"Creating trigger: {trg}")
                with conn.cursor() as cursor:
                    cursor.execute(f"""
                    CREATE OR REPLACE TRIGGER {trg}
                    BEFORE INSERT ON {table_name}
                    FOR EACH ROW
                    WHEN (NEW.{f['name']} IS NULL)
                    BEGIN
                        SELECT {seq}.NEXTVAL INTO :NEW.{f['name']} FROM dual;
                    END;""")

        conn.commit()



if __name__ == "__main__":
    conn = oracledb.connect(user="system", password="password", dsn="localhost/XE")

    # Drop MY_TEST and MY_TEST2 if exist
    ddl_drop1 = '''
    {
        "query_type": "DDL",
        "operation": "DROP_TABLE",
        "table": "MY_TEST"
    }'''
    ddl_drop2 = '''
    {
        "query_type": "DDL",
        "operation": "DROP_TABLE",
        "table": "MY_TEST2"
    }'''
    for ddl in [ddl_drop1, ddl_drop2]:
        try:
            execute_ddl(conn, ddl)
        except Exception as e:
            print(f"Warning during drop: {e}")

    # Create MY_TEST
    ddl_create1 = '''
    {
        "query_type": "DDL",
        "operation": "CREATE_TABLE",
        "table": "MY_TEST",
        "fields": [
            {"name": "ID", "type": "NUMBER", "primary_key": true},
            {"name": "NAME", "type": "VARCHAR2(100)"}
        ]
    }'''
    execute_ddl(conn, ddl_create1)

    # Insert into MY_TEST
    dml_insert1 = '''
    {
        "query_type": "DML",
        "operation": "INSERT",
        "table": "MY_TEST",
        "columns": ["ID", "NAME"],
        "values": ["MY_TEST_ID_SEQ.NEXTVAL", "'Test Name'"]
    }'''
    execute_dml(conn, dml_insert1)

    # SELECT with nested filter
    select_nested = '''
    {
        "query_type": "SELECT",
        "columns": ["ID", "NAME"],
        "tables": ["MY_TEST"],
        "filters": [
            {
                "expression": "NAME = 'Test Name'",
                "sub_filters": [
                    {
                        "expression": "ID",
                        "operator": "IN",
                        "subquery": {
                            "query_type": "SELECT",
                            "columns": ["ID"],
                            "tables": ["MY_TEST"],
                            "filters": [
                                {
                                    "expression": "NAME = 'Test Name'"
                                }
                            ]
                        },
                        "logical_connector": "AND"
                    }
                ]
            }
        ]
    }'''
    execute_select(conn, select_nested)

    # Update MY_TEST
    dml_update = '''
    {
        "query_type": "DML",
        "operation": "UPDATE",
        "table": "MY_TEST",
        "set": "NAME = 'Updated Name'",
        "filters": [
            {
                "expression": "NAME = 'Test Name'"
            }
        ]
    }'''
    execute_dml(conn, dml_update)

    # SELECT with subquery filter
    select_subquery = '''
    {
        "query_type": "SELECT",
        "columns": ["ID", "NAME"],
        "tables": ["MY_TEST"],
        "filters": [
            {
                "expression": "ID",
                "operator": "IN",
                "subquery": {
                    "query_type": "SELECT",
                    "columns": ["ID"],
                    "tables": ["MY_TEST"],
                    "filters": [
                        {
                            "expression": "NAME = 'Updated Name'"
                        }
                    ]
                }
            }
        ]
    }'''
    execute_select(conn, select_subquery)

    # Create MY_TEST2
    ddl_create2 = '''
    {
        "query_type": "DDL",
        "operation": "CREATE_TABLE",
        "table": "MY_TEST2",
        "fields": [
            {"name": "TEST_ID", "type": "NUMBER", "primary_key": true},
            {"name": "DESCRIPTION", "type": "VARCHAR2(100)"}
        ]
    }'''
    execute_ddl(conn, ddl_create2)

    # Insert into MY_TEST2
    dml_insert2 = '''
    {
        "query_type": "DML",
        "operation": "INSERT",
        "table": "MY_TEST2",
        "columns": ["TEST_ID", "DESCRIPTION"],
        "values": ["MY_TEST2_TEST_ID_SEQ.NEXTVAL", "'Test Description'"]
    }'''
    execute_dml(conn, dml_insert2)

    # SELECT with JOIN
    select_join = '''
    {
        "query_type": "SELECT",
        "columns": ["MY_TEST.ID", "MY_TEST.NAME", "MY_TEST2.DESCRIPTION"],
        "tables": ["MY_TEST"],
        "joins": [
            {
                "join_type": "INNER JOIN",
                "table": "MY_TEST2",
                "on": "MY_TEST.ID = MY_TEST2.TEST_ID"
            }
        ],
        "filters": [
            {
                "expression": "MY_TEST.NAME LIKE '%Name%'"
            }
        ]
    }'''
    execute_select(conn, select_join)

    # Cursor-like result (print rows)
    cursor_select = '''
    {
        "query_type": "SELECT",
        "columns": ["ID", "NAME"],
        "tables": ["MY_TEST"],
        "filters": [
            {
                "expression": "NAME LIKE '%Name%'"
            }
        ]
    }'''
    print("\nCursor-like data:")
    with conn.cursor() as cursor:
        select_data = json.loads(cursor_select)
        query = "SELECT ID, NAME FROM MY_TEST WHERE NAME LIKE '%Name%'"
        cursor.execute(query)
        for row in cursor:
            print(dict(zip(["ID", "NAME"], row)))

    # DELETE from MY_TEST
    dml_delete = '''
    {
        "query_type": "DML",
        "operation": "DELETE",
        "table": "MY_TEST",
        "filters": [
            {
                "expression": "NAME = 'Updated Name'"
            }
        ]
    }'''
    execute_dml(conn, dml_delete)

    # Drop both tables
    for ddl in [ddl_drop1, ddl_drop2]:
        try:
            execute_ddl(conn, ddl)
        except Exception as e:
            print(f"Warning during final drop: {e}")

    conn.close()
