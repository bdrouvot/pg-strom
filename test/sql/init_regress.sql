--
-- initialization of regression test database
--
SHOW application_name
\gset
SELECT pgstrom.regression_testdb_revision() != :application_name rev_check
\gset

\if :rev_check
-- cleanup resources
SET client_min_messages = error;
DROP SCHEMA IF EXISTS pgstrom_regress CASCADE;
DROP FUNCTION IF EXISTS pgstrom.regression_test_revision();
RESET client_min_messages;

BEGIN;
CREATE SCHEMA pgstrom_regress;
SET search_path = pgstrom_regress,public;

CREATE TABLE customer (
    c_custkey numeric PRIMARY KEY,
    c_name character varying(25),
    c_address character varying(25),
    c_city character(10),
    c_nation character(15),
    c_region character(12),
    c_phone character(15),
    c_mktsegment character(10)
);

CREATE TABLE date1 (
    d_datekey integer PRIMARY KEY,
    d_date character(18),
    d_dayofweek character(12),
    d_month character(9),
    d_year integer,
    d_yearmonthnum numeric,
    d_yearmonth character(7),
    d_daynuminweek numeric,
    d_daynuminmonth numeric,
    d_daynuminyear numeric,
    d_monthnuminyear numeric,
    d_weeknuminyear numeric,
    d_sellingseason character(12),
    d_lastdayinweekfl character(1),
    d_lastdayinmonthfl character(1),
    d_holidayfl character(1),
    d_weekdayfl character(1)
);

CREATE TABLE lineorder (
    lo_orderkey numeric,
    lo_linenumber integer,
    lo_custkey numeric,
    lo_partkey integer,
    lo_suppkey numeric,
    lo_orderdate integer,
    lo_orderpriority character(15),
    lo_shippriority character(1),
    lo_quantity numeric,
    lo_extendedprice numeric,
    lo_ordertotalprice numeric,
    lo_discount numeric,
    lo_revenue numeric,
    lo_supplycost numeric,
    lo_tax numeric,
    lo_commit_date character(8),
    lo_shipmode character(10)
);

CREATE TABLE part (
    p_partkey integer PRIMARY KEY,
    p_name character varying(22),
    p_mfgr character(6),
    p_category character(7),
    p_brand1 character(9),
    p_color character varying(11),
    p_type character varying(25),
    p_size numeric,
    p_container character(10)
);

CREATE TABLE supplier (
    s_suppkey numeric PRIMARY KEY,
    s_name character(25),
    s_address character varying(25),
    s_city character(10),
    s_nation character(15),
    s_region character(12),
    s_phone character(15)
);

\copy customer  FROM PROGRAM 'dbgen-ssbm -q -s2 -X -Tc' DELIMITER '|';
\copy date1     FROM PROGRAM 'dbgen-ssbm -q -s2 -X -Td' DELIMITER '|';
\copy lineorder FROM PROGRAM 'dbgen-ssbm -q -s2 -X -Tl' DELIMITER '|';
\copy part      FROM PROGRAM 'dbgen-ssbm -q -s2 -X -Tp' DELIMITER '|';
\copy supplier  FROM PROGRAM 'dbgen-ssbm -q -s2 -X -Ts' DELIMITER '|';

--
-- Simple large tables (for CPU fallback & suspend/resume case)
--
CREATE TABLE t0 (id int,
                 cat text,
                 aid int,
                 bid int,
                 cid int,
                 did int,
                 ymd date,
                 md5 text);
CREATE TABLE t1 (aid int, atext text, ax float, ay float);
CREATE TABLE t2 (bid int, btext text, bx float, by float);
CREATE TABLE t3 (cid int, ctext text, cx float, cy float);
CREATE TABLE t4 (did int, dtext text, dx float, dy float);
INSERT INTO t0 (SELECT x, CASE floor(random()*26)
                          WHEN  0 THEN 'aaa'
                          WHEN  1 THEN 'bbb'
                          WHEN  2 THEN 'ccc'
                          WHEN  3 THEN 'ddd'
                          WHEN  4 THEN 'eee'
                          WHEN  5 THEN 'fff'
                          WHEN  6 THEN 'ggg'
                          WHEN  7 THEN 'hhh'
                          WHEN  8 THEN 'iii'
                          WHEN  9 THEN 'jjj'
                          WHEN 10 THEN 'kkk'
                          WHEN 11 THEN 'lll'
                          WHEN 12 THEN 'mmm'
                          WHEN 13 THEN 'nnn'
                          WHEN 14 THEN 'ooo'
                          WHEN 15 THEN 'ppp'
                          WHEN 16 THEN 'qqq'
                          WHEN 17 THEN 'rrr'
                          WHEN 18 THEN 'sss'
                          WHEN 19 THEN 'ttt'
                          WHEN 20 THEN 'uuu'
                          WHEN 21 THEN 'vvv'
                          WHEN 22 THEN 'www'
                          WHEN 23 THEN 'xxx'
                          WHEN 24 THEN 'yyy'
                          ELSE 'zzz'
                          END,
                       pgstrom.random_int(0.5, 1, 40000),
                       pgstrom.random_int(0.5, 1, 40000),
                       pgstrom.random_int(0.5, 1, 40000),
                       12345,   -- for suspend/resume test
                       pgstrom.random_date(0.5, '2010-01-01', '2030-12-31'),
                       md5(x::text)
                  FROM generate_series(1,2000000) x);
INSERT INTO t1 (SELECT x, md5((x+1)::text), random()*100.0, random()*100.0
                  FROM generate_series(1,40000) x);
INSERT INTO t2 (SELECT x, md5((x+2)::text), random()*100.0, random()*100.0
                  FROM generate_series(1,40000) x);
INSERT INTO t3 (SELECT x, md5((x+3)::text), random()*100.0, random()*100.0
                  FROM generate_series(1,40000) x);
INSERT INTO t4 (SELECT x, md5((x+4)::text), random()*100.0, random()*100.0
                  FROM generate_series(1,40000) x);
INSERT INTO t4 (SELECT 12345, md5((x+10)::text), random()*100.0, random()*100.0
                  FROM generate_series(1,20) x);    -- for suspend/resume

-- test for CPU fallback / GPU kernel suspend/resume
CREATE TABLE fallback_data (
  id    int,
  aid   int,
  cat   text,
  x     float,
  y     float,
  memo  text
);
SELECT pgstrom.random_setseed(20190714);
INSERT INTO fallback_data (
  SELECT x, pgstrom.random_int(0.5, 1, 4000),
            CASE floor(random()*26)
            WHEN 0 THEN 'aaa'
            WHEN  1 THEN 'bbb'
            WHEN  2 THEN 'ccc'
            WHEN  3 THEN 'ddd'
            WHEN  4 THEN 'eee'
            WHEN  5 THEN 'fff'
            WHEN  6 THEN 'ggg'
            WHEN  7 THEN 'hhh'
            WHEN  8 THEN 'iii'
            WHEN  9 THEN 'jjj'
            WHEN 10 THEN 'kkk'
            WHEN 11 THEN 'lll'
            WHEN 12 THEN 'mmm'
            WHEN 13 THEN 'nnn'
            WHEN 14 THEN 'ooo'
            WHEN 15 THEN 'ppp'
            WHEN 16 THEN 'qqq'
            WHEN 17 THEN 'rrr'
            WHEN 18 THEN 'sss'
            WHEN 19 THEN 'ttt'
            WHEN 20 THEN 'uuu'
            WHEN 21 THEN 'vvv'
            WHEN 22 THEN 'www'
            WHEN 23 THEN 'xxx'
            WHEN 24 THEN 'yyy'
            ELSE 'zzz'
            END,
            pgstrom.random_float(2,-1000.0,1000.0),
            pgstrom.random_float(2,-1000.0,1000.0),
            pgstrom.random_text_len(2, 200)
    FROM generate_series(1,400001) x);
UPDATE fallback_data
   SET memo = md5(memo) || md5(memo)
 WHERE id = 400001;
UPDATE fallback_data
   SET memo = memo || '-' || memo || '-' || memo || '-' || memo
 WHERE id = 400001;
UPDATE fallback_data
   SET memo = memo || '-' || memo || '-' || memo || '-' || memo
 WHERE id = 400001;
UPDATE fallback_data
   SET memo = memo || '-' || memo || '-' || memo || '-' || memo
 WHERE id = 400001;

CREATE TABLE fallback_small (
  aid   int,
  z     float,
  md5   varchar(32)
);
INSERT INTO fallback_small (
  SELECT x, pgstrom.random_float(2,-1000.0,1000.0),
            md5(x::text)
    FROM generate_series(1,4000) x);

CREATE TABLE fallback_enlarge (
  aid   int,
  z     float,
  md5   char(200)
);
INSERT INTO fallback_enlarge (
  SELECT x / 5, pgstrom.random_float(2,-1000.0,1000.0),
            md5(x::text)
    FROM generate_series(1,20000) x);

-- test for partition-wise GpuJoin
CREATE TABLE rtable (
  id    int,
  label text,
  aid   int,
  bid   int,
  cid   int,
  x     text
);

CREATE TABLE ptable (
  id    int,
  label text,
  aid   int,
  bid   int,
  cid   int,
  x     text
)
PARTITION BY HASH(id);

CREATE TABLE ptable__p0 PARTITION OF ptable
       FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE ptable__p1 PARTITION OF ptable
       FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE ptable__p2 PARTITION OF ptable
       FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE ptable__p3 PARTITION OF ptable
       FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO rtable (
  SELECT x, CASE pgstrom.random_int(0.1) % 28
            WHEN  0 THEN 'aaa'
            WHEN  1 THEN 'bbb'
            WHEN  2 THEN 'ccc'
            WHEN  3 THEN 'ddd'
            WHEN  4 THEN 'eee'
            WHEN  5 THEN 'fff'
            WHEN  6 THEN 'ggg'
            WHEN  7 THEN 'hhh'
            WHEN  8 THEN 'iii'
            WHEN  9 THEN 'jjj'
            WHEN 10 THEN 'kkk'
            WHEN 11 THEN 'lll'
            WHEN 12 THEN 'mmm'
            WHEN 13 THEN 'nnn'
            WHEN 14 THEN 'ooo'
            WHEN 15 THEN 'ppp'
            WHEN 16 THEN 'qqq'
            WHEN 17 THEN 'rrr'
            WHEN 18 THEN 'sss'
            WHEN 19 THEN 'ttt'
            WHEN 20 THEN 'uuu'
            WHEN 21 THEN 'vvv'
            WHEN 22 THEN 'www'
            WHEN 23 THEN 'xxx'
            WHEN 24 THEN 'yyy'
            WHEN 25 THEN 'zzz'
            WHEN 26 THEN 'abc'  -- no match with ltable
            WHEN 27 THEN 'xyz'  -- no match with ltable
            ELSE null
            END,
            pgstrom.random_int(0.1,     1, 20000),
            pgstrom.random_int(0.1, -1000, 19000),
            pgstrom.random_int(0.1, -2000, 18000),
            md5(x::text)
    FROM generate_series(1,40000000) x);

INSERT INTO ptable (SELECT * FROM rtable);

CREATE TABLE atable (
  aid     int primary key,
  x       int
);

CREATE TABLE btable (
  bid     int primary key,
  y       int
);

CREATE TABLE ctable (
  cid     int primary key,
  z       int
);

CREATE TABLE ltable (
  lid     int primary key,
  label   text
);

INSERT INTO atable (SELECT x, pgstrom.random_int(0, -200, 200)
                      FROM generate_series(1,20000) x);
INSERT INTO btable (SELECT x, pgstrom.random_int(0, -200, 200)
                      FROM generate_series(1,22000) x);
INSERT INTO ctable (SELECT x, pgstrom.random_int(0, -200, 200)
                      FROM generate_series(1,24000) x);
INSERT INTO ltable
     VALUES ( 1, 'aaa'), ( 2, 'bbb'), ( 3, 'ccc'), ( 4, 'ddd'),
            ( 5, 'eee'), ( 6, 'fff'), ( 7, 'ggg'), ( 8, 'hhh'),
            ( 9, 'iii'), (10, 'jjj'), (11, 'kkk'), (12, 'lll'),
            (13, 'mmm'), (14, 'nnn'), (15, 'ooo'), (16, 'ppp'),
            (17, 'qqq'), (18, 'rrr'), (19, 'sss'), (20, 'ttt'),
            (21, 'uuu'), (22, 'vvv'), (23, 'www'), (24, 'xxx'),
            (25, 'yyy'), (26, 'zzz'), (27,'hoge'), (28,'piyo');

-- mark regression test database (large ones) is built
\set sql_func_body 'SELECT ':application_name
CREATE OR REPLACE FUNCTION
pgstrom.regression_testdb_revision()
RETURNS int
AS :'sql_func_body'
LANGUAGE 'sql';

COMMIT;
-- vacuum tables
VACUUM ANALYZE;

\endif
