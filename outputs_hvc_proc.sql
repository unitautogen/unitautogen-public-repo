CREATE PROCEDURE dbo.usp_ReconcileTradedPositions
    @AccountID INT,
    @CutoffDate DATETIME,
    @IsDryRun BIT = 1,
    @TotalProcessedRecords INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Local loop variables and control flags
    DECLARE @CurrentPositionID INT;
    DECLARE @CurrentVolume NUMERIC(18,4);
    DECLARE @CurrentPrice NUMERIC(18,4);
    DECLARE @CurrentDirection CHAR(1); -- 'B' for Buy, 'S' for Sell
    DECLARE @IsActiveAccount BIT;
    DECLARE @RiskMultiplier NUMERIC(5,2) = 1.00;
    DECLARE @WavePatternPhase CHAR(1) = '0';
    
    -- Initialize Output
    SET @TotalProcessedRecords = 0;

    -- 1. Initial Validation / Conditional Check
    SELECT @IsActiveAccount = IsActive 
    FROM dbo.TradingAccounts 
    WHERE AccountID = @AccountID;

    IF @IsActiveAccount IS NULL
    BEGIN
        RAISERROR('Account does not exist.', 16, 1);
        RETURN -1;
    END
    ELSE IF @IsActiveAccount = 0
    BEGIN
        -- Log warning and exit early (Branch 1A)
        INSERT INTO dbo.ReconciliationLogs (AccountID, LogMessage, LogType)
        VALUES (@AccountID, 'Reconciliation skipped: Account suspended.', 'WARN');
        RETURN 0;
    END

    -- 2. Determine Risk Multiplier based on historical metrics (Heavy Conditional Branching)
    DECLARE @MFI_Score INT;
    SELECT @MFI_Score = AVG(MFI_Value) FROM dbo.MarketIndicators WHERE MetricDate >= DATEADD(day, -14, @CutoffDate);

    IF @MFI_Score > 80
    BEGIN
        SET @RiskMultiplier = 1.50;
        SET @WavePatternPhase = 'C'; -- High risk / Wave C structural volatility
    END
    ELSE IF @MFI_Score < 20
    BEGIN
        SET @RiskMultiplier = 0.75;
        SET @WavePatternPhase = 'A';
    END
    ELSE
    BEGIN
        SET @RiskMultiplier = 1.00;
        SET @WavePatternPhase = 'B';
    END

    -- 3. Heavy Procedural Loop (Simulating Row-by-Row Evaluation)
    -- Finding all raw un-reconciled trades for this account
    IF OBJECT_ID('tempdb..#PendingTrades') IS NOT NULL DROP TABLE #PendingTrades;
    
    SELECT 
        ROW_NUMBER() OVER (ORDER BY TradeDate ASC, PositionID ASC) AS RowNum,
        PositionID, Volume, ExecutionPrice, TradeDirection
    INTO #PendingTrades
    FROM dbo.RawPositionIngest
    WHERE AccountID = @AccountID 
      AND SettleDate <= @CutoffDate
      AND IsReconciled = 0;

    DECLARE @LoopCounter INT = 1;
    DECLARE @MaxRows INT = (SELECT COUNT(*) FROM #PendingTrades);

    -- Primary Heavy Loop
    WHILE @LoopCounter <= @MaxRows
    BEGIN
        SELECT 
            @CurrentPositionID = PositionID,
            @CurrentVolume = Volume,
            @CurrentPrice = ExecutionPrice,
            @CurrentDirection = TradeDirection
        FROM #PendingTrades
        WHERE RowNum = @LoopCounter;

        -- Nested Conditional Block 1: Directional Validation
        IF @CurrentVolume <= 0 OR @CurrentPrice <= 0
        BEGIN
            -- Flag dirty data and move to next record
            INSERT INTO dbo.ReconciliationErrors (PositionID, ErrorReason)
            VALUES (@CurrentPositionID, 'Invalid Volume or Price metrics.');
            
            SET @LoopCounter = @LoopCounter + 1;
            CONTINUE; -- Force skip to next loop iteration
        END

        -- Nested Conditional Block 2: Complex Business Logic Math
        DECLARE @AdjustedValue NUMERIC(18,4) = (@CurrentVolume * @CurrentPrice) * @RiskMultiplier;
        DECLARE @ReconciliationStatus VARCHAR(20) = 'APPROVED';

        -- Inner conditional logic paths based on direction and risk profile
        IF @CurrentDirection = 'S' -- Short Positions
        BEGIN
            IF @AdjustedValue > 100000.00 AND @WavePatternPhase = 'C'
            BEGIN
                SET @ReconciliationStatus = 'HOLD_RISK_LIMIT';
            END
            ELSE IF @AdjustedValue > 50000.00
            BEGIN
                SET @ReconciliationStatus = 'MANUAL_REVIEW';
            END
        END
        ELSE IF @CurrentDirection = 'B' -- Long Positions
        BEGIN
            IF @AdjustedValue > 250000.00
            BEGIN
                SET @ReconciliationStatus = 'FLAG_LARGE_CAP';
            END
        END
        ELSE
        BEGIN
            SET @ReconciliationStatus = 'REJECT_UNKNOWN_DIR';
        END

        -- 4. State Modification based on DryRun flag
        IF @IsDryRun = 0
        BEGIN
            -- Real execution path (Branch 2A)
            UPDATE dbo.RawPositionIngest
            SET IsReconciled = 1, ReconciledDate = GETDATE()
            WHERE PositionID = @CurrentPositionID;

            INSERT INTO dbo.SettledPositions (PositionID, FinalValue, Status, ProcessedPhase)
            VALUES (@CurrentPositionID, @AdjustedValue, @ReconciliationStatus, @WavePatternPhase);
        END
        ELSE
        BEGIN
            -- Dry Run Execution Path (Branch 2B)
            INSERT INTO dbo.DryRunAuditLog (AccountID, PositionID, TargetStatus, ComputedValue)
            VALUES (@AccountID, @CurrentPositionID, @ReconciliationStatus, @AdjustedValue);
        END

        -- Increment loop controllers
        SET @TotalProcessedRecords = @TotalProcessedRecords + 1;
        SET @LoopCounter = @LoopCounter + 1;
    END

    -- Final Cleanup and logging
    INSERT INTO dbo.ReconciliationLogs (AccountID, LogMessage, LogType)
    VALUES (@AccountID, CONCAT('Completed processing. Records handled: ', @TotalProcessedRecords), 'INFO');

    DROP TABLE #PendingTrades;
    RETURN 0;
END;

