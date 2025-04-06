### Official guide by Vitek

1. Launch

```docker-compose up if Windows, or docker compose up on Unix```

2. docker ps in your terminal or Powershell to get container name of you oracle db instance 

```docker exec -it <container-name> bash```

3. log to system user as sysdba

```sqlplus sys/password@localhost:1521/XE as sysdba```

4. Copy all the related queries to create users dev, prod, super

```
DROP USER dev_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER dev_schema IDENTIFIED BY dev_password;
GRANT CONNECT, RESOURCE TO DEV_SCHEMA;
GRANT ALL PRIVILEGES TO DEV_SCHEMA;

DROP USER prod_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER prod_schema IDENTIFIED BY prod_password;
GRANT ALL PRIVILEGES TO PROD_SCHEMA;
GRANT CONNECT, RESOURCE TO PROD_SCHEMA;

DROP USER super_schema CASCADE;
ALTER SESSION SET "_ORACLE_SCRIPT" = TRUE;
CREATE USER super_schema IDENTIFIED BY super_password;
GRANT ALL PRIVILEGES TO SUPER_SCHEMA;
GRANT SYSDBA TO SUPER_SCHEMA CONTAINER=ALL; - grant sysdba for super_schema user
```

5. Log in to super user, either sqlplus with sysdba role or in SQL Developer

6. Create all tables , procs, funcs e.g data and then run

```
BEGIN
    compare_schemes('DEV_SCHEMA', 'PROD_SCHEMA');
END;
```

7. The end(nu eto ne tochno, nu vrode vse ok rabotaet kak nado v labe)