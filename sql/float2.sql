/*
 * float2 - half-precision floating point data support
 */
CREATE TYPE pg_catalog.float2;
CREATE FUNCTION pgstrom.float2_in(cstring)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float2_in'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.float2_out(float2)
  RETURNS cstring
  AS 'MODULE_PATHNAME','pgstrom_float2_out'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.float2_recv(internal)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float2_recv'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.float2_send(float2)
  RETURNS bytea
  AS 'MODULE_PATHNAME','pgstrom_float2_send'
  LANGUAGE C STRICT IMMUTABLE;
CREATE TYPE pg_catalog.float2
(
  input =  pgstrom.float2_in,
  output = pgstrom.float2_out,
  receive = pgstrom.float2_recv,
  send = pgstrom.float2_send,
  like = pg_catalog.int2
);

--
-- Type Cast Definitions
--
CREATE FUNCTION pgstrom.as_float4(float2)
  RETURNS float4
  AS 'MODULE_PATHNAME','pgstrom_float2_to_float4'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float8(float2)
  RETURNS float8
  AS 'MODULE_PATHNAME','pgstrom_float2_to_float8'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_int2(float2)
  RETURNS int2
  AS 'MODULE_PATHNAME','pgstrom_float2_to_int2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_int4(float2)
  RETURNS int4
  AS 'MODULE_PATHNAME','pgstrom_float2_to_int4'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_int8(float2)
  RETURNS int8
  AS 'MODULE_PATHNAME','pgstrom_float2_to_int8'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_numeric(float2)
  RETURNS numeric
  AS 'MODULE_PATHNAME','pgstrom_float2_to_numeric'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.as_float2(float4)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float4_to_float2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float2(float8)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float8_to_float2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float2(int2)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_int2_to_float2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float2(int4)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_int4_to_float2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float2(int8)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_int8_to_float2'
  LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION pgstrom.as_float2(numeric)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_numeric_to_float2'
  LANGUAGE C STRICT IMMUTABLE;

CREATE CAST (float2 AS float4)
  WITH FUNCTION pgstrom.as_float4(float2)
  AS IMPLICIT;
CREATE CAST (float2 AS float8)
  WITH FUNCTION pgstrom.as_float8(float2)
  AS IMPLICIT;
CREATE CAST (float2 AS int2)
  WITH FUNCTION pgstrom.as_int2(float2)
  AS ASSIGNMENT;
CREATE CAST (float2 AS int4)
  WITH FUNCTION pgstrom.as_int4(float2)
  AS ASSIGNMENT;
CREATE CAST (float2 AS int8)
  WITH FUNCTION pgstrom.as_int8(float2)
  AS ASSIGNMENT;
CREATE CAST (float2 AS numeric)
  WITH FUNCTION pgstrom.as_numeric(float2)
  AS ASSIGNMENT;

CREATE CAST (float4 AS float2)
  WITH FUNCTION pgstrom.as_float2(float4)
  AS IMPLICIT;
CREATE CAST (float8 AS float2)
  WITH FUNCTION pgstrom.as_float2(float8)
  AS IMPLICIT;
CREATE CAST (int2 AS float2)
  WITH FUNCTION pgstrom.as_float2(int2)
  AS ASSIGNMENT;
CREATE CAST (int4 AS float2)
  WITH FUNCTION pgstrom.as_float2(int4)
  AS ASSIGNMENT;
CREATE CAST (int8 AS float2)
  WITH FUNCTION pgstrom.as_float2(int8)
  AS ASSIGNMENT;
CREATE CAST (numeric AS float2)
  WITH FUNCTION pgstrom.as_float2(numeric)
  AS ASSIGNMENT;

--
-- comparison operators
--
CREATE FUNCTION pgstrom.float2_eq(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_eq'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_ne(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_ne'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_lt(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_lt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_le(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_le'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_gt(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_gt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_ge(float2,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float2_ge'
  LANGUAGE C STRICT IMMUTABLE;


CREATE FUNCTION pgstrom.float42_eq(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_eq'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float42_ne(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_ne'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float42_lt(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_lt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float42_le(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_le'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float42_gt(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_gt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float42_ge(float4,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float42_ge'
  LANGUAGE C STRICT IMMUTABLE;


CREATE FUNCTION pgstrom.float82_eq(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_eq'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float82_ne(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_ne'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float82_lt(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_lt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float82_le(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_le'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float82_gt(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_gt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float82_ge(float8,float2)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float82_ge'
  LANGUAGE C STRICT IMMUTABLE;


CREATE FUNCTION pgstrom.float24_eq(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_eq'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float24_ne(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_ne'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float24_lt(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_lt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float24_le(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_le'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float24_gt(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_gt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float24_ge(float2,float4)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float24_ge'
  LANGUAGE C STRICT IMMUTABLE;


CREATE FUNCTION pgstrom.float28_eq(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_eq'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float28_ne(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_ne'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float28_lt(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_lt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float28_le(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_le'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float28_gt(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_gt'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float28_ge(float2,float8)
  RETURNS bool
  AS 'MODULE_PATHNAME','pgstrom_float28_ge'
  LANGUAGE C STRICT IMMUTABLE;


CREATE OPERATOR pg_catalog.= (
  PROCEDURE = pgstrom.float2_eq,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = =, NEGATOR = <>
);

CREATE OPERATOR pg_catalog.<> (
  PROCEDURE = pgstrom.float2_ne,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <>, NEGATOR = =
);

CREATE OPERATOR pg_catalog.< (
  PROCEDURE = pgstrom.float2_lt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >, NEGATOR = >=
);

CREATE OPERATOR pg_catalog.<= (
  PROCEDURE = pgstrom.float2_le,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >=, NEGATOR = >
);

CREATE OPERATOR pg_catalog.> (
  PROCEDURE = pgstrom.float2_gt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <, NEGATOR = <=
);

CREATE OPERATOR pg_catalog.>= (
  PROCEDURE = pgstrom.float2_ge,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <=, NEGATOR = <
);


CREATE OPERATOR pg_catalog.= (
  PROCEDURE = pgstrom.float42_eq,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = =, NEGATOR = <>
);

CREATE OPERATOR pg_catalog.<> (
  PROCEDURE = pgstrom.float42_ne,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <>, NEGATOR = =
);

CREATE OPERATOR pg_catalog.< (
  PROCEDURE = pgstrom.float42_lt,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >, NEGATOR = >=
);

CREATE OPERATOR pg_catalog.<= (
  PROCEDURE = pgstrom.float42_le,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >=, NEGATOR = >
);

CREATE OPERATOR pg_catalog.> (
  PROCEDURE = pgstrom.float42_gt,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <, NEGATOR = <=
);

CREATE OPERATOR pg_catalog.>= (
  PROCEDURE = pgstrom.float42_ge,
  LEFTARG = pg_catalog.float4,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <=, NEGATOR = <
);


CREATE OPERATOR pg_catalog.= (
  PROCEDURE = pgstrom.float82_eq,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = =, NEGATOR = <>
);

CREATE OPERATOR pg_catalog.<> (
  PROCEDURE = pgstrom.float82_ne,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <>, NEGATOR = =
);

CREATE OPERATOR pg_catalog.< (
  PROCEDURE = pgstrom.float82_lt,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >, NEGATOR = >=
);

CREATE OPERATOR pg_catalog.<= (
  PROCEDURE = pgstrom.float82_le,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = >=, NEGATOR = >
);

CREATE OPERATOR pg_catalog.> (
  PROCEDURE = pgstrom.float82_gt,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <, NEGATOR = <=
);

CREATE OPERATOR pg_catalog.>= (
  PROCEDURE = pgstrom.float82_ge,
  LEFTARG = pg_catalog.float8,
  RIGHTARG = pg_catalog.float2,
  COMMUTATOR = <=, NEGATOR = <
);


CREATE OPERATOR pg_catalog.= (
  PROCEDURE = pgstrom.float24_eq,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = =, NEGATOR = <>
);

CREATE OPERATOR pg_catalog.<> (
  PROCEDURE = pgstrom.float24_ne,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = <>, NEGATOR = =
);

CREATE OPERATOR pg_catalog.< (
  PROCEDURE = pgstrom.float24_lt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = >, NEGATOR = >=
);

CREATE OPERATOR pg_catalog.<= (
  PROCEDURE = pgstrom.float24_le,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = >=, NEGATOR = >
);

CREATE OPERATOR pg_catalog.> (
  PROCEDURE = pgstrom.float24_gt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = <, NEGATOR = <=
);

CREATE OPERATOR pg_catalog.>= (
  PROCEDURE = pgstrom.float24_ge,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float4,
  COMMUTATOR = <=, NEGATOR = <
);


CREATE OPERATOR pg_catalog.= (
  PROCEDURE = pgstrom.float28_eq,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = =, NEGATOR = <>
);

CREATE OPERATOR pg_catalog.<> (
  PROCEDURE = pgstrom.float28_ne,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = <>, NEGATOR = =
);

CREATE OPERATOR pg_catalog.< (
  PROCEDURE = pgstrom.float28_lt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = >, NEGATOR = >=
);

CREATE OPERATOR pg_catalog.<= (
  PROCEDURE = pgstrom.float28_le,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = >=, NEGATOR = >
);

CREATE OPERATOR pg_catalog.> (
  PROCEDURE = pgstrom.float28_gt,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = <, NEGATOR = <=
);

CREATE OPERATOR pg_catalog.>= (
  PROCEDURE = pgstrom.float28_ge,
  LEFTARG = pg_catalog.float2,
  RIGHTARG = pg_catalog.float8,
  COMMUTATOR = <=, NEGATOR = <
);

--
-- Unary operator
--
CREATE FUNCTION pgstrom.float2_up(float2)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float2_up'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_um(float2)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float2_um'
  LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION pgstrom.float2_abs(float2)
  RETURNS float2
  AS 'MODULE_PATHNAME','pgstrom_float2_abs'
  LANGUAGE C STRICT IMMUTABLE;

CREATE OPERATOR pg_catalog.+ (
  PROCEDURE = pgstrom.float2_up,
  RIGHTARG = pg_catalog.float2
);

CREATE OPERATOR pg_catalog.- (
  PROCEDURE = pgstrom.float2_um,
  RIGHTARG = pg_catalog.float2
);

CREATE OPERATOR pg_catalog.@ (
  PROCEDURE = pgstrom.float2_abs,
  RIGHTARG = pg_catalog.float2
);





