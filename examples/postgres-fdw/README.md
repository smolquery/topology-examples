# postgres-fdw

**Planned (T-647).** OLTP and OLAP joined from Postgres: a Postgres pod with
`postgres_fdw` attaches smolquery's wire listener and imports a dataset as
foreign tables; in the other direction, smolquery registers that Postgres
as a federated connection and joins its rows from the OLAP side.

Host ports: API 9600, smolquery Postgres wire 9605, the OLTP Postgres 9606.
