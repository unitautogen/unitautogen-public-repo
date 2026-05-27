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

/*******************************************************************************
 * Verify_Coverage_v5.sql
 *
 * Run AFTER applying:
 *   - 20_Coverage_Instrumenter_v5.sql
 *   - 22_Coverage_Reporter_v2.sql
 *
 * All output is via PRINT so it appears in SSMS Messages tab.
 ******************************************************************************/
USE AdventureWorks2025;
GO

SET NOCOUNT ON;

PRINT '========== Step 1: re-instrument ==========';
EXEC TestGen.InstrumentProcedure @SchemaName = N'dbo', @ProcName = N'uspV9ValidationTest';
GO

PRINT '';
PRINT '========== Step 2: registry summary ==========';
DECLARE @Lines INT, @Exec INT, @Branch INT;
SELECT @Lines  = COUNT(*),
       @Exec   = SUM(CAST(IsExec AS INT)),
       @Branch = SUM(CAST(IsBranch AS INT))
FROM   TestGen.CoverageLines
WHERE  SchemaName = N'dbo' AND ProcName = N'uspV9ValidationTest';
PRINT 'Total lines registered : ' + CAST(ISNULL(@Lines,0)  AS VARCHAR);
PRINT 'IsExec lines           : ' + CAST(ISNULL(@Exec,0)   AS VARCHAR);
PRINT 'IsBranch lines         : ' + CAST(ISNULL(@Branch,0) AS VARCHAR);
PRINT 'Expected: 148 / 28 / 15  (Lines / Exec / Branch)';
GO

PRINT '';
PRINT '========== Step 3: registry dump (Exec or Branch only) ==========';
PRINT ' LN  Ex Br  Text';
DECLARE @LN INT, @LT NVARCHAR(MAX), @IE BIT, @IB BIT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT LineNum, LineText, IsExec, IsBranch
    FROM   TestGen.CoverageLines
    WHERE  SchemaName = N'dbo' AND ProcName = N'uspV9ValidationTest'
      AND  (IsExec = 1 OR IsBranch = 1)
    ORDER  BY LineNum;
OPEN c; FETCH NEXT FROM c INTO @LN, @LT, @IE, @IB;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT RIGHT('   ' + CAST(@LN AS VARCHAR), 3)
        + '   ' + CAST(@IE AS CHAR(1))
        + '  ' + CAST(@IB AS CHAR(1))
        + '   ' + LEFT(LTRIM(ISNULL(@LT,'')), 80);
    FETCH NEXT FROM c INTO @LN, @LT, @IE, @IB;
END;
CLOSE c; DEALLOCATE c;
GO

PRINT '';
PRINT '========== Step 4: cross-check IsExec <-> RecordCoverageHit ==========';
DECLARE @body NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.uspV9ValidationTest_cov'));
IF @body IS NULL
BEGIN
    PRINT '!! _cov proc was not created. EXEC(@CreateSQL) inside InstrumentProcedure failed.';
    PRINT '   Look at the previous Messages output for the syntax error.';
    RETURN;
END;

DECLARE @okCount INT = 0, @missCount INT = 0;
DECLARE @ckLN INT;
DECLARE @needle NVARCHAR(200);
DECLARE ck CURSOR LOCAL FAST_FORWARD FOR
    SELECT LineNum FROM TestGen.CoverageLines
    WHERE SchemaName = N'dbo' AND ProcName = N'uspV9ValidationTest' AND IsExec = 1
    ORDER BY LineNum;
OPEN ck; FETCH NEXT FROM ck INTO @ckLN;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @needle = N'RecordCoverageHit ''dbo'',''uspV9ValidationTest'','
                + CAST(@ckLN AS NVARCHAR(10)) + N';';
    IF CHARINDEX(@needle, @body) > 0
        SET @okCount = @okCount + 1;
    ELSE
    BEGIN
        SET @missCount = @missCount + 1;
        PRINT '  MISSING injection for IsExec LineNum=' + CAST(@ckLN AS VARCHAR);
    END;
    FETCH NEXT FROM ck INTO @ckLN;
END;
CLOSE ck; DEALLOCATE ck;

PRINT 'Injections present : ' + CAST(@okCount   AS VARCHAR);
PRINT 'Injections missing : ' + CAST(@missCount AS VARCHAR);
IF @missCount = 0 PRINT 'PASS - registry and instrumented body agree.';
GO

PRINT '';
PRINT '========== Step 5 (optional): end-to-end coverage run ==========';
PRINT 'When the above shows the expected counts and PASS, run:';
PRINT '  EXEC TestGen.RunCoverage @SchemaName=N''dbo'', @ProcName=N''uspV9ValidationTest'', @OutputMode=''TEXT'';';
GO
