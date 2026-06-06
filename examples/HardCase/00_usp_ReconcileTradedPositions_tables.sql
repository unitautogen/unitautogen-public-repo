/*=============================================================================
 * HardCase corpus - usp_ReconcileTradedPositions
 * 00_..._tables.sql - the 7 tables the proc references but which DO NOT EXIST
 * in HighValueCustomer (the proc was created via deferred name resolution and
 * is currently a PARSE-ONLY artifact: it cannot be FakeTable'd / instrumented /
 * run until these exist).
 *
 * Schemas inferred strictly from how each column is used in the proc body:
 *   - read targets, WHERE/ORDER BY columns, SET targets in UPDATE,
 *     INSERT column lists, and the comparison literals in each gate.
 * Tiny, deterministic, no seed rows (the framework seeds via FakeTable).
 *
 * Install: run against HighValueCustomer once. Then the proc is a live
 * benchmark for the search-based seeder (see design/DESIGN_Search_Based_Seeding.md).
 *===========================================================================*/

SET NOCOUNT ON;
GO

-- G1: SELECT @IsActiveAccount = IsActive FROM TradingAccounts WHERE AccountID=@AccountID
IF OBJECT_ID('dbo.TradingAccounts','U') IS NULL
CREATE TABLE dbo.TradingAccounts (
    AccountID INT          NOT NULL PRIMARY KEY,
    IsActive  BIT          NOT NULL
);
GO

-- G2: SELECT @MFI_Score = AVG(MFI_Value) FROM MarketIndicators
--     WHERE MetricDate >= DATEADD(day,-14,@CutoffDate)
IF OBJECT_ID('dbo.MarketIndicators','U') IS NULL
CREATE TABLE dbo.MarketIndicators (
    IndicatorID INT IDENTITY(1,1) PRIMARY KEY,
    MetricDate  DATETIME NOT NULL,
    MFI_Value   INT      NOT NULL      -- AVG()>80 / <20 gate -> integer money-flow index
);
GO

-- G3/G4/G5: SELECT ... INTO #PendingTrades FROM RawPositionIngest
--   WHERE AccountID=@AccountID AND SettleDate<=@CutoffDate AND IsReconciled=0
--   columns read: PositionID, Volume, ExecutionPrice, TradeDirection, TradeDate (ORDER BY)
--   UPDATE SET IsReconciled=1, ReconciledDate=GETDATE()
IF OBJECT_ID('dbo.RawPositionIngest','U') IS NULL
CREATE TABLE dbo.RawPositionIngest (
    PositionID     INT           NOT NULL PRIMARY KEY,
    AccountID      INT           NOT NULL,
    Volume         NUMERIC(18,4) NOT NULL,
    ExecutionPrice NUMERIC(18,4) NOT NULL,
    TradeDirection CHAR(1)       NOT NULL,   -- 'B' / 'S' / other -> REJECT arm
    TradeDate      DATETIME      NOT NULL,
    SettleDate     DATETIME      NOT NULL,
    IsReconciled   BIT           NOT NULL,
    ReconciledDate DATETIME      NULL
);
GO

-- INSERT INTO SettledPositions (PositionID, FinalValue, Status, ProcessedPhase)
IF OBJECT_ID('dbo.SettledPositions','U') IS NULL
CREATE TABLE dbo.SettledPositions (
    SettledID      INT IDENTITY(1,1) PRIMARY KEY,
    PositionID     INT           NOT NULL,
    FinalValue     NUMERIC(18,4) NOT NULL,
    Status         VARCHAR(20)   NOT NULL,
    ProcessedPhase CHAR(1)       NOT NULL
);
GO

-- INSERT INTO ReconciliationLogs (AccountID, LogMessage, LogType)
IF OBJECT_ID('dbo.ReconciliationLogs','U') IS NULL
CREATE TABLE dbo.ReconciliationLogs (
    LogID      INT IDENTITY(1,1) PRIMARY KEY,
    AccountID  INT           NOT NULL,
    LogMessage NVARCHAR(400) NOT NULL,
    LogType    VARCHAR(10)   NOT NULL
);
GO

-- INSERT INTO ReconciliationErrors (PositionID, ErrorReason)
IF OBJECT_ID('dbo.ReconciliationErrors','U') IS NULL
CREATE TABLE dbo.ReconciliationErrors (
    ErrorID     INT IDENTITY(1,1) PRIMARY KEY,
    PositionID  INT           NOT NULL,
    ErrorReason NVARCHAR(200) NOT NULL
);
GO

-- INSERT INTO DryRunAuditLog (AccountID, PositionID, TargetStatus, ComputedValue)
IF OBJECT_ID('dbo.DryRunAuditLog','U') IS NULL
CREATE TABLE dbo.DryRunAuditLog (
    AuditID      INT IDENTITY(1,1) PRIMARY KEY,
    AccountID    INT           NOT NULL,
    PositionID   INT           NOT NULL,
    TargetStatus VARCHAR(20)   NOT NULL,
    ComputedValue NUMERIC(18,4) NOT NULL
);
GO

PRINT 'HardCase tables for usp_ReconcileTradedPositions installed.';
GO
