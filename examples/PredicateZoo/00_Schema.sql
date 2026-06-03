/*=============================================================================
 * PredicateZoo - v0.10 predicate-aware seeding regression corpus
 * 00_Schema.sql - tables.  Deterministic, tiny, fast.  Schema: pz.
 *
 * Install order: 00_Schema.sql -> 01_Procedures.sql.  Then point
 * Get-ParsedPredicates.ps1 at schema 'pz' and inspect TestGen.PredicateInbox /
 * TestGen.GeneratePredicateBranchPlan against 02_Expected_Shapes.md.
 *===========================================================================*/
IF SCHEMA_ID('pz') IS NULL EXEC('CREATE SCHEMA pz;');
GO

IF OBJECT_ID('pz.Orders','U')   IS NOT NULL DROP TABLE pz.Orders;
IF OBJECT_ID('pz.Students','U') IS NOT NULL DROP TABLE pz.Students;
GO

CREATE TABLE pz.Students (
    StudentId INT IDENTITY(1,1) PRIMARY KEY,
    Active    BIT          NOT NULL,
    Score     INT          NOT NULL,
    Name      NVARCHAR(50) NOT NULL
);
GO

CREATE TABLE pz.Orders (
    OrderId    INT IDENTITY(1,1) PRIMARY KEY,
    CustomerId INT            NOT NULL,
    Amount     DECIMAL(10,2)  NOT NULL,
    Status     NVARCHAR(20)   NOT NULL
);
GO

PRINT 'PredicateZoo schema installed.';
GO
