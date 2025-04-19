package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"strings"

	_ "github.com/sijms/go-ora/v2"
)

type JoinBlock struct {
	JoinType string `json:"join_type"`
	Table    string `json:"table"`
	On       string `json:"on"`
}

type FilterCondition struct {
	Expression       string            `json:"expression,omitempty"`
	Operator         string            `json:"operator,omitempty"`
	SubQuery         *SelectCommand    `json:"subquery,omitempty"`
	LogicalConnector string            `json:"logical_connector,omitempty"`
	SubFilters       []FilterCondition `json:"sub_filters,omitempty"`
}

type SelectCommand struct {
	QueryType string            `json:"query_type"`
	Columns   []string          `json:"columns"`
	Tables    []string          `json:"tables"`
	Joins     []JoinBlock       `json:"joins,omitempty"`
	Filters   []FilterCondition `json:"filters,omitempty"`
}

type DmlCommand struct {
	QueryType string            `json:"query_type"`
	Operation string            `json:"operation"`
	Table     string            `json:"table"`
	Columns   []string          `json:"columns,omitempty"`
	Values    []string          `json:"values,omitempty"`
	Set       string            `json:"set,omitempty"`
	Filters   []FilterCondition `json:"filters,omitempty"`
}

type DdlField struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	PrimaryKey bool   `json:"primary_key,omitempty"`
}

type DdlCommand struct {
	QueryType string     `json:"query_type"`
	Operation string     `json:"operation"`
	Table     string     `json:"table"`
	Fields    []DdlField `json:"fields,omitempty"`
}

func buildFilter(fc FilterCondition) string {
	result := fc.Expression
	if fc.SubQuery != nil {
		subQuerySQL := buildSelectQuery(*fc.SubQuery)
		result = result + fmt.Sprintf(" %s (%s)", fc.Operator, subQuerySQL)
	}
	if len(fc.SubFilters) > 0 {
		var subParts []string
		for _, sf := range fc.SubFilters {
			subParts = append(subParts, buildFilter(sf))
		}
		connector := fc.LogicalConnector
		if connector == "" {
			connector = "AND"
		}
		if result != "" {
			result = "(" + result + " " + connector + " " + strings.Join(subParts, " "+connector+" ") + ")"
		} else {
			result = "(" + strings.Join(subParts, " "+connector+" ") + ")"
		}
	}
	return result
}

func buildSelectQuery(cmd SelectCommand) string {
	query := "SELECT " + strings.Join(cmd.Columns, ", ") + " FROM " + strings.Join(cmd.Tables, ", ")
	if len(cmd.Joins) > 0 {
		for _, j := range cmd.Joins {
			query += fmt.Sprintf(" %s %s ON %s", j.JoinType, j.Table, j.On)
		}
	}
	if len(cmd.Filters) > 0 {
		var filterParts []string
		for _, f := range cmd.Filters {
			filterParts = append(filterParts, buildFilter(f))
		}
		query += " WHERE " + strings.Join(filterParts, " AND ")
	}
	return query
}

func executeSelect(db *sql.DB, jsonData string) error {
	var cmd SelectCommand
	err := json.Unmarshal([]byte(jsonData), &cmd)
	if err != nil {
		return fmt.Errorf("json unmarshal error: %v", err)
	}
	query := buildSelectQuery(cmd)
	fmt.Println("Executing query:", query)
	rows, err := db.Query(query)
	if err != nil {
		return fmt.Errorf("query execution error: %v", err)
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return fmt.Errorf("retrieving columns error: %v", err)
	}
	values := make([]interface{}, len(columns))
	valuePtrs := make([]interface{}, len(columns))
	for rows.Next() {
		for i := range columns {
			valuePtrs[i] = &values[i]
		}
		err = rows.Scan(valuePtrs...)
		if err != nil {
			return fmt.Errorf("row scan error: %v", err)
		}
		for i, col := range columns {
			fmt.Printf("%s: %v  ", col, values[i])
		}
		fmt.Println()
	}
	return nil
}

func getCursor(db *sql.DB, jsonData string) (*sql.Rows, error) {
	var cmd SelectCommand
	err := json.Unmarshal([]byte(jsonData), &cmd)
	if err != nil {
		return nil, fmt.Errorf("json unmarshal error: %v", err)
	}
	query := buildSelectQuery(cmd)
	fmt.Println("Executing query with getCursor:", query)
	rows, err := db.Query(query)
	if err != nil {
		return nil, fmt.Errorf("query execution error: %v", err)
	}
	return rows, nil
}

func executeDML(db *sql.DB, jsonData string) error {
	var cmd DmlCommand
	err := json.Unmarshal([]byte(jsonData), &cmd)
	if err != nil {
		return fmt.Errorf("json unmarshal error: %v", err)
	}
	var query string
	switch strings.ToUpper(cmd.Operation) {
	case "INSERT":
		query = fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", cmd.Table, strings.Join(cmd.Columns, ", "), strings.Join(cmd.Values, ", "))
	case "UPDATE":
		query = fmt.Sprintf("UPDATE %s SET %s", cmd.Table, cmd.Set)
	case "DELETE":
		query = fmt.Sprintf("DELETE FROM %s", cmd.Table)
	default:
		return fmt.Errorf("unsupported DML operation")
	}
	if len(cmd.Filters) > 0 {
		var filterParts []string
		for _, f := range cmd.Filters {
			filterParts = append(filterParts, buildFilter(f))
		}
		query += " WHERE " + strings.Join(filterParts, " AND ")
	}
	fmt.Println("Executing DML:", query)
	res, err := db.Exec(query)
	if err != nil {
		return fmt.Errorf("executing DML error: %v", err)
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("retrieving rows affected error: %v", err)
	}
	fmt.Println("Rows affected:", rowsAffected)
	return nil
}

func executeDDL(db *sql.DB, jsonData string) error {
	var cmd DdlCommand
	err := json.Unmarshal([]byte(jsonData), &cmd)
	if err != nil {
		return fmt.Errorf("json unmarshal error: %v", err)
	}
	var query string
	switch strings.ToUpper(cmd.Operation) {
	case "CREATE_TABLE":
		if len(cmd.Fields) == 0 {
			return fmt.Errorf("fields required for CREATE_TABLE")
		}
		var fieldDefs []string
		var pkFields []string
		for _, f := range cmd.Fields {
			fieldDefs = append(fieldDefs, fmt.Sprintf("%s %s", f.Name, f.Type))
			if f.PrimaryKey {
				pkFields = append(pkFields, f.Name)
			}
		}
		query = fmt.Sprintf("CREATE TABLE %s (%s", cmd.Table, strings.Join(fieldDefs, ", "))
		if len(pkFields) > 0 {
			query += fmt.Sprintf(", PRIMARY KEY (%s)", strings.Join(pkFields, ", "))
		}
		query += ")"
	case "DROP_TABLE":
		query = fmt.Sprintf("DROP TABLE %s", cmd.Table)
	default:
		return fmt.Errorf("unsupported DDL operation")
	}
	fmt.Println("Executing DDL:", query)
	_, err = db.Exec(query)
	if err != nil {
		return fmt.Errorf("executing DDL error: %v", err)
	}
	if strings.ToUpper(cmd.Operation) == "CREATE_TABLE" {
		for _, f := range cmd.Fields {
			if f.PrimaryKey {
				trgName := fmt.Sprintf("%s_%s_trg", cmd.Table, f.Name)
				seqName := fmt.Sprintf("%s_%s_seq", cmd.Table, f.Name)
				seqQuery := fmt.Sprintf("CREATE SEQUENCE %s START WITH 1 INCREMENT BY 1", seqName)
				fmt.Println("Executing DDL for sequence:", seqQuery)
				_, err = db.Exec(seqQuery)
				if err != nil {
					return fmt.Errorf("executing sequence DDL error: %v", err)
				}
				trgQuery := fmt.Sprintf("CREATE OR REPLACE TRIGGER %s BEFORE INSERT ON %s FOR EACH ROW WHEN (NEW.%s IS NULL) BEGIN SELECT %s.NEXTVAL INTO :NEW.%s FROM dual; END;", trgName, cmd.Table, f.Name, seqName, f.Name)
				fmt.Println("Executing DDL for trigger:", trgQuery)
				_, err = db.Exec(trgQuery)
				if err != nil {
					return fmt.Errorf("executing trigger DDL error: %v", err)
				}
				break
			}
		}
	}
	fmt.Println("DDL executed successfully")
	return nil
}

func main() {
	db, err := sql.Open("oracle", "oracle://system:password@localhost:1521/XE")
	if err != nil {
		log.Fatalf("db connection error: %v", err)
	}
	defer db.Close()
	err = db.Ping()
	if err != nil {
		log.Fatalf("cannot ping db: %v", err.Error())
	}

	ddlDropJSON := `{
		"query_type": "DDL",
		"operation": "DROP_TABLE",
		"table": "MY_TEST"
	}`
	_ = executeDDL(db, ddlDropJSON)

	ddlDropJSON2 := `{
		"query_type": "DDL",
		"operation": "DROP_TABLE",
		"table": "MY_TEST2"
	}`
	_ = executeDDL(db, ddlDropJSON2)

	ddlCreateJSON := `{
		"query_type": "DDL",
		"operation": "CREATE_TABLE",
		"table": "MY_TEST",
		"fields": [
			{"name": "ID", "type": "NUMBER", "primary_key": true},
			{"name": "NAME", "type": "VARCHAR2(100)"}
		]
	}`
	err = executeDDL(db, ddlCreateJSON)
	if err != nil {
		log.Fatalf("DDL CREATE error: %v", err)
	}

	dmlInsertJSON := `{
		"query_type": "DML",
		"operation": "INSERT",
		"table": "MY_TEST",
		"columns": ["ID", "NAME"],
		"values": ["MY_TEST_ID_SEQ.NEXTVAL", "'Test Name'"]
	}`
	err = executeDML(db, dmlInsertJSON)
	if err != nil {
		log.Fatalf("DML INSERT error: %v", err)
	}

	selectJSON := `{
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
	}`
	err = executeSelect(db, selectJSON)
	if err != nil {
		log.Fatalf("SELECT error: %v", err)
	}

	dmlUpdateJSON := `{
		"query_type": "DML",
		"operation": "UPDATE",
		"table": "MY_TEST",
		"set": "NAME = 'Updated Name'",
		"filters": [
			{
				"expression": "NAME = 'Test Name'"
			}
		]
	}`
	err = executeDML(db, dmlUpdateJSON)
	if err != nil {
		log.Fatalf("DML UPDATE error: %v", err)
	}

	selectNestedJSON := `{
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
	}`
	err = executeSelect(db, selectNestedJSON)
	if err != nil {
		log.Fatalf("SELECT nested error: %v", err)
	}

	ddlCreateJSON2 := `{
		"query_type": "DDL",
		"operation": "CREATE_TABLE",
		"table": "MY_TEST2",
		"fields": [
			{"name": "TEST_ID", "type": "NUMBER", "primary_key": true},
			{"name": "DESCRIPTION", "type": "VARCHAR2(100)"}
		]
	}`
	err = executeDDL(db, ddlCreateJSON2)
	if err != nil {
		log.Fatalf("DDL CREATE error for MY_TEST2: %v", err)
	}
	dmlInsertJSON2 := `{
		"query_type": "DML",
		"operation": "INSERT",
		"table": "MY_TEST2",
		"columns": ["TEST_ID", "DESCRIPTION"],
		"values": ["MY_TEST2_TEST_ID_SEQ.NEXTVAL", "'Test Description'"]
	}`
	err = executeDML(db, dmlInsertJSON2)
	if err != nil {
		log.Fatalf("DML INSERT error for MY_TEST2: %v", err)
	}

	selectJoinJSON := `{
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
	}`
	err = executeSelect(db, selectJoinJSON)
	if err != nil {
		log.Fatalf("SELECT JOIN error: %v", err)
	}

	cursorJSON := `{
		"query_type": "SELECT",
		"columns": ["ID", "NAME"],
		"tables": ["MY_TEST"],
		"filters": [
			{
				"expression": "NAME LIKE '%Name%'"
			}
		]
	}`
	rows, err := getCursor(db, cursorJSON)
	if err != nil {
		log.Fatalf("get cursor error: %v", err)
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		log.Fatalf("retrieving cursor columns error: %v", err)
	}
	fmt.Println("Cursor Data:")
	values := make([]interface{}, len(columns))
	valuePtrs := make([]interface{}, len(columns))
	for rows.Next() {
		for i := range columns {
			valuePtrs[i] = &values[i]
		}
		err = rows.Scan(valuePtrs...)
		if err != nil {
			log.Fatalf("cursor reading error: %v", err)
		}
		for i, col := range columns {
			fmt.Printf("%s: %v  ", col, values[i])
		}
		fmt.Println()
	}

	dmlDeleteJSON := `{
		"query_type": "DML",
		"operation": "DELETE",
		"table": "MY_TEST",
		"filters": [
			{
				"expression": "NAME = 'Updated Name'"
			}
		]
	}`
	err = executeDML(db, dmlDeleteJSON)
	if err != nil {
		log.Fatalf("DML DELETE error: %v", err)
	}

	ddlDropJSON = `{
		"query_type": "DDL",
		"operation": "DROP_TABLE",
		"table": "MY_TEST"
	}`
	err = executeDDL(db, ddlDropJSON)
	if err != nil {
		log.Fatalf("DDL DROP error for MY_TEST: %v", err)
	}

	ddlDropJSON2 = `{
		"query_type": "DDL",
		"operation": "DROP_TABLE",
		"table": "MY_TEST2"
	}`
	err = executeDDL(db, ddlDropJSON2)
	if err != nil {
		log.Fatalf("DDL DROP error for MY_TEST2: %v", err)
	}
}
