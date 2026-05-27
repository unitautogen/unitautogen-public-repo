/*****************************************************************************
 * TestGen.GetSampleValueLiteral
 * -----------------------------------------------------------------------------
 * Returns a T-SQL literal suitable for a given type name. The @Variant argument
 * selects which sample to return:
 *   0 = a "typical valid" value
 *   1 = a "boundary low" value  (zero, empty string, 1900-01-01, ...)
 *   2 = a "boundary high" value (MAX-like, long string, future date, ...)
 *   3 = NULL literal
 *
 * Used by the test-class generator to build _Happy / _Boundary / _Null tests.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetSampleValueLiteral', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.GetSampleValueLiteral;
GO

CREATE FUNCTION TestGen.GetSampleValueLiteral
(
    @SqlTypeName SYSNAME,
    @MaxLength   SMALLINT,
    @Precision   TINYINT,
    @Scale       TINYINT,
    @Variant     TINYINT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @Variant = 3 RETURN N'NULL';

    DECLARE @t SYSNAME = LOWER(@SqlTypeName);

    -- Integers
    IF @t IN ('bit')
        RETURN CASE @Variant WHEN 0 THEN N'1' WHEN 1 THEN N'0' ELSE N'1' END;
    IF @t IN ('tinyint')
        RETURN CASE @Variant WHEN 0 THEN N'42' WHEN 1 THEN N'0' ELSE N'255' END;
    IF @t IN ('smallint')
        RETURN CASE @Variant WHEN 0 THEN N'1234' WHEN 1 THEN N'-32768' ELSE N'32767' END;
    IF @t IN ('int')
        RETURN CASE @Variant WHEN 0 THEN N'42' WHEN 1 THEN N'-2147483648' ELSE N'2147483647' END;
    IF @t IN ('bigint')
        RETURN CASE @Variant WHEN 0 THEN N'1000000' WHEN 1 THEN N'-9223372036854775808' ELSE N'9223372036854775807' END;

    -- Money / decimal / numeric
    IF @t IN ('money','smallmoney')
        RETURN CASE @Variant WHEN 0 THEN N'$123.45' WHEN 1 THEN N'$0.00' ELSE N'$999999.99' END;
    IF @t IN ('decimal','numeric')
        RETURN CASE @Variant WHEN 0 THEN N'123.45' WHEN 1 THEN N'0' ELSE N'99999.99' END;
    IF @t IN ('float','real')
        RETURN CASE @Variant WHEN 0 THEN N'1.5' WHEN 1 THEN N'0' ELSE N'1.7976931348623157E+308' END;

    -- Strings
    IF @t IN ('char','varchar','nchar','nvarchar','sysname','text','ntext')
    BEGIN
        -- Compute the column's effective character length up front so all
        -- variants can respect it.
        DECLARE @len INT =
            CASE
                WHEN @MaxLength = -1 THEN 200          -- MAX types
                WHEN @t IN ('nchar','nvarchar')
                                     THEN @MaxLength/2
                ELSE @MaxLength
            END;
        IF @len IS NULL OR @len < 1 SET @len = 10;
        IF @len > 200 SET @len = 200;

        IF @Variant = 0
        BEGIN
            -- v9.2 (revision 2): always return a SHORT sample value (3 chars
            -- or shorter, capped by @len) for strings.  Reason: parameters
            -- are often used in WHERE clauses against columns of varying
            -- max-length.  If the EXEC arg uses 'SampleText' (10 chars) and
            -- the seed truncates to 'Sam' to fit a NCHAR(3) column, the
            -- predicate `col = @param` evaluates 'Sam' = 'SampleText' = false.
            -- A 3-char default fits in any column with max-length >= 3 (which
            -- is most realistic columns).  Sub-3-char columns are rare.
            IF @len >= 3 RETURN N'''Sam''';
            RETURN N'''' + LEFT(N'Sam', @len) + N'''';
        END;
        IF @Variant = 1 RETURN N'''''';   -- empty string
        -- boundary high: build a longish string respecting max_length
        RETURN N'''' + REPLICATE(N'X', @len) + N'''';
    END;

    -- Dates / times
    IF @t = 'date'
        RETURN CASE @Variant WHEN 0 THEN N'''2024-06-15''' WHEN 1 THEN N'''1900-01-01''' ELSE N'''9999-12-31''' END;
    IF @t IN ('datetime','datetime2','smalldatetime','datetimeoffset')
        RETURN CASE @Variant
                 WHEN 0 THEN N'''2024-06-15T12:34:56'''
                 WHEN 1 THEN N'''1900-01-01T00:00:00'''
                 ELSE        N'''9999-12-31T23:59:59'''
               END;
    IF @t = 'time'
        RETURN CASE @Variant WHEN 0 THEN N'''12:34:56''' WHEN 1 THEN N'''00:00:00''' ELSE N'''23:59:59''' END;

    -- Binary
    IF @t IN ('binary','varbinary','image')
        RETURN CASE @Variant WHEN 0 THEN N'0x0102' WHEN 1 THEN N'0x00' ELSE N'0xFFFFFFFF' END;

    -- Uniqueidentifier
    IF @t = 'uniqueidentifier'
        RETURN CASE @Variant
                 WHEN 0 THEN N'''11111111-1111-1111-1111-111111111111'''
                 WHEN 1 THEN N'''00000000-0000-0000-0000-000000000000'''
                 ELSE        N'''FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'''
               END;

    IF @t = 'xml'
        RETURN N'''<sample/>''';

    -- Fallback
    RETURN N'NULL /* unknown type ' + @SqlTypeName + N' */';
END;
GO

/*****************************************************************************
 * TestGen.GetDeclareLiteralForType
 * -----------------------------------------------------------------------------
 * Returns the type portion of a DECLARE statement, e.g. NVARCHAR(50),
 * DECIMAL(10,2), DATETIME2(3). Used when we need to declare local variables
 * for OUTPUT parameters inside generated tests.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetDeclareLiteralForType', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.GetDeclareLiteralForType;
GO

CREATE FUNCTION TestGen.GetDeclareLiteralForType
(
    @SqlTypeName SYSNAME,
    @MaxLength   SMALLINT,
    @Precision   TINYINT,
    @Scale       TINYINT
)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @t SYSNAME = LOWER(@SqlTypeName);

    IF @t IN ('char','varchar','binary','varbinary')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength AS NVARCHAR(10)) END + N')';

    IF @t IN ('nchar','nvarchar')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength/2 AS NVARCHAR(10)) END + N')';

    IF @t IN ('decimal','numeric')
        RETURN UPPER(@t) + N'(' + CAST(@Precision AS NVARCHAR(10)) + N',' + CAST(@Scale AS NVARCHAR(10)) + N')';

    IF @t IN ('datetime2','datetimeoffset','time')
        RETURN UPPER(@t) + N'(' + CAST(@Scale AS NVARCHAR(10)) + N')';

    RETURN UPPER(@t);
END;
GO

PRINT 'Sample-value helpers installed.';
GO
