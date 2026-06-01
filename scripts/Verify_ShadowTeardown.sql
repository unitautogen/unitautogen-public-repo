/*============================================================================
 * Verify_ShadowTeardown.sql  —  TF-shadow defensive-teardown check
 *----------------------------------------------------------------------------
 * Run on AdventureWorks2025 (or any DB with the framework + a multi-statement
 * TVF).  Reproduces the stale-synonym tangle a prior interrupted coverage run
 * can leave, then proves BuildShadowProcForFunction now recovers instead of
 * reporting a false "failed generation".  Idempotent; cleans up after itself.
 *============================================================================*/
SET NOCOUNT ON;
DECLARE @fn SYSNAME = N'ufnGetContactInformation';   -- the AdventureWorks mTVF
DECLARE @cov SYSNAME = @fn + N'_covfn';
IF OBJECT_ID(N'dbo.'+@fn) IS NULL
BEGIN PRINT 'Skipped: dbo.'+@fn+' not present (point @fn at a local mTVF).'; RETURN; END;

-- 1. strand the tangle a half-finished prior run would leave
IF OBJECT_ID(N'dbo.'+@cov,'SN') IS NOT NULL EXEC('DROP SYNONYM dbo.'+@cov);
IF OBJECT_ID(N'dbo.'+@cov,'P')  IS NOT NULL EXEC('DROP PROCEDURE dbo.'+@cov);
EXEC('CREATE SYNONYM dbo.'+@cov+' FOR sys.objects');
IF OBJECT_ID(N'dbo.'+@cov+N'_orig','P') IS NULL EXEC('CREATE PROCEDURE dbo.'+@cov+'_orig AS SELECT 1');
IF OBJECT_ID(N'dbo.'+@cov+N'_cov','P')  IS NULL EXEC('CREATE PROCEDURE dbo.'+@cov+'_cov AS SELECT 1');
PRINT '=== Stranded a stale SYNONYM + _orig + _cov for dbo.'+@cov+' ===';

-- 2. build the shadow - must now RECOVER (drop the orphans) and succeed
DECLARE @sn SYSNAME, @st NVARCHAR(200);
EXEC TestGen.BuildShadowProcForFunction @SchemaName='dbo', @FunctionName=@fn, @ShadowName=@sn OUTPUT, @Status=@st OUTPUT;

SELECT
    @st AS build_status,                                  -- expect: OK
    (SELECT type_desc FROM sys.objects
       WHERE object_id=OBJECT_ID(N'dbo.'+@cov)) AS covfn_type,   -- expect: SQL_STORED_PROCEDURE
    OBJECT_ID(N'dbo.'+@cov+N'_orig') AS orig_left,        -- expect: NULL
    OBJECT_ID(N'dbo.'+@cov+N'_cov')  AS cov_left;         -- expect: NULL

-- 3. cleanup
IF OBJECT_ID(N'dbo.'+@cov,'P') IS NOT NULL EXEC('DROP PROCEDURE dbo.'+@cov);
IF OBJECT_ID(N'dbo.'+@cov,'SN') IS NOT NULL EXEC('DROP SYNONYM dbo.'+@cov);
IF OBJECT_ID(N'dbo.'+@cov+N'_orig','P') IS NOT NULL EXEC('DROP PROCEDURE dbo.'+@cov+'_orig');
IF OBJECT_ID(N'dbo.'+@cov+N'_cov','P')  IS NOT NULL EXEC('DROP PROCEDURE dbo.'+@cov+'_cov');
DELETE FROM TestGen.ShadowLineMap WHERE FunctionName=@fn;
PRINT '=== Verify_ShadowTeardown.sql complete (build_status should read OK). ===';
