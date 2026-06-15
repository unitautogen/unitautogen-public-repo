/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License v3.0 as published
 * by the Free Software Foundation. See the LICENSE file at the repository
 * root for the full text, and COPYRIGHT for the author's notice.
 *
 * Distributed WITHOUT ANY WARRANTY, even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * A separate commercial licence (AGPL-free) is available from the copyright
 * holder. Contact: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

/*=============================================================================
 * MODULE 32 - Predicate seeder (v0.10 predicate-aware seeding)
 * -----------------------------------------------------------------------------
 * Reads one TestGen.PredicateInbox row and emits the T-SQL that, run AFTER the
 * SafeFakeTable calls and BEFORE the Act/EXEC, makes the branch predicate
 * evaluate to a chosen @Direction ('TRUE' or 'FALSE').
 *
 * Single case-analysis procedure - NO strategy registry (design sec 3.3,
 * resolved open Q).  The cases implement DESIGN_v0_10_PredicateSeeding sec 3.2.
 *
 * Reuses the v9.2/v9.4 identity/computed/rowversion exclusion (resolved Q4):
 * INSERT column lists never include identity, computed, or rowversion columns.
 *
 * Bounded by design (resolved Q5): single faked target table; WHERE conjuncts
 * are AND-composed equality / numeric-inequality predicates on that table.
 * Anything outside that grammar returns @Supported = 0 with a reason, which the
 * test generator (module 33) turns into a NOT_TESTABLE placeholder test.
 *===========================================================================*/

SET NOCOUNT ON;
GO

/*-----------------------------------------------------------------------------
 * TestGen.SatisfyingValue
 * Given a comparator and a comparand literal, return a T-SQL literal that
 * (when a column is set to it) makes "<col> <op> <comparand>" evaluate to
 * @Satisfy.  Returns NULL when the (op, literal) pair is outside the supported
 * grammar (e.g. a non-numeric inequality), signalling "unsupported".
 *
 *   '=', '<>', '!=' : supported for ANY literal (numeric or quoted string).
 *   '<','<=','>','>=': supported for NUMERIC literals only.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.SatisfyingValue', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.SatisfyingValue;
GO
CREATE FUNCTION TestGen.SatisfyingValue
(
    @Op      VARCHAR(16),
    @Literal NVARCHAR(400),
    @Satisfy BIT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @op2 VARCHAR(16) = REPLACE(UPPER(LTRIM(RTRIM(@Op))), '!=', '<>');
    DECLARE @num FLOAT       = TRY_CAST(@Literal AS FLOAT);
    DECLARE @isStr BIT       = CASE WHEN LEFT(LTRIM(@Literal),1) IN ('''','N') THEN 1 ELSE 0 END;

    -- A literal guaranteed not to equal a "normal" seeded value.
    DECLARE @diffStr NVARCHAR(64) = N'N''__UAG_NOMATCH__''';

    -- Helper formatting: emit an integer when the number is whole, else float.
    DECLARE @numPlus  NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num + 1 AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num + 1 AS NVARCHAR(50)) END;
    DECLARE @numMinus NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num - 1 AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num - 1 AS NVARCHAR(50)) END;
    DECLARE @numSame  NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num AS NVARCHAR(50)) END;

    IF @op2 = '='
        RETURN CASE WHEN @Satisfy = 1 THEN @Literal
                    WHEN @num IS NOT NULL THEN @numPlus
                    ELSE @diffStr END;

    IF @op2 = '<>'
        RETURN CASE WHEN @Satisfy = 0 THEN @Literal
                    WHEN @num IS NOT NULL THEN @numPlus
                    ELSE @diffStr END;

    -- Numeric inequalities require a numeric comparand.
    IF @num IS NULL RETURN NULL;

    IF @op2 = '>'  RETURN CASE WHEN @Satisfy = 1 THEN @numPlus  ELSE @numSame  END;
    IF @op2 = '>=' RETURN CASE WHEN @Satisfy = 1 THEN @numSame  ELSE @numMinus END;
    IF @op2 = '<'  RETURN CASE WHEN @Satisfy = 1 THEN @numMinus ELSE @numSame  END;
    IF @op2 = '<=' RETURN CASE WHEN @Satisfy = 1 THEN @numSame  ELSE @numPlus  END;

    RETURN NULL;   -- unknown operator
END;
GO

/*-----------------------------------------------------------------------------
 * TestGen.SatisfyAll  (v0.15.2; =/<>/string in v0.15.3)
 * Intersect MULTIPLE comparison constraints on ONE column into a single satisfying
 * value. Used when a column must satisfy several comparisons at once - e.g.
 * a.X > b.Y AND a.X > c.Z (beat BOTH), a.X = b.Y AND a.X = c.Z (equal BOTH),
 * a.X <> b.Y AND a.X <> c.Z (differ from BOTH), or a.X > b.Y AND a.X > 100
 * (column vs another column AND a literal) - which a per-anchor MAX cannot do
 * (and string MAX is lexical: '43' > '101').
 *   @ConstraintsJson = [{"op":">","val":"42","want":1}, {"op":">","val":"100","want":1}]
 *   want=0 violates that op.
 * NUMERIC: lo = max of lower bounds (>,>=), hi = min of upper bounds (<,<=); a
 *   single '=' must fall in [lo,hi] and dodge '<>'; '<>'-only picks above all
 *   exclusions. STRING: a single '=' returns that value, '<>'-only returns a
 *   guaranteed-non-matching sentinel.
 * Returns NULL - caller leaves the column unresolved (honest residue, never a
 * wrong seed) - for an empty intersection (lo > hi), conflicting equalities,
 * a numeric inequality over a string, or any case it cannot satisfy.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.SatisfyAll', 'FN') IS NOT NULL DROP FUNCTION TestGen.SatisfyAll;
GO
CREATE FUNCTION TestGen.SatisfyAll (@ConstraintsJson NVARCHAR(MAX))
RETURNS NVARCHAR(400)
AS
BEGIN
    -- normalize each constraint to want=1, classify numeric vs string.
    DECLARE @c TABLE (op VARCHAR(8), num FLOAT, sval NVARCHAR(400), isnum BIT);
    INSERT @c (op, num, sval, isnum)
    SELECT CASE WHEN w = 1 THEN o
                ELSE CASE o WHEN '>' THEN '<=' WHEN '>=' THEN '<' WHEN '<' THEN '>='
                            WHEN '<=' THEN '>' WHEN '=' THEN '<>' WHEN '<>' THEN '=' ELSE o END END,
           n, v, CASE WHEN n IS NULL THEN 0 ELSE 1 END
    FROM (
        SELECT o = UPPER(LTRIM(RTRIM(JSON_VALUE([value],'$.op')))),
               w = ISNULL(TRY_CAST(JSON_VALUE([value],'$.want') AS BIT), 1),
               n = TRY_CAST(JSON_VALUE([value],'$.val') AS FLOAT),
               v = JSON_VALUE([value],'$.val')
        FROM   OPENJSON(ISNULL(@ConstraintsJson, N'[]'))
    ) x;

    IF NOT EXISTS (SELECT 1 FROM @c) RETURN NULL;

    -- STRING fan: equality / inequality only (no ordering on strings).
    IF EXISTS (SELECT 1 FROM @c WHERE isnum = 0)
    BEGIN
        IF EXISTS (SELECT 1 FROM @c WHERE op IN ('>','>=','<','<=')) RETURN NULL;
        IF (SELECT COUNT(DISTINCT sval) FROM @c WHERE op = '=') > 1 RETURN NULL;
        DECLARE @seq NVARCHAR(400) = (SELECT MIN(sval) FROM @c WHERE op = '=');
        IF @seq IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM @c WHERE op = '<>' AND sval = @seq) RETURN NULL;
            RETURN @seq;
        END;
        IF EXISTS (SELECT 1 FROM @c WHERE op = '<>') RETURN N'N''__UAG_NOMATCH__''';
        RETURN NULL;
    END;

    -- NUMERIC fan.
    IF (SELECT COUNT(DISTINCT num) FROM @c WHERE op = '=') > 1 RETURN NULL;     -- = k1 AND = k2
    DECLARE @lo FLOAT = (SELECT MAX(CASE WHEN op='>' THEN num+1 WHEN op='>=' THEN num END) FROM @c);
    DECLARE @hi FLOAT = (SELECT MIN(CASE WHEN op='<' THEN num-1 WHEN op='<=' THEN num END) FROM @c);
    DECLARE @eq FLOAT = (SELECT MIN(num) FROM @c WHERE op = '=');

    IF @eq IS NOT NULL
    BEGIN
        IF (@lo IS NOT NULL AND @eq < @lo) OR (@hi IS NOT NULL AND @eq > @hi) RETURN NULL;
        IF EXISTS (SELECT 1 FROM @c WHERE op = '<>' AND num = @eq) RETURN NULL;
        RETURN CASE WHEN @eq = FLOOR(@eq) THEN CAST(CAST(@eq AS BIGINT) AS NVARCHAR(50)) ELSE CAST(@eq AS NVARCHAR(50)) END;
    END;

    IF @lo IS NOT NULL AND @hi IS NOT NULL AND @lo > @hi RETURN NULL;           -- empty range

    DECLARE @v FLOAT;
    IF @lo IS NULL AND @hi IS NULL
        SET @v = ISNULL((SELECT MAX(num) + 1 FROM @c WHERE op = '<>'), 0);      -- above all <>, else 0
    ELSE
    BEGIN
        SET @v = COALESCE(@lo, @hi);
        IF EXISTS (SELECT 1 FROM @c WHERE op = '<>' AND num = @v)
        BEGIN
            IF @lo IS NOT NULL
            BEGIN
                SET @v = (SELECT MAX(num) + 1 FROM @c WHERE op = '<>' AND num >= @lo);
                IF @hi IS NOT NULL AND @v > @hi RETURN NULL;
            END
            ELSE
                SET @v = (SELECT MIN(num) - 1 FROM @c WHERE op = '<>' AND num <= @hi);
        END;
    END;
    RETURN CASE WHEN @v = FLOOR(@v) THEN CAST(CAST(@v AS BIGINT) AS NVARCHAR(50))
                ELSE CAST(@v AS NVARCHAR(50)) END;
END;
GO

/*-----------------------------------------------------------------------------
 * TestGen.BuildSeedInsert
 * Build an INSERT that puts @Count identical rows into a faked table.
 *   - Column list excludes identity / computed / rowversion (resolved Q4).
 *   - Each column gets a "typical valid" sample literal, UNLESS overridden by
 *     @OverridesJson, a JSON array of {"col":"<name>","val":"<T-SQL literal>"}.
 *   - @Count = 1 -> single VALUES row; @Count > 1 -> SELECT TOP(@Count) from a
 *     tally so any row multiplicity is expressed without N copies of text.
 * Returns NULL if the table is missing or has no insertable columns.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.BuildSeedInsert', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.BuildSeedInsert;
GO
CREATE FUNCTION TestGen.BuildSeedInsert
(
    @SchemaName    SYSNAME,
    @TableName     SYSNAME,
    @OverridesJson NVARCHAR(MAX),
    @Count         INT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @full NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    DECLARE @objid INT = OBJECT_ID(@full);
    IF @objid IS NULL RETURN NULL;
    IF @Count IS NULL OR @Count < 1 RETURN NULL;

    DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);

    ;WITH ov AS (
        SELECT  col = JSON_VALUE([value], '$.col'),
                val = JSON_VALUE([value], '$.val')
        FROM    OPENJSON(ISNULL(NULLIF(@OverridesJson, N''), N'[]'))
    )
    SELECT
        @cols = STRING_AGG(QUOTENAME(c.name), N', ')
                  WITHIN GROUP (ORDER BY c.column_id),
        @vals = STRING_AGG(
                  CONVERT(NVARCHAR(MAX),
                    ISNULL(ov.val,
                      TestGen.GetSampleValueLiteral(t.name, c.max_length,
                                                    c.precision, c.scale, 0))),
                  N', ')
                  WITHIN GROUP (ORDER BY c.column_id)
    FROM    sys.columns c
    JOIN    sys.types   t ON c.user_type_id = t.user_type_id
    LEFT JOIN ov ON ov.col = c.name
    WHERE   c.object_id = @objid
      AND   ( ov.val IS NOT NULL          -- a WHERE/scalar override needs this column,
                                          -- e.g. an IDENTITY PK the gate filters on:
                                          -- tSQLt.FakeTable drops identity/computed/
                                          -- rowversion, so the faked table accepts an
                                          -- explicit insert into it. Include it.
              OR ( c.is_identity = 0 AND c.is_computed = 0
                   AND t.name NOT IN ('timestamp','rowversion') ) );

    IF @cols IS NULL RETURN NULL;

    IF @Count = 1
        RETURN N'INSERT ' + @full + N' (' + @cols + N')' + CHAR(13) + CHAR(10)
             + N'    VALUES (' + @vals + N');';

    -- @Count > 1: pull exactly @Count rows from a guaranteed-large tally.
    RETURN N'INSERT ' + @full + N' (' + @cols + N')' + CHAR(13) + CHAR(10)
         + N'    SELECT TOP (' + CAST(@Count AS NVARCHAR(10)) + N') '
         + @vals + CHAR(13) + CHAR(10)
         + N'    FROM sys.all_columns a CROSS JOIN sys.all_columns b;';
END;
GO

/*=============================================================================
 * v0.12 UNIFIED ENGINE helpers (design/DESIGN_v0_12_UnifiedReverseSeeder.md)
 *   TestGen.CountForCase   - rows the base table needs for an atom's comparator
 *   TestGen.ResolveVspec   - symbolic value spec -> a concrete T-SQL literal
 *   TestGen.ExecuteSeedPlan- run a per-direction per-table seed plan
 *===========================================================================*/
IF OBJECT_ID('TestGen.CountForCase', 'FN') IS NOT NULL DROP FUNCTION TestGen.CountForCase;
GO
CREATE FUNCTION TestGen.CountForCase
(
    @shape      VARCHAR(32),
    @comparator VARCHAR(16),
    @comparand  NVARCHAR(MAX),   -- already param-resolved literal / list
    @want       BIT
)
RETURNS INT
AS
BEGIN
    -- Rows the base table needs so the atom evaluates to @want. NULL = degenerate
    -- / unsupported (caller turns that into a Skip). A negative result is also
    -- degenerate (cannot make a count negative).
    DECLARE @op VARCHAR(16) = REPLACE(UPPER(ISNULL(@comparator, '')), '!=', '<>');
    DECLARE @K INT = NULL;

    IF @shape = 'EXISTS'
        SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    ELSE IF @shape = 'SCALAR_NULL'
    BEGIN
        IF      @op = 'IS_NULL'     SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;
        ELSE IF @op = 'IS_NOT_NULL' SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    END
    ELSE IF @shape IN ('SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP','SCALAR_CMP')
        SET @K = 1;                                  -- one row; the value override drives it
    ELSE IF @shape = 'COUNT_CMP'
    BEGIN
        DECLARE @N FLOAT = TRY_CAST(@comparand AS FLOAT);
        IF @N IS NOT NULL AND @N = FLOOR(@N)
        BEGIN
            DECLARE @Ni INT = CAST(@N AS INT);
            IF      @op = '='  SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni + 1 END;
            ELSE IF @op = '<>' SET @K = CASE WHEN @want = 1 THEN @Ni + 1 ELSE @Ni     END;
            ELSE IF @op = '>'  SET @K = CASE WHEN @want = 1 THEN @Ni + 1 ELSE @Ni     END;
            ELSE IF @op = '>=' SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni - 1 END;
            ELSE IF @op = '<'  SET @K = CASE WHEN @want = 1 THEN @Ni - 1 ELSE @Ni     END;
            ELSE IF @op = '<=' SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni + 1 END;
        END
    END
    ELSE IF @shape = 'COUNT_IN'
    BEGIN
        DECLARE @first INT, @maxv INT, @bad INT = 0;
        SELECT  @first = MIN(CASE WHEN ord = 1 THEN v END),
                @maxv  = MAX(v),
                @bad   = SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END)
        FROM ( SELECT TRY_CAST(LTRIM(RTRIM([value])) AS INT) AS v,
                      ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS ord
               FROM   STRING_SPLIT(ISNULL(@comparand, N''), ',') ) s;
        IF @bad = 0 AND @first IS NOT NULL
        BEGIN
            IF @op = 'NOT_IN' SET @K = CASE WHEN @want = 1 THEN @maxv + 1 ELSE @first END;
            ELSE              SET @K = CASE WHEN @want = 1 THEN @first    ELSE @maxv + 1 END;
        END
    END
    ELSE IF @shape = 'COUNT_BETWEEN'
    BEGIN
        DECLARE @up NVARCHAR(MAX) = UPPER(@comparand);
        DECLARE @ap INT = CHARINDEX(' AND ', @up);
        IF @ap > 0
        BEGIN
            DECLARE @A INT = TRY_CAST(LTRIM(RTRIM(LEFT(@comparand, @ap - 1))) AS INT);
            DECLARE @B INT = TRY_CAST(LTRIM(RTRIM(SUBSTRING(@comparand, @ap + 5, 4000))) AS INT);
            IF @A IS NOT NULL AND @B IS NOT NULL
                SET @K = CASE WHEN @want = 1 THEN @A
                              WHEN @A >= 1   THEN @A - 1
                              ELSE @B + 1 END;
        END
    END;

    IF @K < 0 SET @K = NULL;     -- degenerate (e.g. COUNT < 0)
    RETURN @K;
END;
GO

IF OBJECT_ID('TestGen.ResolveVspec', 'FN') IS NOT NULL DROP FUNCTION TestGen.ResolveVspec;
GO
CREATE FUNCTION TestGen.ResolveVspec
(
    @vspec   NVARCHAR(MAX),
    @procObj INT,
    @objid   INT,
    @col     SYSNAME
)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @vspec IS NULL OR ISJSON(@vspec) = 0 RETURN NULL;

    -- { "lit": <literal> }
    IF JSON_VALUE(@vspec, '$.lit') IS NOT NULL
        RETURN JSON_VALUE(@vspec, '$.lit');

    -- { "param": "@Name" } -> the proc-parameter sample value
    DECLARE @p NVARCHAR(200) = JSON_VALUE(@vspec, '$.param');
    IF @p IS NOT NULL
    BEGIN
        DECLARE @pv NVARCHAR(400) = NULL;
        SELECT @pv = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
        WHERE  pr.object_id = @procObj AND pr.name = @p;
        RETURN @pv;
    END;

    -- { "sample": true } -> a typed sample of the target column
    IF JSON_VALUE(@vspec, '$.sample') IS NOT NULL
    BEGIN
        DECLARE @sv NVARCHAR(400) = NULL;
        SELECT @sv = TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0)
        FROM   sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE  c.object_id = @objid AND c.name = @col;
        RETURN @sv;
    END;

    -- { "satisfy": { op, val, valKind, want } }
    DECLARE @sat NVARCHAR(MAX) = JSON_QUERY(@vspec, '$.satisfy');
    IF @sat IS NOT NULL
    BEGIN
        DECLARE @op  VARCHAR(8)     = JSON_VALUE(@sat, '$.op');
        DECLARE @val NVARCHAR(400)  = JSON_VALUE(@sat, '$.val');
        DECLARE @vk  VARCHAR(16)    = JSON_VALUE(@sat, '$.valKind');
        DECLARE @w   BIT            = TRY_CAST(JSON_VALUE(@sat, '$.want') AS BIT);
        IF @vk = 'param'
            SELECT @val = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  pr.object_id = @procObj AND pr.name = @val;
        RETURN TestGen.SatisfyingValue(@op, @val, @w);
    END;

    -- { "satisfysample": { op, want } } -> SatisfyingValue against THIS column's
    -- own typed sample. For a non-equi join a.x <op> b.y, b.y gets {sample} and
    -- a.x gets this; same column type -> same sample -> a.x <op> b.y holds.
    DECLARE @ss NVARCHAR(MAX) = JSON_QUERY(@vspec, '$.satisfysample');
    IF @ss IS NOT NULL
    BEGIN
        DECLARE @ssop VARCHAR(8) = JSON_VALUE(@ss, '$.op');
        DECLARE @ssw  BIT        = TRY_CAST(JSON_VALUE(@ss, '$.want') AS BIT);
        DECLARE @ssrv NVARCHAR(400) = NULL;
        SELECT @ssrv = TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0)
        FROM   sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE  c.object_id = @objid AND c.name = @col;
        RETURN TestGen.SatisfyingValue(@ssop, @ssrv, @ssw);
    END;

    -- { "satisfyother": { op, want, oschema, otable, ocol } } (v0.15.0)
    -- Cross-column WHERE a.x <op> b.y: derive THIS column's value from the OTHER
    -- column's typed sample, so a.x <op> b.y holds regardless of the two types.
    DECLARE @soj NVARCHAR(MAX) = JSON_QUERY(@vspec, '$.satisfyother');
    IF @soj IS NOT NULL
    BEGIN
        DECLARE @soop VARCHAR(8) = JSON_VALUE(@soj, '$.op');
        DECLARE @sow  BIT        = TRY_CAST(JSON_VALUE(@soj, '$.want') AS BIT);
        DECLARE @ooid INT = OBJECT_ID(QUOTENAME(JSON_VALUE(@soj, '$.oschema')) + N'.' + QUOTENAME(JSON_VALUE(@soj, '$.otable')));
        DECLARE @ocol SYSNAME = JSON_VALUE(@soj, '$.ocol');
        DECLARE @obase NVARCHAR(400) = NULL;
        SELECT @obase = TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0)
        FROM   sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE  c.object_id = @ooid AND c.name = @ocol;
        RETURN TestGen.SatisfyingValue(@soop, @obase, @sow);
    END;

    RETURN NULL;
END;
GO

IF OBJECT_ID('TestGen.OverridesContain', 'FN') IS NOT NULL DROP FUNCTION TestGen.OverridesContain;
GO
CREATE FUNCTION TestGen.OverridesContain
(
    @super NVARCHAR(MAX),   -- resolved override array [{col,val}...]
    @sub   NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    -- 1 when every (col,val) in @sub also appears in @super (i.e. a row carrying
    -- @super's overrides also satisfies @sub's predicate).
    IF @sub IS NULL OR @sub = N'[]' RETURN 1;
    IF EXISTS (
        SELECT 1
        FROM   OPENJSON(@sub) s
        WHERE  NOT EXISTS (
            SELECT 1 FROM OPENJSON(ISNULL(@super, N'[]')) u
            WHERE  JSON_VALUE(u.[value], '$.col') = JSON_VALUE(s.[value], '$.col')
              AND  JSON_VALUE(u.[value], '$.val') = JSON_VALUE(s.[value], '$.val') )
    ) RETURN 0;
    RETURN 1;
END;
GO

IF OBJECT_ID('TestGen.ExecuteSeedPlan', 'P') IS NOT NULL DROP PROCEDURE TestGen.ExecuteSeedPlan;
GO
CREATE PROCEDURE TestGen.ExecuteSeedPlan
    @Direction    VARCHAR(8),
    @ProcSchema   SYSNAME,
    @ProcName     SYSNAME,
    @PlanTrue     NVARCHAR(MAX),
    @PlanFalse    NVARCHAR(MAX),
    @PredText     NVARCHAR(MAX),
    @SeedSql      NVARCHAR(MAX) = NULL OUTPUT,
    @Supported    BIT           = NULL OUTPUT,
    @Reason       NVARCHAR(400) = NULL OUTPUT,
    @PredicateSql NVARCHAR(MAX) = NULL OUTPUT,
    @ExpectedBit  BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @SeedSql = NULL; SET @Supported = 0; SET @Reason = NULL;
    SET @PredicateSql = NULL; SET @ExpectedBit = NULL;

    DECLARE @MaxSeedRows INT = 500;
    DECLARE @plan NVARCHAR(MAX) = CASE WHEN UPPER(@Direction) = 'TRUE' THEN @PlanTrue ELSE @PlanFalse END;
    IF @plan IS NULL OR ISJSON(@plan) = 0
    BEGIN SET @Reason = N'no seed plan for direction ' + @Direction; RETURN; END;

    SET @PredicateSql = JSON_VALUE(@plan, '$.predSql');
    SET @ExpectedBit  = TRY_CAST(JSON_VALUE(@plan, '$.expectedBit') AS BIT);
    DECLARE @skip NVARCHAR(MAX) = JSON_VALUE(@plan, '$.skip');
    IF @skip IS NOT NULL BEGIN SET @Reason = LEFT(@skip, 400); RETURN; END;

    DECLARE @procObj INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName));

    -- Resolve @param tokens in the assertion predicate to their sample literals
    -- (longest name first so @Order does not clobber @OrderId).
    IF @PredicateSql IS NOT NULL AND @procObj IS NOT NULL
    BEGIN
        DECLARE @pn SYSNAME, @pv NVARCHAR(400);
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
            SELECT pr.name, TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  pr.object_id = @procObj AND pr.name <> N''
            ORDER  BY LEN(pr.name) DESC;
        OPEN pc; FETCH NEXT FROM pc INTO @pn, @pv;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @pv IS NOT NULL SET @PredicateSql = REPLACE(@PredicateSql, @pn, @pv);
            FETCH NEXT FROM pc INTO @pn, @pv;
        END;
        CLOSE pc; DEALLOCATE pc;
    END;

    -- Walk the per-table plan. Each table carries one or more demands (two atoms,
    -- or a self-join's two aliases). Reconcile them greedily, most-specific demand
    -- first: a more-specific row already counts toward a broader demand, so a
    -- COUNT total is back-filled and an over-constrained EXACT/MAX demand is a
    -- genuine contradiction (-> honest Skip). The strong assertion is the backstop.
    DECLARE @seed NVARCHAR(MAX) = N'';
    DECLARE @ovt  TABLE (col SYSNAME, val NVARCHAR(400));
    DECLARE @demT TABLE (idx INT IDENTITY(1,1), K INT, ovJson NVARCHAR(MAX), spec INT, mode VARCHAR(8));
    DECLARE @emit TABLE (idx INT IDENTITY(1,1), ovJson NVARCHAR(MAX), n INT);
    DECLARE @tsch SYSNAME, @ttbl SYSNAME, @tdemands NVARCHAR(MAX);
    DECLARE @objid INT, @ins NVARCHAR(MAX);
    DECLARE @dkspec NVARCHAR(MAX), @dcount NVARCHAR(20), @dov NVARCHAR(MAX);
    DECLARE @K INT, @kshape VARCHAR(32), @kcmp VARCHAR(16), @kcd NVARCHAR(MAX), @kwant BIT, @mode VARCHAR(8), @spec INT, @dovJson NVARCHAR(MAX);
    DECLARE @dK INT, @dmode VARCHAR(8), @satisfied INT, @need INT, @eOv NVARCHAR(MAX), @eN INT, @tot INT;

    -- ============================================================
    -- v0.15.1: cross-column value propagation (transitive chains).
    -- Resolve every override's value GLOBALLY, in dependency order, so a
    -- {satisfyother} column derives from its anchor column's ACTUAL resolved
    -- value rather than a generic type sample. This makes transitive chains
    -- (a.x > b.y AND b.y > c.z) seed correctly: c.z is sampled, b.y is derived to
    -- beat c.z, then a.x is derived to beat b.y's ACTUAL value. A column that is
    -- both an anchor and constrained (carries {sample} AND {satisfyother}) takes
    -- the constrained value. A true cycle (contradiction: a.x>b.y AND b.y>a.x)
    -- never resolves and falls back to the anchor's TYPE sample - the pre-v0.15.1
    -- behaviour - so the impossible arm stays honestly uncovered, never faked.
    -- @cc_chosen[fullcol] becomes the authoritative value the emit loop uses.
    -- ============================================================
    DECLARE @cc_spec TABLE (fullcol NVARCHAR(400), col SYSNAME, isOther BIT,
                            op VARCHAR(8), want BIT, anchor NVARCHAR(400), oobjid INT, ocol NVARCHAR(128),
                            litImm NVARCHAR(400));
    DECLARE @cc_chosen TABLE (fullcol NVARCHAR(400) PRIMARY KEY, lit NVARCHAR(400));
    DECLARE @cc_next   TABLE (fullcol NVARCHAR(400) PRIMARY KEY, v NVARCHAR(400));
    DECLARE @cc_rounds INT = 0, @cc_changed INT = 1;

    ;WITH cc_tbls AS (
        SELECT JSON_VALUE(t.[value],'$.schema') sch, JSON_VALUE(t.[value],'$.table') tbl, t.[value] tval
        FROM   OPENJSON(@plan,'$.tables') t
    ),
    cc_ovs AS (
        SELECT b.sch, b.tbl, JSON_VALUE(o.[value],'$.col') col, JSON_QUERY(o.[value],'$.vspec') vspec
        FROM   cc_tbls b
        CROSS APPLY OPENJSON(b.tval,'$.demands') d
        CROSS APPLY OPENJSON(JSON_QUERY(d.[value],'$.overrides')) o
    )
    INSERT @cc_spec (fullcol, col, isOther, op, want, anchor, oobjid, ocol, litImm)
    SELECT LOWER(sch+N'.'+tbl+N'.'+col), col,
           CASE WHEN JSON_QUERY(vspec,'$.satisfyother') IS NOT NULL THEN 1 ELSE 0 END,
           JSON_VALUE(vspec,'$.satisfyother.op'),
           TRY_CAST(JSON_VALUE(vspec,'$.satisfyother.want') AS BIT),
           LOWER(JSON_VALUE(vspec,'$.satisfyother.oschema')+N'.'+JSON_VALUE(vspec,'$.satisfyother.otable')+N'.'+JSON_VALUE(vspec,'$.satisfyother.ocol')),
           OBJECT_ID(QUOTENAME(JSON_VALUE(vspec,'$.satisfyother.oschema'))+N'.'+QUOTENAME(JSON_VALUE(vspec,'$.satisfyother.otable'))),
           JSON_VALUE(vspec,'$.satisfyother.ocol'),
           CASE WHEN JSON_QUERY(vspec,'$.satisfyother') IS NULL
                THEN TestGen.ResolveVspec(vspec, @procObj, OBJECT_ID(QUOTENAME(sch)+N'.'+QUOTENAME(tbl)), col)
                ELSE NULL END
    FROM   cc_ovs
    WHERE  col IS NOT NULL;

    -- v0.15.3: capture {satisfy} literal/param comparisons as constraints too, so a
    -- column compared to BOTH another column and a literal (a.X > b.Y AND a.X > 100)
    -- intersects them, rather than letting the satisfyother overwrite the literal.
    DECLARE @cc_cmp TABLE (fullcol NVARCHAR(400), op VARCHAR(8), want BIT, cval NVARCHAR(400));
    ;WITH cc_tbls AS (
        SELECT JSON_VALUE(t.[value],'$.schema') sch, JSON_VALUE(t.[value],'$.table') tbl, t.[value] tval
        FROM   OPENJSON(@plan,'$.tables') t
    ),
    cc_ovs AS (
        SELECT b.sch, b.tbl, JSON_VALUE(o.[value],'$.col') col, JSON_QUERY(o.[value],'$.vspec') vspec
        FROM   cc_tbls b
        CROSS APPLY OPENJSON(b.tval,'$.demands') d
        CROSS APPLY OPENJSON(JSON_QUERY(d.[value],'$.overrides')) o
    )
    INSERT @cc_cmp (fullcol, op, want, cval)
    SELECT LOWER(sch+N'.'+tbl+N'.'+col),
           JSON_VALUE(vspec,'$.satisfy.op'),
           ISNULL(TRY_CAST(JSON_VALUE(vspec,'$.satisfy.want') AS BIT), 1),
           CASE WHEN JSON_VALUE(vspec,'$.satisfy.valKind') = 'param'
                THEN (SELECT TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
                      FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
                      WHERE  pr.object_id = @procObj AND pr.name = JSON_VALUE(vspec,'$.satisfy.val'))
                ELSE JSON_VALUE(vspec,'$.satisfy.val') END
    FROM   cc_ovs
    WHERE  col IS NOT NULL AND JSON_QUERY(vspec,'$.satisfy') IS NOT NULL;

    -- round 0: the non-satisfyother (lit/param/sample) values
    INSERT @cc_chosen (fullcol, lit)
    SELECT fullcol, MAX(litImm) FROM @cc_spec WHERE isOther = 0 GROUP BY fullcol;

    -- relaxation: derive each satisfyother value from its (chosen) anchor until stable
    WHILE @cc_changed = 1 AND @cc_rounds < 64
    BEGIN
        SET @cc_rounds += 1;
        DELETE FROM @cc_next;
        -- resolve a satisfyother column only when ALL its anchors are chosen;
        -- single anchor -> SatisfyingValue (unchanged); multiple anchors ->
        -- SatisfyAll numeric intersection (NULL -> leave for the cycle fallback).
        ;WITH oan AS (   -- satisfyother rows + anchor readiness
            SELECT s.fullcol, s.op, s.want, ca.lit AS aval,
                   ocnt = COUNT(*)          OVER (PARTITION BY s.fullcol),
                   ordy = COUNT(ca.fullcol) OVER (PARTITION BY s.fullcol)
            FROM   @cc_spec s
            LEFT JOIN @cc_chosen ca ON ca.fullcol = s.anchor
            WHERE  s.isOther = 1
        ),
        ready AS ( SELECT DISTINCT fullcol FROM oan WHERE ocnt = ordy ),
        hard AS (   -- total hard constraints on a ready column: satisfyother + satisfy
            SELECT r.fullcol,
                   n = (SELECT COUNT(*) FROM @cc_spec s2 WHERE s2.fullcol = r.fullcol AND s2.isOther = 1)
                     + (SELECT COUNT(*) FROM @cc_cmp  m2 WHERE m2.fullcol = r.fullcol)
            FROM   ready r
        )
        INSERT @cc_next (fullcol, v)
        SELECT z.fullcol, z.v FROM (
            SELECT h.fullcol,
                   v = CASE WHEN h.n = 1
                            -- single satisfyother, no literal -> original fast path
                            THEN (SELECT MAX(TestGen.SatisfyingValue(o.op, o.aval, o.want))
                                  FROM oan o WHERE o.fullcol = h.fullcol)
                            -- 2+ constraints (multi-anchor, or anchor + literal) -> intersect
                            ELSE TestGen.SatisfyAll((
                                  SELECT op, want, val FROM (
                                      SELECT o.op AS op, o.want AS want, o.aval AS val
                                      FROM   oan o WHERE o.fullcol = h.fullcol
                                      UNION ALL
                                      SELECT m.op, m.want, m.cval
                                      FROM   @cc_cmp m WHERE m.fullcol = h.fullcol
                                  ) q FOR JSON PATH)) END
            FROM   hard h
        ) z
        WHERE  z.v IS NOT NULL;

        SET @cc_changed = CASE WHEN EXISTS (
            SELECT 1 FROM @cc_next n LEFT JOIN @cc_chosen c ON c.fullcol = n.fullcol
            WHERE c.fullcol IS NULL OR ISNULL(c.lit, N'<<uagx>>') <> ISNULL(n.v, N'<<uagx>>')
        ) THEN 1 ELSE 0 END;

        UPDATE c SET c.lit = n.v
        FROM   @cc_chosen c JOIN @cc_next n ON n.fullcol = c.fullcol
        WHERE  ISNULL(c.lit, N'<<uagx>>') <> ISNULL(n.v, N'<<uagx>>');

        INSERT @cc_chosen (fullcol, lit)
        SELECT n.fullcol, n.v FROM @cc_next n
        WHERE  NOT EXISTS (SELECT 1 FROM @cc_chosen c WHERE c.fullcol = n.fullcol);
    END;

    -- cycle fallback: a satisfyother col still unresolved (its anchor never resolved
    -- = a contradiction/cycle) derives from the anchor column's TYPE sample - the
    -- pre-v0.15.1 best-effort. If that cannot satisfy, the branch stays honestly
    -- uncovered (no phantom pass), exactly as a contradiction should.
    INSERT @cc_chosen (fullcol, lit)
    SELECT s.fullcol, MAX(TestGen.SatisfyingValue(s.op,
               TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0), s.want))
    FROM   @cc_spec s
    JOIN   sys.columns c ON c.object_id = s.oobjid AND c.name = s.ocol
    JOIN   sys.types   t ON t.user_type_id = c.user_type_id
    WHERE  s.isOther = 1
      AND  NOT EXISTS (SELECT 1 FROM @cc_chosen ch WHERE ch.fullcol = s.fullcol)
    GROUP  BY s.fullcol;

    DECLARE tc CURSOR LOCAL FAST_FORWARD FOR
        SELECT JSON_VALUE([value], '$.schema'), JSON_VALUE([value], '$.table'), JSON_QUERY([value], '$.demands')
        FROM   OPENJSON(@plan, '$.tables');
    OPEN tc; FETCH NEXT FROM tc INTO @tsch, @ttbl, @tdemands;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @objid = OBJECT_ID(QUOTENAME(@tsch) + N'.' + QUOTENAME(@ttbl));
        IF @objid IS NULL
        BEGIN SET @Reason = N'tree target table not found: ' + @tsch + N'.' + @ttbl; CLOSE tc; DEALLOCATE tc; RETURN; END;

        -- 1. resolve each demand of this table into (K, resolved overrides, mode)
        DELETE FROM @demT;
        DECLARE ddc CURSOR LOCAL FAST_FORWARD FOR
            SELECT JSON_QUERY([value], '$.kspec'), JSON_VALUE([value], '$.count'), JSON_QUERY([value], '$.overrides')
            FROM   OPENJSON(ISNULL(@tdemands, N'[]'));
        OPEN ddc; FETCH NEXT FROM ddc INTO @dkspec, @dcount, @dov;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @dkspec IS NOT NULL
            BEGIN
                SET @kshape = JSON_VALUE(@dkspec, '$.shape');
                SET @kcmp   = JSON_VALUE(@dkspec, '$.comparator');
                SET @kcd    = JSON_VALUE(@dkspec, '$.comparand');
                SET @kwant  = TRY_CAST(JSON_VALUE(@dkspec, '$.want') AS BIT);
                IF @kcd LIKE '@%'
                    SELECT @kcd = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
                    FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
                    WHERE  pr.object_id = @procObj AND pr.name = @kcd;
                SET @K = TestGen.CountForCase(@kshape, @kcmp, @kcd, @kwant);
                IF @K IS NULL
                BEGIN SET @Reason = N'degenerate/unsupported count: ' + @kshape + N' ' + ISNULL(@kcmp, N''); CLOSE ddc; DEALLOCATE ddc; CLOSE tc; DEALLOCATE tc; RETURN; END;
                -- Effective row-count constraint (mode) DEPENDS on @kwant: e.g.
                -- "COUNT > 0" wanted FALSE means "<= 0 rows" (a MAX/upper bound).
                SET @mode = CASE
                    WHEN @kshape = 'EXISTS'      THEN CASE WHEN @kwant = 1 THEN 'min' ELSE 'max' END
                    WHEN @kshape = 'SCALAR_NULL' THEN 'exact'
                    WHEN @kshape IN ('COUNT_IN','COUNT_BETWEEN') THEN 'exact'
                    WHEN @kshape = 'COUNT_CMP' THEN
                         CASE @kcmp
                             WHEN '='  THEN CASE WHEN @kwant = 1 THEN 'exact' ELSE 'min' END
                             WHEN '<>' THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'exact' END
                             WHEN '>'  THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'max' END
                             WHEN '>=' THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'max' END
                             WHEN '<'  THEN CASE WHEN @kwant = 1 THEN 'max'   ELSE 'min' END
                             WHEN '<=' THEN CASE WHEN @kwant = 1 THEN 'max'   ELSE 'min' END
                             ELSE 'min' END
                    ELSE 'min' END;   -- SUM/MIN/MAX/AVG/SCALAR_CMP: one value-driven row
            END
            ELSE
            BEGIN SET @K = TRY_CAST(@dcount AS INT); SET @mode = 'min'; END;
            IF @K IS NULL SET @K = 0;

            DELETE FROM @ovt;
            -- v0.15.1: use the globally propagated value (@cc_chosen) so cross-column
            -- chains resolve; fall back to per-column ResolveVspec defensively.
            INSERT @ovt (col, val)
            SELECT JSON_VALUE(o.[value], '$.col'),
                   ISNULL(ch.lit,
                          TestGen.ResolveVspec(JSON_QUERY(o.[value], '$.vspec'), @procObj, @objid, JSON_VALUE(o.[value], '$.col')))
            FROM   OPENJSON(ISNULL(@dov, N'[]')) o
            LEFT  JOIN @cc_chosen ch ON ch.fullcol = LOWER(@tsch + N'.' + @ttbl + N'.' + JSON_VALUE(o.[value], '$.col'));
            SET @dovJson = ISNULL((SELECT col AS [col], MAX(val) AS [val] FROM @ovt GROUP BY col FOR JSON PATH), N'[]');
            SET @spec = (SELECT COUNT(DISTINCT col) FROM @ovt);
            INSERT @demT (K, ovJson, spec, mode) VALUES (@K, @dovJson, @spec, @mode);

            FETCH NEXT FROM ddc INTO @dkspec, @dcount, @dov;
        END;
        CLOSE ddc; DEALLOCATE ddc;

        -- 2. greedy reconcile, most-specific first
        DELETE FROM @emit;
        DECLARE dc2 CURSOR LOCAL FAST_FORWARD FOR SELECT K, ovJson, mode FROM @demT ORDER BY spec DESC, idx;
        OPEN dc2; FETCH NEXT FROM dc2 INTO @dK, @dovJson, @dmode;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @satisfied = ISNULL((SELECT SUM(n) FROM @emit WHERE TestGen.OverridesContain(ovJson, @dovJson) = 1), 0);
            IF @dmode IN ('exact','max') AND @satisfied > @dK
            BEGIN
                SET @Reason = N'unsatisfiable predicate on ' + @tsch + N'.' + @ttbl
                            + N' (needs ' + CAST(@dK AS NVARCHAR(12)) + N' rows but '
                            + CAST(@satisfied AS NVARCHAR(12)) + N' already required)';
                CLOSE dc2; DEALLOCATE dc2; CLOSE tc; DEALLOCATE tc; RETURN;
            END;
            SET @need = @dK - @satisfied;
            IF @need > 0 INSERT @emit (ovJson, n) VALUES (@dovJson, @need);
            FETCH NEXT FROM dc2 INTO @dK, @dovJson, @dmode;
        END;
        CLOSE dc2; DEALLOCATE dc2;

        -- 2b. validate EXACT/MAX demands against the FINAL row set (a later
        -- min-demand may have added rows a max/exact demand cannot tolerate ->
        -- genuine contradiction / unreachable arm -> honest Skip).
        DECLARE vc CURSOR LOCAL FAST_FORWARD FOR SELECT K, ovJson, mode FROM @demT WHERE mode IN ('exact','max');
        OPEN vc; FETCH NEXT FROM vc INTO @dK, @dovJson, @dmode;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @tot = ISNULL((SELECT SUM(n) FROM @emit WHERE TestGen.OverridesContain(ovJson, @dovJson) = 1), 0);
            IF (@dmode = 'max' AND @tot > @dK) OR (@dmode = 'exact' AND @tot <> @dK)
            BEGIN
                SET @Reason = N'unsatisfiable predicate on ' + @tsch + N'.' + @ttbl
                            + N' (needs ' + @dmode + N' ' + CAST(@dK AS NVARCHAR(12))
                            + N' rows but ' + CAST(@tot AS NVARCHAR(12)) + N' present)';
                CLOSE vc; DEALLOCATE vc; CLOSE tc; DEALLOCATE tc; RETURN;
            END;
            FETCH NEXT FROM vc INTO @dK, @dovJson, @dmode;
        END;
        CLOSE vc; DEALLOCATE vc;

        IF (SELECT ISNULL(SUM(n), 0) FROM @emit) > @MaxSeedRows
        BEGIN SET @Reason = N'seed row count exceeds cap on ' + @tsch + N'.' + @ttbl; CLOSE tc; DEALLOCATE tc; RETURN; END;

        -- 3. emit one INSERT per reconciled row-group
        DECLARE ec CURSOR LOCAL FAST_FORWARD FOR SELECT ovJson, n FROM @emit ORDER BY idx;
        OPEN ec; FETCH NEXT FROM ec INTO @eOv, @eN;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ins = TestGen.BuildSeedInsert(@tsch, @ttbl, @eOv, @eN);
            IF @ins IS NULL
            BEGIN SET @Reason = N'tree target ' + @tsch + N'.' + @ttbl + N' not insertable'; CLOSE ec; DEALLOCATE ec; CLOSE tc; DEALLOCATE tc; RETURN; END;
            SET @seed = @seed + N'    ' + @ins + CHAR(13) + CHAR(10);
            FETCH NEXT FROM ec INTO @eOv, @eN;
        END;
        CLOSE ec; DEALLOCATE ec;

        FETCH NEXT FROM tc INTO @tsch, @ttbl, @tdemands;
    END;
    CLOSE tc; DEALLOCATE tc;

    SET @SeedSql = N'    -- v0.12 ' + @Direction + N' seed for: ' + REPLACE(REPLACE(REPLACE(LEFT(@PredText, 200), CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ') + CHAR(13) + CHAR(10)
                 + CASE WHEN @seed = N'' THEN N'    -- (faked tables left empty for this direction)' ELSE @seed END;
    SET @Supported = 1;
END;
GO

/*-----------------------------------------------------------------------------
 * TestGen.SatisfyPredicate
 * The single case-analysis seeder.  Given a PredicateInbox row (@InboxId) and a
 * @Direction ('TRUE' / 'FALSE'), produce the seed T-SQL (@SeedSql).
 *   @Supported = 1 -> @SeedSql is the seed block (possibly an empty-table
 *                     comment when the satisfying state is "leave it empty").
 *   @Supported = 0 -> @Reason explains why; module 33 emits NOT_TESTABLE.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.SatisfyPredicate', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.SatisfyPredicate;
GO
CREATE PROCEDURE TestGen.SatisfyPredicate
    @InboxId    INT,
    @Direction  VARCHAR(8),                 -- 'TRUE' | 'FALSE'
    @SeedSql    NVARCHAR(MAX) = NULL OUTPUT,
    @Supported  BIT           = NULL OUTPUT,
    @Reason     NVARCHAR(400) = NULL OUTPUT,
    @PredicateSql NVARCHAR(MAX) = NULL OUTPUT,   -- gate boolean, params resolved (strong assertion)
    @ExpectedBit  BIT          = NULL OUTPUT     -- 1 if @Direction makes the gate TRUE, else 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @SeedSql   = NULL;
    SET @Supported = 0;
    SET @Reason    = NULL;
    SET @PredicateSql = NULL;
    DECLARE @whereSql NVARCHAR(MAX) = NULL;

    DECLARE @want BIT = CASE WHEN UPPER(@Direction) = 'TRUE' THEN 1 ELSE 0 END;
    DECLARE @MaxSeedRows INT = 500;

    DECLARE @Shape VARCHAR(32), @Comparator VARCHAR(16), @Comparand NVARCHAR(MAX),
            @AggCol NVARCHAR(256), @TablesJson NVARCHAR(MAX), @WhereJson NVARCHAR(MAX),
            @JoinsJson NVARCHAR(MAX),
            @PredTreeJson NVARCHAR(MAX), @SeedPlanTrue NVARCHAR(MAX), @SeedPlanFalse NVARCHAR(MAX),
            @PredText NVARCHAR(MAX), @ProcSchema SYSNAME, @ProcName2 SYSNAME;

    SELECT @Shape = Shape, @Comparator = Comparator, @Comparand = Comparand,
           @AggCol = AggregateColumn, @TablesJson = TargetTablesJson,
           @WhereJson = WhereAstJson, @JoinsJson = JoinsJson,
           @PredTreeJson = PredicateTreeJson, @SeedPlanTrue = SeedPlanTrueJson,
           @SeedPlanFalse = SeedPlanFalseJson, @PredText = PredicateText,
           @ProcSchema = SchemaName, @ProcName2 = ProcName
    FROM   TestGen.PredicateInbox
    WHERE  InboxId = @InboxId;

    IF @@ROWCOUNT = 0
    BEGIN
        SET @Reason = N'PredicateInbox row not found (InboxId ' + CAST(@InboxId AS NVARCHAR(12)) + N').';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- v0.12 UNIFIED TREE PATH. When the parser emitted a predicate tree, the
    -- per-direction seed plan is authoritative; execute it and return. The flat
    -- (v0.10/v0.11) paths below remain as a one-release fallback.
    -- (design/DESIGN_v0_12_UnifiedReverseSeeder.md)
    --------------------------------------------------------------------------
    IF @PredTreeJson IS NOT NULL AND ISJSON(@PredTreeJson) = 1
    BEGIN
        EXEC TestGen.ExecuteSeedPlan
             @Direction = @Direction, @ProcSchema = @ProcSchema, @ProcName = @ProcName2,
             @PlanTrue = @SeedPlanTrue, @PlanFalse = @SeedPlanFalse, @PredText = @PredText,
             @SeedSql = @SeedSql OUTPUT, @Supported = @Supported OUTPUT, @Reason = @Reason OUTPUT,
             @PredicateSql = @PredicateSql OUTPUT, @ExpectedBit = @ExpectedBit OUTPUT;
        RETURN;
    END;

    IF @Shape = 'UNRECOGNISED'
    BEGIN
        SET @Reason = N'parser marked predicate UNRECOGNISED: ' + LEFT(@PredText, 300);
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- v0.11 JOIN path: EXISTS / NOT EXISTS over a 2-table INNER equi-join.
    -- Seeds coordinated rows across BOTH faked tables (shared join-key value,
    -- per-table WHERE/param overrides) and reconstructs the full joined gate
    -- for the strong assertion. Single-table predicates (@JoinsJson NULL) fall
    -- through to the existing logic below.
    --------------------------------------------------------------------------
    IF @JoinsJson IS NOT NULL AND ISJSON(@JoinsJson) = 1 AND @Shape IN ('EXISTS','NOT_EXISTS')
    BEGIN
        DECLARE @procObjJ INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName2));

        DECLARE @jt TABLE (ord INT, sch SYSNAME, tbl SYSNAME,
                           alias NVARCHAR(128) NULL, effalias NVARCHAR(128) NULL, objid INT NULL);
        INSERT @jt (ord, sch, tbl, alias)
        SELECT CAST([key] AS INT),
               ISNULL(JSON_VALUE([value],'$.schema'), N'dbo'),
               JSON_VALUE([value],'$.table'),
               JSON_VALUE([value],'$.alias')
        FROM   OPENJSON(@TablesJson);
        UPDATE @jt SET effalias = ISNULL(alias, tbl),
                       objid    = OBJECT_ID(QUOTENAME(sch) + N'.' + QUOTENAME(tbl));

        IF (SELECT COUNT(*) FROM @jt) <> 2
        BEGIN SET @Reason = N'join path expects exactly 2 tables (parser bound).'; RETURN; END;
        IF EXISTS (SELECT 1 FROM @jt WHERE objid IS NULL OR tbl IS NULL)
        BEGIN SET @Reason = N'a join target table could not be resolved.'; RETURN; END;

        DECLARE @jn TABLE (lAlias NVARCHAR(128) NULL, lCol SYSNAME, rAlias NVARCHAR(128) NULL, rCol SYSNAME, jval NVARCHAR(400) NULL);
        INSERT @jn (lAlias, lCol, rAlias, rCol)
        SELECT JSON_VALUE([value],'$.lAlias'), JSON_VALUE([value],'$.lCol'),
               JSON_VALUE([value],'$.rAlias'), JSON_VALUE([value],'$.rCol')
        FROM   OPENJSON(@JoinsJson);

        DECLARE @jcj TABLE (col SYSNAME, op VARCHAR(8), val NVARCHAR(400) NULL, valKind VARCHAR(16), tbl NVARCHAR(128) NULL);
        IF @WhereJson IS NOT NULL AND ISJSON(@WhereJson) = 1
        BEGIN
            -- WhereAstJson is DNF (array of OR terms). A joined WHERE with OR is
            -- out of this cut; require a single AND-composed disjunct.
            IF (SELECT COUNT(*) FROM OPENJSON(@WhereJson)) > 1
            BEGIN SET @Reason = N'OR composition in a joined WHERE is not seedable in this cut.'; RETURN; END;
            INSERT @jcj (col, op, val, valKind, tbl)
            SELECT JSON_VALUE(c.[value],'$.col'),
                   ISNULL(JSON_VALUE(c.[value],'$.op'), '='),
                   JSON_VALUE(c.[value],'$.val'),
                   ISNULL(JSON_VALUE(c.[value],'$.valKind'), 'literal'),
                   JSON_VALUE(c.[value],'$.tbl')
            FROM   OPENJSON(@WhereJson) t
            CROSS  APPLY OPENJSON(t.[value]) c
            WHERE  JSON_VALUE(c.[value],'$.col') IS NOT NULL;

            -- reverse-seed: resolve @param comparands to the proc-parameter sample.
            UPDATE cj
               SET val = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   @jcj cj
            JOIN   sys.parameters pr ON pr.object_id = @procObjJ AND pr.name = cj.val
            JOIN   sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  cj.valKind = 'param';

            IF EXISTS (SELECT 1 FROM @jcj WHERE valKind = 'param' AND val LIKE '@%')
            BEGIN SET @Reason = N'join WHERE references a parameter that is not a procedure parameter.'; RETURN; END;
            IF EXISTS (SELECT 1 FROM @jcj WHERE tbl IS NULL)
            BEGIN SET @Reason = N'unqualified WHERE column in a joined subquery cannot be routed to a table.'; RETURN; END;
            IF EXISTS (SELECT 1 FROM @jcj c WHERE NOT EXISTS (SELECT 1 FROM @jt t WHERE t.effalias = c.tbl))
            BEGIN SET @Reason = N'a WHERE conjunct references an alias not in the join.'; RETURN; END;
        END;

        -- A joining row is needed for EXISTS-TRUE and NOT_EXISTS-FALSE; otherwise
        -- leaving the faked tables empty makes the join (and the gate) the target.
        DECLARE @needRow BIT =
            CASE WHEN (@Shape = 'EXISTS' AND @want = 1) OR (@Shape = 'NOT_EXISTS' AND @want = 0)
                 THEN 1 ELSE 0 END;

        ----------------------------------------------------------------------
        -- Reconstruct the joined gate boolean for the strong assertion.
        ----------------------------------------------------------------------
        DECLARE @t0 NVARCHAR(400) =
            (SELECT QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                  + CASE WHEN alias IS NOT NULL THEN N' ' + QUOTENAME(alias) ELSE N'' END
             FROM @jt WHERE ord = 0);
        DECLARE @t1 NVARCHAR(400) =
            (SELECT QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                  + CASE WHEN alias IS NOT NULL THEN N' ' + QUOTENAME(alias) ELSE N'' END
             FROM @jt WHERE ord = 1);
        DECLARE @onSql NVARCHAR(MAX);
        SELECT @onSql = STRING_AGG(
                 QUOTENAME(lAlias) + N'.' + QUOTENAME(lCol) + N' = '
               + QUOTENAME(rAlias) + N'.' + QUOTENAME(rCol), N' AND ') FROM @jn;
        DECLARE @jWhere NVARCHAR(MAX) = NULL;
        IF EXISTS (SELECT 1 FROM @jcj)
            SELECT @jWhere = STRING_AGG(
                     QUOTENAME(tbl) + N'.' + QUOTENAME(col) + N' ' + op + N' ' + val, N' AND ') FROM @jcj;
        DECLARE @jFrom NVARCHAR(MAX) =
            @t0 + N' JOIN ' + @t1 + N' ON ' + @onSql
          + CASE WHEN @jWhere IS NULL THEN N'' ELSE N' WHERE ' + @jWhere END;
        SET @PredicateSql =
            CASE WHEN @Shape = 'EXISTS' THEN N'EXISTS (SELECT 1 FROM '     + @jFrom + N')'
                                        ELSE N'NOT EXISTS (SELECT 1 FROM ' + @jFrom + N')' END;
        SET @ExpectedBit = @want;

        ----------------------------------------------------------------------
        -- Emit the seed.
        ----------------------------------------------------------------------
        IF @needRow = 0
        BEGIN
            SET @SeedSql = N'    -- predicate ' + @Direction
                         + N': leave the faked join tables empty (no joining rows -> gate '
                         + @Direction + N').';
            SET @Supported = 1;
            RETURN;
        END;

        -- Shared join-key value: a WHERE "=" on a join column pins it; else a
        -- type-appropriate sample of the left join column (both sides identical).
        UPDATE jn SET jval = c.val
        FROM   @jn jn
        JOIN   @jcj c ON c.op = '='
                     AND ((c.tbl = jn.lAlias AND c.col = jn.lCol)
                       OR (c.tbl = jn.rAlias AND c.col = jn.rCol));
        UPDATE jn
           SET jval = TestGen.GetSampleValueLiteral(ty.name, col.max_length, col.precision, col.scale, 0)
        FROM   @jn jn
        JOIN   @jt t   ON t.effalias = jn.lAlias
        JOIN   sys.columns col ON col.object_id = t.objid AND col.name = jn.lCol
        JOIN   sys.types ty ON ty.user_type_id = col.user_type_id
        WHERE  jn.jval IS NULL;

        IF EXISTS (SELECT 1 FROM @jn WHERE jval IS NULL)
        BEGIN SET @Reason = N'could not resolve a join-key seed value.'; RETURN; END;

        DECLARE @tov TABLE (col SYSNAME, val NVARCHAR(400));
        DECLARE @tovJson NVARCHAR(MAX), @ins NVARCHAR(MAX), @seedAll NVARCHAR(MAX) = N'';
        DECLARE @co_ord INT, @co_sch SYSNAME, @co_tbl SYSNAME, @co_eff SYSNAME;
        DECLARE jc CURSOR LOCAL FAST_FORWARD FOR
            SELECT ord, sch, tbl, effalias FROM @jt ORDER BY ord;
        OPEN jc;
        FETCH NEXT FROM jc INTO @co_ord, @co_sch, @co_tbl, @co_eff;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @tov;
            -- join-key columns on this table get the shared value
            INSERT @tov (col, val)
            SELECT lCol, jval FROM @jn WHERE lAlias = @co_eff
            UNION
            SELECT rCol, jval FROM @jn WHERE rAlias = @co_eff;
            -- this table's WHERE conjuncts (satisfying value), excluding join cols
            INSERT @tov (col, val)
            SELECT c.col, TestGen.SatisfyingValue(c.op, c.val, 1)
            FROM   @jcj c
            WHERE  c.tbl = @co_eff
              AND  c.col NOT IN (SELECT col FROM @tov);

            IF EXISTS (SELECT 1 FROM @tov WHERE val IS NULL)
            BEGIN
                SET @Reason = N'join WHERE conjunct on ' + QUOTENAME(@co_tbl)
                            + N' is outside the supported grammar.';
                CLOSE jc; DEALLOCATE jc; RETURN;
            END;

            -- dedupe to one row per column (BuildSeedInsert joins overrides by name)
            SET @tovJson = (SELECT col AS [col], MAX(val) AS [val]
                            FROM @tov GROUP BY col FOR JSON PATH);
            SET @ins = TestGen.BuildSeedInsert(@co_sch, @co_tbl, @tovJson, 1);
            IF @ins IS NULL
            BEGIN
                SET @Reason = N'join target ' + QUOTENAME(@co_sch) + N'.' + QUOTENAME(@co_tbl)
                            + N' not found or has no insertable columns.';
                CLOSE jc; DEALLOCATE jc; RETURN;
            END;
            SET @seedAll = @seedAll + N'    ' + @ins + CHAR(13) + CHAR(10);
            FETCH NEXT FROM jc INTO @co_ord, @co_sch, @co_tbl, @co_eff;
        END;
        CLOSE jc; DEALLOCATE jc;

        SET @SeedSql = N'    -- predicate ' + @Direction + N' seed (join) for: '
                     + LEFT(@PredText, 200) + CHAR(13) + CHAR(10) + @seedAll;
        SET @Supported = 1;
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Resolve the (single) target table.
    --------------------------------------------------------------------------
    DECLARE @sch SYSNAME, @tbl SYSNAME, @raw NVARCHAR(400);
    SELECT TOP 1
        @sch = JSON_VALUE([value], '$.schema'),
        @tbl = JSON_VALUE([value], '$.table'),
        @raw = JSON_VALUE([value], '$.raw')
    FROM OPENJSON(@TablesJson)
    ORDER BY [key];

    -- Fall back to "schema.table" packed in $.table or $.raw.
    IF @tbl IS NULL AND @raw IS NOT NULL SET @tbl = @raw;
    IF @tbl IS NOT NULL AND @sch IS NULL AND CHARINDEX('.', @tbl) > 0
    BEGIN
        SET @sch = PARSENAME(@tbl, 2);
        SET @tbl = PARSENAME(@tbl, 1);
    END;
    IF @sch IS NULL SET @sch = N'dbo';

    IF @tbl IS NULL
    BEGIN
        SET @Reason = N'no target table resolved from TargetTablesJson.';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Build WHERE-match overrides (matching rows must satisfy the WHERE in
    -- BOTH directions; direction is controlled by row count / aggregate value).
    --------------------------------------------------------------------------
    DECLARE @ov TABLE (col SYSNAME, val NVARCHAR(400));
    DECLARE @unsupported BIT = 0;

    DECLARE @procObj INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName2));
    IF @WhereJson IS NOT NULL AND ISJSON(@WhereJson) = 1
    BEGIN
        -- WhereAstJson is DNF: an array of TERMS (OR-composed), each itself a
        -- JSON array of AND-composed conjuncts. Read all conjuncts tagged with
        -- their term index. Reverse-seed: resolve @param comparands to the
        -- proc-parameter sample value (the same GetSampleValueLiteral variant-0
        -- the test passes as the EXEC arg) so the seeded row matches the gate.
        DECLARE @cj TABLE (term INT, col SYSNAME, op VARCHAR(8), val NVARCHAR(400), valKind VARCHAR(16));
        INSERT @cj (term, col, op, val, valKind)
        SELECT t.[key],
               JSON_VALUE(c.[value], '$.col'),
               ISNULL(JSON_VALUE(c.[value], '$.op'), '='),
               JSON_VALUE(c.[value], '$.val'),
               ISNULL(JSON_VALUE(c.[value], '$.valKind'), 'literal')
        FROM   OPENJSON(@WhereJson) t
        CROSS  APPLY OPENJSON(t.[value]) c
        WHERE  JSON_VALUE(c.[value], '$.col') IS NOT NULL;

        UPDATE cj
           SET val = TestGen.GetSampleValueLiteral(t2.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   @cj cj
        JOIN   sys.parameters pr ON pr.object_id = @procObj AND pr.name = cj.val
        JOIN   sys.types t2 ON t2.user_type_id = pr.user_type_id
        WHERE  cj.valKind = 'param';

        IF EXISTS (SELECT 1 FROM @cj WHERE valKind = 'param' AND val LIKE '@%')
        BEGIN
            SET @Reason = N'WHERE references a parameter/variable that is not a '
                        + N'procedure parameter - cannot resolve a deterministic seed value.';
            RETURN;
        END;

        -- Pick the FIRST fully-seedable disjunct as the matching-row driver
        -- (every conjunct in it must yield a satisfying value).
        DECLARE @driver INT = NULL;
        SELECT TOP 1 @driver = term
        FROM   @cj
        GROUP  BY term
        HAVING SUM(CASE WHEN TestGen.SatisfyingValue(op, val, 1) IS NULL THEN 1 ELSE 0 END) = 0
        ORDER  BY term;

        IF @driver IS NULL
        BEGIN
            SET @Reason = N'no WHERE disjunct is fully seedable (a non-numeric '
                        + N'inequality or unknown operator in every OR branch).';
            RETURN;
        END;

        -- A matching row satisfies the driver disjunct -> it satisfies the whole
        -- OR (each seeded row counts once), so row-count case analysis is unchanged.
        INSERT @ov (col, val)
        SELECT col, TestGen.SatisfyingValue(op, val, 1) FROM @cj WHERE term = @driver;

        -- Strong-assertion WHERE = the FULL DNF, params resolved:
        --   (t0c0 AND t0c1) OR (t1c0) OR ...   (parens only when >1 disjunct).
        DECLARE @nterms INT = (SELECT COUNT(DISTINCT term) FROM @cj);
        ;WITH tt AS (
            SELECT term,
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                       QUOTENAME(col) + N' ' + op + N' ' + val), N' AND ') AS body
            FROM   @cj GROUP BY term )
        SELECT @whereSql = STRING_AGG(CONVERT(NVARCHAR(MAX),
                   CASE WHEN @nterms > 1 THEN N'(' + body + N')' ELSE body END), N' OR ')
        FROM   tt;

        IF EXISTS (SELECT 1 FROM @ov WHERE val IS NULL)
        BEGIN
            SET @Reason = N'WHERE clause has a conjunct outside the supported '
                        + N'grammar (non-numeric inequality or unknown operator).';
            RETURN;
        END;
    END;

    -- Parameter comparand (e.g. (SELECT COUNT(*) FROM T) > @Threshold): resolve
    -- @name to the proc-parameter sample value the test passes, so the seeded
    -- count/aggregate and the runtime gate agree (no ghost).
    IF @Comparand IS NOT NULL AND LEFT(@Comparand, 1) = N'@'
    BEGIN
        DECLARE @cmpVal NVARCHAR(400) = NULL;
        SELECT @cmpVal = TestGen.GetSampleValueLiteral(ty.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   sys.parameters pr
        JOIN   sys.types ty ON ty.user_type_id = pr.user_type_id
        WHERE  pr.object_id = @procObj AND pr.name = @Comparand;
        IF @cmpVal IS NULL
        BEGIN
            SET @Reason = N'comparand parameter ' + @Comparand
                        + N' is not a procedure parameter - cannot resolve a value.';
            RETURN;
        END;
        SET @Comparand = @cmpVal;
    END;

    --------------------------------------------------------------------------
    -- Case analysis: compute row count @K (and any aggregate-column override).
    --------------------------------------------------------------------------
    DECLARE @K INT = NULL;
    DECLARE @aggColName SYSNAME = NULL, @aggVal NVARCHAR(400) = NULL;
    DECLARE @N FLOAT, @Nint INT;
    DECLARE @op VARCHAR(16) = REPLACE(UPPER(ISNULL(@Comparator,'')), '!=', '<>');

    IF @Shape = 'EXISTS'        SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    ELSE IF @Shape = 'NOT_EXISTS' SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;

    ELSE IF @Shape = 'SCALAR_NULL'
    BEGIN
        -- IS_NULL true  = empty (scalar subquery -> NULL); IS_NOT_NULL true = 1 row.
        IF @op = 'IS_NULL'      SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;
        ELSE IF @op = 'IS_NOT_NULL' SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
        ELSE
        BEGIN
            SET @Reason = N'SCALAR_NULL with unexpected comparator ' + ISNULL(@op,'(null)');
            RETURN;
        END;
    END;

    ELSE IF @Shape = 'COUNT_CMP'
    BEGIN
        SET @N = TRY_CAST(@Comparand AS FLOAT);
        IF @N IS NULL OR @N <> FLOOR(@N)
        BEGIN
            SET @Reason = N'COUNT comparand is not an integer literal: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        SET @Nint = CAST(@N AS INT);
        IF      @op = '='  SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint + 1 END;
        ELSE IF @op = '<>' SET @K = CASE WHEN @want = 1 THEN @Nint + 1    ELSE @Nint     END;
        ELSE IF @op = '>'  SET @K = CASE WHEN @want = 1 THEN @Nint + 1    ELSE 0         END;
        ELSE IF @op = '>=' SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint - 1 END;
        ELSE IF @op = '<'  SET @K = CASE WHEN @want = 1 THEN @Nint - 1    ELSE @Nint     END;
        ELSE IF @op = '<=' SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint + 1 END;
        ELSE
        BEGIN
            SET @Reason = N'COUNT comparator not supported: ' + ISNULL(@op,'(null)');
            RETURN;
        END;
        IF @K < 0
        BEGIN
            SET @Reason = N'degenerate COUNT threshold: cannot make "' + LEFT(@PredText,200)
                        + N'" evaluate ' + @Direction + N' (would need a negative row count).';
            RETURN;
        END;
    END;

    ELSE IF @Shape = 'COUNT_IN'
    BEGIN
        DECLARE @first INT = NULL, @maxv INT = NULL, @bad INT = 0;
        SELECT  @first = MIN(CASE WHEN ord = 1 THEN v END),
                @maxv  = MAX(v),
                @bad   = SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END)
        FROM (
            SELECT  TRY_CAST(LTRIM(RTRIM([value])) AS INT) AS v,
                    ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS ord
            FROM    STRING_SPLIT(ISNULL(@Comparand, N''), ',')
        ) s;
        IF @bad > 0 OR @first IS NULL
        BEGIN
            SET @Reason = N'COUNT IN(...) list is not all integer literals: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        -- TRUE: count = first list value.  FALSE: a count not in the list (max+1).
        SET @K = CASE WHEN @want = 1 THEN @first ELSE @maxv + 1 END;
    END;

    ELSE IF @Shape = 'COUNT_BETWEEN'
    BEGIN
        DECLARE @A INT = TRY_CAST(LTRIM(RTRIM(
                   LEFT(@Comparand, CHARINDEX(' AND ', ' ' + UPPER(@Comparand) + ' ') - 1))) AS INT);
        -- Robust split on ' AND '
        DECLARE @up NVARCHAR(MAX) = UPPER(@Comparand);
        DECLARE @ap INT = CHARINDEX(' AND ', @up);
        IF @ap > 0
        BEGIN
            SET @A = TRY_CAST(LTRIM(RTRIM(LEFT(@Comparand, @ap - 1))) AS INT);
            DECLARE @B INT = TRY_CAST(LTRIM(RTRIM(SUBSTRING(@Comparand, @ap + 5, 4000))) AS INT);
            IF @A IS NULL OR @B IS NULL
            BEGIN
                SET @Reason = N'COUNT BETWEEN bounds are not integer literals: ' + @Comparand;
                RETURN;
            END;
            SET @K = CASE WHEN @want = 1 THEN @A
                          WHEN @A >= 1   THEN @A - 1
                          ELSE @B + 1 END;
        END
        ELSE
        BEGIN
            SET @Reason = N'COUNT BETWEEN could not be parsed: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
    END;

    ELSE IF @Shape IN ('SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP','SCALAR_CMP')
    BEGIN
        -- One row whose aggregate/selected column carries a value that makes the
        -- single-row aggregate satisfy (or violate) the comparator.
        SET @K = 1;
        -- Inner column: between '(' and ')' for aggregates; the bare column for SCALAR.
        DECLARE @inner NVARCHAR(256) = @AggCol;
        DECLARE @op1 INT = CHARINDEX('(', ISNULL(@AggCol,''));
        IF @op1 > 0
            SET @inner = SUBSTRING(@AggCol, @op1 + 1, CHARINDEX(')', @AggCol + ')', @op1) - @op1 - 1);
        -- Strip table/alias qualifier and brackets.
        SET @aggColName = PARSENAME(REPLACE(REPLACE(LTRIM(RTRIM(@inner)), '[',''), ']',''), 1);
        IF @aggColName IS NULL OR @aggColName = N'*'
        BEGIN
            SET @Reason = N'could not resolve aggregate/scalar column from "' + ISNULL(@AggCol,'(null)') + N'".';
            RETURN;
        END;
        SET @aggVal = TestGen.SatisfyingValue(@op, @Comparand, @want);
        IF @aggVal IS NULL
        BEGIN
            SET @Reason = N'aggregate/scalar comparator+comparand outside supported grammar: '
                        + ISNULL(@op,'') + N' ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        -- Aggregate override wins over any WHERE override on the same column.
        DELETE FROM @ov WHERE col = @aggColName;
        INSERT @ov (col, val) VALUES (@aggColName, @aggVal);
    END;

    ELSE
    BEGIN
        SET @Reason = N'unhandled predicate shape: ' + @Shape;
        RETURN;
    END;

    -- Reconstruct the gate boolean (params already resolved in @whereSql) so the
    -- generated test can ASSERT the seed actually drove the predicate the right
    -- way (no ghost pass: a wrong seed fails this assertion).
    SET @ExpectedBit = @want;
    DECLARE @tgtSql NVARCHAR(300) = QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl);
    DECLARE @whereClause NVARCHAR(MAX) = CASE WHEN @whereSql IS NULL OR @whereSql = N'' THEN N'' ELSE N' WHERE ' + @whereSql END;
    DECLARE @scalarCol SYSNAME = ISNULL(@aggColName, @AggCol);
    SET @PredicateSql =
        CASE @Shape
            WHEN 'EXISTS'        THEN N'EXISTS (SELECT 1 FROM '     + @tgtSql + @whereClause + N')'
            WHEN 'NOT_EXISTS'    THEN N'NOT EXISTS (SELECT 1 FROM ' + @tgtSql + @whereClause + N')'
            WHEN 'COUNT_CMP'     THEN N'(SELECT COUNT(*) FROM '     + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'SUM_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'MIN_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'MAX_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'AVG_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'SCALAR_CMP'    THEN N'(SELECT ' + @scalarCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'COUNT_IN'      THEN N'(SELECT COUNT(*) FROM ' + @tgtSql + @whereClause + N')' + CASE WHEN @op = N'NOT_IN' THEN N' NOT IN (' ELSE N' IN (' END + @Comparand + N')'
            WHEN 'COUNT_BETWEEN' THEN N'(SELECT COUNT(*) FROM ' + @tgtSql + @whereClause + N') BETWEEN ' + @Comparand
            WHEN 'SCALAR_NULL'   THEN N'(SELECT ' + @scalarCol + N' FROM ' + @tgtSql + @whereClause + N') ' + CASE WHEN @op = N'IS_NOT_NULL' THEN N'IS NOT NULL' ELSE N'IS NULL' END
        END;

    IF @K IS NULL
    BEGIN
        SET @Reason = N'internal: row count not computed for shape ' + @Shape;
        RETURN;
    END;

    IF @K > @MaxSeedRows
    BEGIN
        SET @Reason = N'seed row count ' + CAST(@K AS NVARCHAR(12)) + N' exceeds cap ('
                    + CAST(@MaxSeedRows AS NVARCHAR(12)) + N') for "' + LEFT(@PredText,160) + N'".';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Emit.
    --------------------------------------------------------------------------
    IF @K = 0
    BEGIN
        SET @SeedSql   = N'    -- predicate ' + @Direction + N': leave faked '
                       + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl)
                       + N' empty (no rows satisfy the subquery).';
        SET @Supported = 1;
        RETURN;
    END;

    DECLARE @ovJson NVARCHAR(MAX) =
        (SELECT col AS [col], val AS [val] FROM @ov FOR JSON PATH);

    DECLARE @insert NVARCHAR(MAX) = TestGen.BuildSeedInsert(@sch, @tbl, @ovJson, @K);
    IF @insert IS NULL
    BEGIN
        SET @Reason = N'target table ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl)
                    + N' not found or has no insertable columns.';
        RETURN;
    END;

    SET @SeedSql = N'    -- predicate ' + @Direction + N' seed for: ' + REPLACE(REPLACE(REPLACE(LEFT(@PredText, 200), CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ') + CHAR(13) + CHAR(10)
                 + N'    ' + @insert;
    SET @Supported = 1;
END;
GO

PRINT 'Module 32 (predicate seeder) installed.';
GO
