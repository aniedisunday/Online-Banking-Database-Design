/*
============================================================================
 ONLINE BANKING DATABASE
============================================================================
 Platform : Microsoft SQL Server (T-SQL), run in SQL Server Management Studio
 Design   : Normalised to Third Normal Form (3NF)
============================================================================
*/


-- ============================================================================
-- SECTION 1: DATABASE CREATION
-- ============================================================================
-- Drops and recreates the database so the whole script can be re-run.

USE master;
GO

IF DB_ID('OnlineBankingDB') IS NOT NULL
BEGIN
    ALTER DATABASE OnlineBankingDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OnlineBankingDB;
END;
GO

CREATE DATABASE OnlineBankingDB;
GO

USE OnlineBankingDB;
GO


-- ============================================================================
-- SECTION 2: LOOKUP TABLES
-- ============================================================================
-- Account types, statuses and payment methods are kept in their own tables
-- so the main tables hold a small integer key instead of repeated text.

CREATE TABLE AccountType (
    AccountTypeID  INT IDENTITY(1,1) PRIMARY KEY,
    TypeName       NVARCHAR(20) NOT NULL UNIQUE,
    CONSTRAINT CHK_AccountType CHECK (TypeName IN ('Savings', 'Checking', 'Loan', 'Credit Card', 'Investment'))
);

CREATE TABLE AccountStatus (
    StatusID    INT IDENTITY(1,1) PRIMARY KEY,
    StatusName  NVARCHAR(20) NOT NULL UNIQUE,
    CONSTRAINT CHK_AccountStatus CHECK (StatusName IN ('Active', 'Dormant', 'Closed', 'Frozen'))
);

CREATE TABLE PaymentMethod (
    PaymentMethodID  INT IDENTITY(1,1) PRIMARY KEY,
    MethodName       NVARCHAR(20) NOT NULL UNIQUE,
    CONSTRAINT CHK_PaymentMethod CHECK (MethodName IN ('Bank Transfer', 'Card', 'Cash'))
);


-- ============================================================================
-- SECTION 3: MAIN TABLES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Address
-- Kept separate from Customers so address fields are not repeated and a
-- change of address updates one row.
-- ----------------------------------------------------------------------------
CREATE TABLE Address (
    AddressID     INT IDENTITY(1,1) PRIMARY KEY,
    AddressLine1  NVARCHAR(200) NOT NULL,
    AddressLine2  NVARCHAR(200) NULL,
    City          NVARCHAR(50)  NOT NULL,
    Postcode      NVARCHAR(10)  NOT NULL
);

-- ----------------------------------------------------------------------------
-- Customers
-- Customers are never deleted. When a customer leaves, IsActive is set to 0
-- and AccountClosureDate is recorded, so the record is kept for marketing.
-- Only a password hash is stored, never the password itself.
-- ----------------------------------------------------------------------------
CREATE TABLE Customers (
    CustomerID          INT IDENTITY(1,1) PRIMARY KEY,
    AddressID           INT           NOT NULL,
    CustomerFirstName   NVARCHAR(50)  NOT NULL,
    CustomerLastName    NVARCHAR(50)  NOT NULL,
    CustomerDOB         DATE          NOT NULL,
    Username            NVARCHAR(50)  NOT NULL UNIQUE,
    PasswordHash        VARCHAR(255)  NOT NULL,
    Email               NVARCHAR(100) NULL,
    Telephone           NVARCHAR(20)  NULL,
    IsActive            BIT           NOT NULL DEFAULT 1,
    AccountClosureDate  DATE          NULL,
    CreatedDate         DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT FK_Customer_Address FOREIGN KEY (AddressID) REFERENCES Address(AddressID),
    CONSTRAINT CHK_Customer_DOB    CHECK (CustomerDOB < CAST(GETDATE() AS DATE)),
    CONSTRAINT CHK_Customer_Email  CHECK (Email LIKE '%_@_%._%' OR Email IS NULL)
);

-- ----------------------------------------------------------------------------
-- Account
-- One row per product a customer holds. For Loan and Credit Card accounts a
-- negative CurrentBalance is the amount still owed; it rises towards zero as
-- payments are completed. CurrentBalance is maintained by a trigger.
-- ----------------------------------------------------------------------------
CREATE TABLE Account (
    AccountID         INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID        INT            NOT NULL,
    AccountTypeID     INT            NOT NULL,
    StatusID          INT            NOT NULL,
    AccountName       NVARCHAR(100)  NOT NULL,
    ReferenceNumber   NVARCHAR(30)   NULL UNIQUE,
    OpeningDate       DATE           NOT NULL DEFAULT GETDATE(),
    ClosedFrozenDate  DATE           NULL,
    CurrentBalance    DECIMAL(18,2)  NOT NULL DEFAULT 0.00,
    CONSTRAINT FK_Account_Customer      FOREIGN KEY (CustomerID)    REFERENCES Customers(CustomerID),
    CONSTRAINT FK_Account_AccountType   FOREIGN KEY (AccountTypeID) REFERENCES AccountType(AccountTypeID),
    CONSTRAINT FK_Account_AccountStatus FOREIGN KEY (StatusID)      REFERENCES AccountStatus(StatusID),
    CONSTRAINT CHK_Account_ClosedDate   CHECK (ClosedFrozenDate IS NULL OR ClosedFrozenDate >= OpeningDate)
);

-- ----------------------------------------------------------------------------
-- Transaction
-- Every financial event. DueDate applies to loan and credit card payments;
-- CompletionDate is NULL while a transaction is still pending.
-- TRANSACTION is a reserved word in T-SQL, so the name is written in brackets.
-- ----------------------------------------------------------------------------
CREATE TABLE [Transaction] (
    TransactionID    INT IDENTITY(1,1) PRIMARY KEY,
    AccountID        INT            NOT NULL,
    CustomerID       INT            NOT NULL,
    TransactionDate  DATETIME       NOT NULL DEFAULT GETDATE(),
    DueDate          DATE           NULL,
    CompletionDate   DATETIME       NULL,
    Amount           DECIMAL(18,2)  NOT NULL,
    TransactionType  NVARCHAR(30)   NOT NULL,
    Description      NVARCHAR(200)  NULL,
    CONSTRAINT FK_Transaction_Account  FOREIGN KEY (AccountID)  REFERENCES Account(AccountID),
    CONSTRAINT FK_Transaction_Customer FOREIGN KEY (CustomerID) REFERENCES Customers(CustomerID),
    CONSTRAINT CHK_Transaction_Type    CHECK (TransactionType IN ('Deposit', 'Withdrawal', 'Payment', 'Transfer', 'Fee')),
    CONSTRAINT CHK_Transaction_Amount  CHECK (Amount > 0)
);

-- ----------------------------------------------------------------------------
-- OverdueFee
-- A fee charged when a payment is completed after its due date. TotalOwed is
-- the overdue amount, TotalRepaid is what has been paid back so far, and
-- OutstandingBalance is a computed column so it can never disagree with them.
-- ----------------------------------------------------------------------------
CREATE TABLE OverdueFee (
    OverdueFeeID        INT IDENTITY(1,1) PRIMARY KEY,
    TransactionID       INT            NOT NULL UNIQUE,
    CustomerID          INT            NOT NULL,
    FeeAmount           DECIMAL(18,2)  NOT NULL,
    DaysOverdue         INT            NOT NULL,
    FeeDate             DATE           NOT NULL DEFAULT GETDATE(),
    TotalOwed           DECIMAL(18,2)  NOT NULL,
    TotalRepaid         DECIMAL(18,2)  NOT NULL DEFAULT 0.00,
    OutstandingBalance  AS (TotalOwed - TotalRepaid) PERSISTED,
    CONSTRAINT FK_OverdueFee_Transaction FOREIGN KEY (TransactionID) REFERENCES [Transaction](TransactionID),
    CONSTRAINT FK_OverdueFee_Customer    FOREIGN KEY (CustomerID)    REFERENCES Customers(CustomerID),
    CONSTRAINT CHK_OverdueFee_Days       CHECK (DaysOverdue > 0),
    CONSTRAINT CHK_OverdueFee_Amount     CHECK (FeeAmount > 0),
    CONSTRAINT CHK_OverdueFee_Repaid     CHECK (TotalRepaid >= 0 AND TotalRepaid <= TotalOwed)
);

-- ----------------------------------------------------------------------------
-- Repayment
-- Each instalment paid against an overdue fee, with date, amount and method.
-- ----------------------------------------------------------------------------
CREATE TABLE Repayment (
    RepaymentID        INT IDENTITY(1,1) PRIMARY KEY,
    OverdueFeeID       INT            NOT NULL,
    CustomerID         INT            NOT NULL,
    PaymentMethodID    INT            NOT NULL,
    RepaymentDateTime  DATETIME       NOT NULL DEFAULT GETDATE(),
    Amount             DECIMAL(18,2)  NOT NULL,
    CONSTRAINT FK_Repayment_OverdueFee    FOREIGN KEY (OverdueFeeID)    REFERENCES OverdueFee(OverdueFeeID),
    CONSTRAINT FK_Repayment_Customer      FOREIGN KEY (CustomerID)      REFERENCES Customers(CustomerID),
    CONSTRAINT FK_Repayment_PaymentMethod FOREIGN KEY (PaymentMethodID) REFERENCES PaymentMethod(PaymentMethodID),
    CONSTRAINT CHK_Repayment_Amount       CHECK (Amount > 0)
);


-- ============================================================================
-- SECTION 4: INDEXES
-- ============================================================================
-- Foreign keys and the columns used for filtering. Primary keys and UNIQUE
-- columns are indexed automatically.

CREATE INDEX IX_Customers_Address        ON Customers(AddressID);
CREATE INDEX IX_Account_Customer         ON Account(CustomerID);
CREATE INDEX IX_Account_Type             ON Account(AccountTypeID);
CREATE INDEX IX_Account_Name             ON Account(AccountName);
CREATE INDEX IX_Transaction_Account      ON [Transaction](AccountID);
CREATE INDEX IX_Transaction_Customer     ON [Transaction](CustomerID);
CREATE INDEX IX_Transaction_DuePending   ON [Transaction](DueDate) WHERE CompletionDate IS NULL;
CREATE INDEX IX_OverdueFee_Customer      ON OverdueFee(CustomerID);
CREATE INDEX IX_Repayment_OverdueFee     ON Repayment(OverdueFeeID);
CREATE INDEX IX_Repayment_Customer       ON Repayment(CustomerID);
GO


-- ============================================================================
-- SECTION 5: SAMPLE DATA
-- ============================================================================
-- All people, addresses and numbers are fictional.

INSERT INTO AccountType   (TypeName)   VALUES ('Savings'), ('Checking'), ('Loan'), ('Credit Card'), ('Investment');
INSERT INTO AccountStatus (StatusName) VALUES ('Active'), ('Dormant'), ('Closed'), ('Frozen');
INSERT INTO PaymentMethod (MethodName) VALUES ('Bank Transfer'), ('Card'), ('Cash');

INSERT INTO Address (AddressLine1, AddressLine2, City, Postcode) VALUES
('12 High Street',  NULL,           'London',     'SW1A 1AA'),
('45 Park Road',    NULL,           'Manchester', 'M1 1AA'),
('78 Queen Lane',   'Flat 3',       'Birmingham', 'B1 1BB'),
('23 King Avenue',  NULL,           'Liverpool',  'L1 1CC'),
('90 Market Close', 'Ground Floor', 'Leeds',      'LS1 1DD'),
('34 River View',   NULL,           'Bristol',    'BS1 1EE'),
('56 Church Road',  'Apartment 7B', 'Glasgow',    'G1 1FF'),
('11 Station Lane', NULL,           'Edinburgh',  'EH1 1GG');

INSERT INTO Customers (AddressID, CustomerFirstName, CustomerLastName, CustomerDOB, Username, PasswordHash, Email, Telephone, IsActive)
VALUES
(1, 'Emma',     'Wilson',    '1990-05-15', 'emma_w',     'hash123', 'emma@email.com',     '07123456789', 1),
(2, 'Liam',     'Smith',     '1985-11-20', 'liam_s',     'hash456', NULL,                 NULL,          1),
(3, 'Olivia',   'Brown',     '1995-03-10', 'olivia_b',   'hash789', 'olivia@email.com',   '07234567890', 1),
(4, 'Noah',     'Jones',     '1978-08-05', 'noah_j',     'hash101', 'noah@email.com',     '07345678901', 1),
(5, 'Ava',      'Garcia',    '2000-12-25', 'ava_g',      'hash112', NULL,                 '07456789012', 1),
(6, 'Ethan',    'Miller',    '1992-07-18', 'ethan_m',    'hash134', 'ethan@email.com',    NULL,          1),
(7, 'Isabella', 'Davis',     '1989-04-30', 'isabella_d', 'hash156', 'isabella@email.com', '07567890123', 1),
(8, 'James',    'Rodriguez', '1998-09-12', 'james_r',    'hash178', NULL,                 NULL,          1);

-- Loan and Credit Card balances are negative: the amount still owed.
INSERT INTO Account (CustomerID, AccountTypeID, StatusID, AccountName, ReferenceNumber, OpeningDate, ClosedFrozenDate, CurrentBalance)
VALUES
(1, 1, 1, 'Emma Savings',       'SAV001',  '2024-01-10', NULL,          1250.50),
(1, 2, 1, 'Emma Checking',      'CHK001',  '2024-02-05', NULL,           340.75),
(2, 3, 1, 'Liam Personal Loan', 'LOAN001', '2023-11-15', NULL,         -8500.00),
(3, 4, 1, 'Olivia Credit Card', 'CC001',   '2024-03-20', NULL,         -1250.00),
(4, 5, 1, 'Noah Investment',    'INV001',  '2024-01-05', NULL,          5000.00),
(5, 1, 1, 'Ava Savings',        'SAV002',  '2024-04-01', NULL,           980.25),
(6, 2, 3, 'Ethan Checking',     'CHK002',  '2023-10-10', '2025-12-31',     0.00),
(7, 3, 1, 'Isabella Loan',      'LOAN002', '2024-02-28', NULL,         -4200.00),
(8, 4, 1, 'James Credit Card',  'CC002',   '2024-03-15', NULL,         -2100.00),
(2, 1, 1, 'Liam Extra Savings', 'SAV003',  '2024-05-01', NULL,           150.00),
(3, 2, 4, 'Olivia Checking',    'CHK003',  '2024-01-20', '2026-02-01',    45.50),
(4, 3, 1, 'Noah Second Loan',   'LOAN003', '2024-04-10', NULL,         -3000.00);

-- Transactions 1 to 15 are completed history. Transactions 4 to 11 were
-- paid late and carry an overdue fee. Transactions 16 to 20 are pending and
-- their due dates are set relative to today, so the "due soon" procedure
-- always has something to show whenever the script is run.
DECLARE @Today DATE = CAST(GETDATE() AS DATE);

INSERT INTO [Transaction] (AccountID, CustomerID, TransactionDate, DueDate, CompletionDate, Amount, TransactionType, Description)
VALUES
(1,  1, '2026-03-01', NULL,         '2026-03-01', 500.00,  'Deposit',    'Salary deposit'),
(2,  1, '2026-03-03', NULL,         '2026-03-03', 120.00,  'Withdrawal', 'ATM withdrawal'),
(5,  4, '2026-03-10', NULL,         '2026-03-10', 1000.00, 'Deposit',    'Investment deposit'),
(3,  2, '2026-02-20', '2026-03-01', '2026-03-13', 250.00,  'Payment',    'Loan monthly payment'),
(9,  8, '2026-02-25', '2026-03-05', '2026-03-13', 180.00,  'Payment',    'Credit card payment'),
(12, 4, '2026-03-01', '2026-03-10', '2026-03-25', 300.00,  'Payment',    'Loan instalment'),
(4,  3, '2026-03-05', '2026-03-15', '2026-03-22', 120.00,  'Payment',    'Credit card payment'),
(8,  7, '2026-03-01', '2026-03-10', '2026-03-20', 200.00,  'Payment',    'Loan repayment'),
(3,  2, '2026-03-20', '2026-04-01', '2026-04-10', 250.00,  'Payment',    'Loan monthly payment'),
(9,  8, '2026-03-28', '2026-04-05', '2026-04-11', 180.00,  'Payment',    'Credit card payment'),
(12, 4, '2026-04-01', '2026-04-10', '2026-04-14', 150.00,  'Payment',    'Loan instalment'),
(6,  5, '2026-04-10', NULL,         '2026-04-10', 30.00,   'Withdrawal', 'Shopping'),
(10, 2, '2026-04-14', NULL,         '2026-04-14', 50.00,   'Deposit',    'Refund'),
(1,  1, '2026-04-15', NULL,         '2026-04-15', 200.00,  'Deposit',    'Bonus'),
(2,  1, '2026-04-20', NULL,         '2026-04-20', 75.00,   'Transfer',   'Transfer to savings'),
(3,  2, DATEADD(DAY, -5, @Today), DATEADD(DAY,  2, @Today), NULL, 250.00, 'Payment', 'Loan monthly payment'),
(9,  8, DATEADD(DAY, -5, @Today), DATEADD(DAY,  3, @Today), NULL, 180.00, 'Payment', 'Credit card payment'),
(12, 4, DATEADD(DAY, -5, @Today), DATEADD(DAY,  4, @Today), NULL, 150.00, 'Payment', 'Loan instalment'),
(4,  3, DATEADD(DAY, -3, @Today), DATEADD(DAY,  1, @Today), NULL, 120.00, 'Payment', 'Credit card payment'),
(3,  2, DATEADD(DAY, -2, @Today), DATEADD(DAY, 12, @Today), NULL, 250.00, 'Payment', 'Next loan instalment');

-- One fee per late payment. FeeDate is the day the late payment completed.
-- TotalRepaid equals the sum of the repayments recorded below.
INSERT INTO OverdueFee (TransactionID, CustomerID, FeeAmount, DaysOverdue, FeeDate, TotalOwed, TotalRepaid)
VALUES
(4,  2, 25.00, 12, '2026-03-13', 250.00,  80.00),
(5,  8, 15.00,  8, '2026-03-13', 180.00, 170.00),
(6,  4, 30.00, 15, '2026-03-25', 300.00,  90.00),
(8,  7, 20.00, 10, '2026-03-20', 200.00, 200.00),
(7,  3, 18.00,  7, '2026-03-22', 120.00,  40.00),
(9,  2, 35.00,  9, '2026-04-10', 250.00, 100.00),
(10, 8, 22.00,  6, '2026-04-11', 180.00,  50.00),
(11, 4, 10.00,  4, '2026-04-14', 150.00, 140.00);

-- PaymentMethodID: 1 = Bank Transfer, 2 = Card, 3 = Cash
INSERT INTO Repayment (OverdueFeeID, CustomerID, PaymentMethodID, RepaymentDateTime, Amount)
VALUES
(1, 2, 1, '2026-03-20', 50.00),
(1, 2, 2, '2026-04-02', 30.00),
(2, 8, 3, '2026-03-18', 170.00),
(3, 4, 1, '2026-04-01', 90.00),
(4, 7, 2, '2026-03-27', 200.00),
(5, 3, 3, '2026-03-30', 20.00),
(5, 3, 1, '2026-04-12', 20.00),
(6, 2, 3, '2026-04-15', 60.00),
(6, 2, 1, '2026-04-20', 40.00),
(7, 8, 2, '2026-04-18', 50.00),
(8, 4, 1, '2026-04-17', 80.00),
(8, 4, 3, '2026-04-21', 60.00);
GO


-- ============================================================================
-- SECTION 6: STORED PROCEDURES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 6a. Search accounts by name, most recently opened first
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_SearchAccountsByName
    @AccountName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.AccountID,
        a.AccountName,
        at.TypeName   AS AccountType,
        s.StatusName  AS Status,
        a.OpeningDate,
        a.CurrentBalance,
        a.ReferenceNumber,
        CONCAT(c.CustomerFirstName, ' ', c.CustomerLastName) AS CustomerName
    FROM Account AS a
    INNER JOIN AccountType   AS at ON a.AccountTypeID = at.AccountTypeID
    INNER JOIN AccountStatus AS s  ON a.StatusID      = s.StatusID
    INNER JOIN Customers     AS c  ON a.CustomerID    = c.CustomerID
    WHERE a.AccountName LIKE '%' + @AccountName + '%'
    ORDER BY a.OpeningDate DESC;
END;
GO

EXEC sp_SearchAccountsByName @AccountName = 'Loan';
EXEC sp_SearchAccountsByName @AccountName = 'Savings';
GO

-- ----------------------------------------------------------------------------
-- 6b. Pending loan and credit card payments due in less than 5 days
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_GetDuePayments
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT
        t.TransactionID,
        CONCAT(c.CustomerFirstName, ' ', c.CustomerLastName) AS CustomerName,
        a.AccountName,
        at.TypeName                              AS AccountType,
        t.DueDate,
        t.Amount,
        DATEDIFF(DAY, @Today, t.DueDate)         AS DaysUntilDue
    FROM [Transaction] AS t
    INNER JOIN Account     AS a  ON t.AccountID     = a.AccountID
    INNER JOIN AccountType AS at ON a.AccountTypeID = at.AccountTypeID
    INNER JOIN Customers   AS c  ON t.CustomerID    = c.CustomerID
    WHERE at.TypeName IN ('Loan', 'Credit Card')
      AND t.TransactionType = 'Payment'
      AND t.CompletionDate IS NULL
      AND t.DueDate >= @Today
      AND t.DueDate <  DATEADD(DAY, 5, @Today)
    ORDER BY t.DueDate;
END;
GO

EXEC sp_GetDuePayments;
GO

-- ----------------------------------------------------------------------------
-- 6c. Insert a new customer and their address as one transaction
-- If the customer insert fails (for example a duplicate username), the
-- address insert is rolled back too, so no orphaned address is left behind.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_InsertNewCustomer
    @FirstName     NVARCHAR(50),
    @LastName      NVARCHAR(50),
    @Address1      NVARCHAR(200),
    @Address2      NVARCHAR(200) = NULL,
    @City          NVARCHAR(50),
    @Postcode      NVARCHAR(10),
    @DOB           DATE,
    @Username      NVARCHAR(50),
    @PasswordHash  VARCHAR(255),
    @Email         NVARCHAR(100) = NULL,
    @Telephone     NVARCHAR(20)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Address (AddressLine1, AddressLine2, City, Postcode)
        VALUES (@Address1, @Address2, @City, @Postcode);

        DECLARE @NewAddressID INT = SCOPE_IDENTITY();

        INSERT INTO Customers (AddressID, CustomerFirstName, CustomerLastName, CustomerDOB,
                               Username, PasswordHash, Email, Telephone)
        VALUES (@NewAddressID, @FirstName, @LastName, @DOB,
                @Username, @PasswordHash, @Email, @Telephone);

        DECLARE @NewCustomerID INT = SCOPE_IDENTITY();

        COMMIT TRANSACTION;

        SELECT @NewCustomerID AS NewCustomerID;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- A valid new customer
EXEC sp_InsertNewCustomer
    @FirstName    = 'Sophie',
    @LastName     = 'Taylor',
    @Address1     = '99 New Road',
    @City         = 'Cardiff',
    @Postcode     = 'CF1 1HH',
    @DOB          = '1997-06-22',
    @Username     = 'sophie_t',
    @PasswordHash = 'newhash999',
    @Email        = 'sophie@email.com',
    @Telephone    = '07777888899';

SELECT c.*, ad.AddressLine1, ad.City
FROM Customers AS c
INNER JOIN Address AS ad ON ad.AddressID = c.AddressID
WHERE c.Username = 'sophie_t';

-- A duplicate username is refused and the address insert is rolled back
SELECT COUNT(*) AS AddressesBefore FROM Address;

BEGIN TRY
    EXEC sp_InsertNewCustomer
        @FirstName    = 'Emma',
        @LastName     = 'Copy',
        @Address1     = '1 Test Street',
        @City         = 'London',
        @Postcode     = 'E1 1AA',
        @DOB          = '1991-01-01',
        @Username     = 'emma_w',
        @PasswordHash = 'hash000';
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorReturned;
END CATCH;

SELECT COUNT(*) AS AddressesAfter FROM Address;
GO

-- ----------------------------------------------------------------------------
-- 6d. Update an existing customer's details
-- Setting @IsActive to 0 records the closure date; the record itself is
-- kept. An unknown CustomerID raises an error instead of silently doing
-- nothing.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE sp_UpdateCustomer
    @CustomerID  INT,
    @FirstName   NVARCHAR(50),
    @LastName    NVARCHAR(50),
    @Email       NVARCHAR(100),
    @Telephone   NVARCHAR(20),
    @IsActive    BIT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE Customers
        SET CustomerFirstName  = @FirstName,
            CustomerLastName   = @LastName,
            Email              = @Email,
            Telephone          = @Telephone,
            IsActive           = @IsActive,
            AccountClosureDate = CASE
                                     WHEN @IsActive = 0 THEN COALESCE(AccountClosureDate, CAST(GETDATE() AS DATE))
                                     ELSE NULL
                                 END
        WHERE CustomerID = @CustomerID;

        IF @@ROWCOUNT = 0
            THROW 50001, 'No customer exists with that CustomerID.', 1;

        COMMIT TRANSACTION;

        SELECT 'Customer updated successfully' AS Result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- Before
SELECT CustomerID, CustomerFirstName, CustomerLastName, Email, Telephone, IsActive, AccountClosureDate
FROM Customers WHERE CustomerID IN (1, 6);

-- Update contact details
EXEC sp_UpdateCustomer
    @CustomerID = 1,
    @FirstName  = 'Emma',
    @LastName   = 'Wilson-Hart',
    @Email      = 'emma.new@email.com',
    @Telephone  = '07111122222',
    @IsActive   = 1;

-- Close a customer: the record is kept and the closure date is recorded
EXEC sp_UpdateCustomer
    @CustomerID = 6,
    @FirstName  = 'Ethan',
    @LastName   = 'Miller',
    @Email      = 'ethan@email.com',
    @Telephone  = NULL,
    @IsActive   = 0;

-- After
SELECT CustomerID, CustomerFirstName, CustomerLastName, Email, Telephone, IsActive, AccountClosureDate
FROM Customers WHERE CustomerID IN (1, 6);

-- An unknown customer is reported, not ignored
BEGIN TRY
    EXEC sp_UpdateCustomer @CustomerID = 999, @FirstName = 'X', @LastName = 'Y',
                           @Email = NULL, @Telephone = NULL, @IsActive = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorReturned;
END CATCH;
GO


-- ============================================================================
-- SECTION 7: VIEW - ALL TRANSACTIONS WITH OVERDUE FEES AND REPAYMENTS
-- ============================================================================
-- INNER JOINs for data every transaction must have; LEFT JOINs for fees and
-- repayments, because most transactions have none.

CREATE OR ALTER VIEW vw_AllTransactionsWithOverdueFees
AS
SELECT
    t.TransactionID,
    CONCAT(c.CustomerFirstName, ' ', c.CustomerLastName) AS CustomerName,
    a.AccountName,
    at.TypeName            AS AccountType,
    t.TransactionDate,
    t.DueDate,
    t.CompletionDate,
    t.Amount,
    t.TransactionType,
    t.Description,
    ofee.FeeAmount,
    ofee.DaysOverdue,
    ofee.TotalOwed,
    ofee.TotalRepaid,
    ofee.OutstandingBalance,
    r.Amount               AS RepaymentAmount,
    r.RepaymentDateTime,
    pm.MethodName          AS PaymentMethod
FROM [Transaction] AS t
INNER JOIN Customers     AS c    ON t.CustomerID      = c.CustomerID
INNER JOIN Account       AS a    ON t.AccountID       = a.AccountID
INNER JOIN AccountType   AS at   ON a.AccountTypeID   = at.AccountTypeID
LEFT  JOIN OverdueFee    AS ofee ON t.TransactionID   = ofee.TransactionID
LEFT  JOIN Repayment     AS r    ON ofee.OverdueFeeID = r.OverdueFeeID
LEFT  JOIN PaymentMethod AS pm   ON r.PaymentMethodID = pm.PaymentMethodID;
GO

SELECT *
FROM vw_AllTransactionsWithOverdueFees
ORDER BY TransactionID, RepaymentDateTime;
GO


-- ============================================================================
-- SECTION 8: TRIGGERS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 8a. tr_AutoUpdateAccountBalance
-- Business rule: an account's balance changes when a transaction is
-- COMPLETED, not when it is first recorded. The trigger fires on INSERT and
-- UPDATE and only applies rows whose CompletionDate has just been set.
--   Deposit                          adds to the balance
--   Payment on a Loan or Credit Card adds to the balance (reduces the debt)
--   Any other Payment, Withdrawal,
--   Transfer or Fee                  subtracts from the balance
-- Changes are summed per account, so multi-row inserts are handled in one
-- update. UPDLOCK and ROWLOCK stop two sessions from updating the same
-- balance at once without blocking other accounts.
-- ----------------------------------------------------------------------------
CREATE OR ALTER TRIGGER tr_AutoUpdateAccountBalance
ON [Transaction]
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    WITH NewlyCompleted AS (
        SELECT i.AccountID, i.TransactionType, i.Amount
        FROM inserted AS i
        LEFT JOIN deleted AS d ON d.TransactionID = i.TransactionID
        WHERE i.CompletionDate IS NOT NULL
          AND (d.TransactionID IS NULL OR d.CompletionDate IS NULL)
    ),
    BalanceChange AS (
        SELECT
            nc.AccountID,
            SUM(CASE
                    WHEN nc.TransactionType = 'Deposit' THEN nc.Amount
                    WHEN nc.TransactionType = 'Payment'
                         AND at.TypeName IN ('Loan', 'Credit Card') THEN nc.Amount
                    ELSE -nc.Amount
                END) AS TotalChange
        FROM NewlyCompleted AS nc
        INNER JOIN Account     AS a  ON a.AccountID      = nc.AccountID
        INNER JOIN AccountType AS at ON at.AccountTypeID = a.AccountTypeID
        GROUP BY nc.AccountID
    )
    UPDATE a WITH (UPDLOCK, ROWLOCK)
    SET a.CurrentBalance = a.CurrentBalance + bc.TotalChange
    FROM Account AS a
    INNER JOIN BalanceChange AS bc ON a.AccountID = bc.AccountID;
END;
GO

-- ----------------------------------------------------------------------------
-- 8b. tr_ClosePaidOffLoanCredit
-- Business rule: when the balance of a Loan or Credit Card account moves from
-- negative (money owed) to zero or above (fully paid), the account status is
-- set to Closed and the closure date is recorded. Comparing the old balance
-- (deleted) with the new one (inserted) means only the payment that clears
-- the debt closes the account; paying part of a loan does not.
-- ----------------------------------------------------------------------------
CREATE OR ALTER TRIGGER tr_ClosePaidOffLoanCredit
ON Account
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(CurrentBalance)
        RETURN;

    DECLARE @ClosedID INT = (SELECT StatusID FROM AccountStatus WHERE StatusName = 'Closed');

    UPDATE a
    SET a.StatusID         = @ClosedID,
        a.ClosedFrozenDate = CAST(GETDATE() AS DATE)
    FROM Account AS a
    INNER JOIN inserted    AS i  ON a.AccountID      = i.AccountID
    INNER JOIN deleted     AS d  ON a.AccountID      = d.AccountID
    INNER JOIN AccountType AS at ON a.AccountTypeID  = at.AccountTypeID
    WHERE at.TypeName IN ('Loan', 'Credit Card')
      AND d.CurrentBalance < 0
      AND i.CurrentBalance >= 0
      AND a.StatusID <> @ClosedID;
END;
GO

-- ----------------------------------------------------------------------------
-- Trigger test: Isabella's loan (AccountID 8) owes 4,200.00
-- ----------------------------------------------------------------------------

-- 1. Before
SELECT a.AccountID, a.AccountName, a.CurrentBalance, s.StatusName, a.ClosedFrozenDate
FROM Account AS a INNER JOIN AccountStatus AS s ON s.StatusID = a.StatusID
WHERE a.AccountID IN (3, 8);

-- 2. A part payment on Liam's loan reduces the debt but does not close it
INSERT INTO [Transaction] (AccountID, CustomerID, CompletionDate, Amount, TransactionType, Description)
VALUES (3, 2, GETDATE(), 500.00, 'Payment', 'Part payment');

-- 3. The final payment on Isabella's loan is recorded as pending:
--    nothing changes yet
INSERT INTO [Transaction] (AccountID, CustomerID, DueDate, CompletionDate, Amount, TransactionType, Description)
VALUES (8, 7, CAST(GETDATE() AS DATE), NULL, 4200.00, 'Payment', 'Final loan payment');

SELECT a.AccountID, a.AccountName, a.CurrentBalance, s.StatusName, a.ClosedFrozenDate
FROM Account AS a INNER JOIN AccountStatus AS s ON s.StatusID = a.StatusID
WHERE a.AccountID IN (3, 8);

-- 4. The final payment completes: the balance reaches zero and the loan closes
UPDATE [Transaction]
SET CompletionDate = GETDATE()
WHERE AccountID = 8
  AND Description = 'Final loan payment'
  AND CompletionDate IS NULL;

-- 5. After
SELECT a.AccountID, a.AccountName, a.CurrentBalance, s.StatusName, a.ClosedFrozenDate
FROM Account AS a INNER JOIN AccountStatus AS s ON s.StatusID = a.StatusID
WHERE a.AccountID IN (3, 8);
GO


-- ============================================================================
-- SECTION 9: CUSTOMERS WHO HAVE REPAID LESS THAN 50% OF THEIR OVERDUE FEES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 9a. View: one row per customer below the 50% threshold
-- HAVING filters on the aggregated totals; NULLIF prevents division by zero.
-- ----------------------------------------------------------------------------
CREATE OR ALTER VIEW vw_CustomersLowRepayment
AS
SELECT
    c.CustomerID,
    CONCAT(c.CustomerFirstName, ' ', c.CustomerLastName) AS CustomerName,
    COUNT(ofee.OverdueFeeID)  AS NumberOfOverdueFees,
    SUM(ofee.TotalOwed)       AS TotalOwed,
    SUM(ofee.TotalRepaid)     AS TotalRepaid,
    CAST(SUM(ofee.TotalRepaid) * 100.0 / NULLIF(SUM(ofee.TotalOwed), 0) AS DECIMAL(5,2)) AS PercentRepaid
FROM Customers AS c
INNER JOIN OverdueFee AS ofee ON c.CustomerID = ofee.CustomerID
GROUP BY c.CustomerID, c.CustomerFirstName, c.CustomerLastName
HAVING SUM(ofee.TotalRepaid) * 1.0 / NULLIF(SUM(ofee.TotalOwed), 0) < 0.5;
GO

-- ----------------------------------------------------------------------------
-- 9b. Scalar function: how many customers are below the threshold
-- ----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION fn_CountCustomersLowRepayment()
RETURNS INT
AS
BEGIN
    RETURN (SELECT COUNT(*) FROM vw_CustomersLowRepayment);
END;
GO

SELECT * FROM vw_CustomersLowRepayment ORDER BY PercentRepaid;

SELECT dbo.fn_CountCustomersLowRepayment() AS CustomersBelow50Percent;
GO


-- ============================================================================
-- SECTION 10: ADDITIONAL OBJECTS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 10a. View: one summary row per customer
-- The transaction count uses a correlated subquery, because joining the
-- transactions in the main query would multiply the account rows and
-- distort the balance total.
-- ----------------------------------------------------------------------------
CREATE OR ALTER VIEW vw_CustomerAccountSummary
AS
SELECT
    c.CustomerID,
    CONCAT(c.CustomerFirstName, ' ', c.CustomerLastName) AS CustomerName,
    ad.City,
    ad.Postcode,
    COUNT(a.AccountID)        AS TotalAccounts,
    SUM(a.CurrentBalance)     AS NetBalanceAcrossAccounts,
    (SELECT COUNT(*)
     FROM [Transaction] AS t
     WHERE t.CustomerID = c.CustomerID) AS TotalTransactions,
    c.IsActive,
    c.CreatedDate             AS CustomerSince
FROM Customers AS c
LEFT JOIN Address AS ad ON c.AddressID  = ad.AddressID
LEFT JOIN Account AS a  ON c.CustomerID = a.CustomerID
GROUP BY c.CustomerID, c.CustomerFirstName, c.CustomerLastName,
         ad.City, ad.Postcode, c.IsActive, c.CreatedDate;
GO

SELECT * FROM vw_CustomerAccountSummary ORDER BY CustomerID;
GO

-- ----------------------------------------------------------------------------
-- 10b. Trigger: keep TotalRepaid in step with the Repayment table
-- Every new repayment is added to its fee's TotalRepaid. The CHECK on
-- OverdueFee stops TotalRepaid going above TotalOwed, so an overpayment is
-- rejected and the repayment insert is rolled back with it.
-- ----------------------------------------------------------------------------
CREATE OR ALTER TRIGGER tr_UpdateTotalRepaid
ON Repayment
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE ofee
    SET ofee.TotalRepaid = ofee.TotalRepaid + x.NewRepayments
    FROM OverdueFee AS ofee
    INNER JOIN (
        SELECT OverdueFeeID, SUM(Amount) AS NewRepayments
        FROM inserted
        GROUP BY OverdueFeeID
    ) AS x ON x.OverdueFeeID = ofee.OverdueFeeID;
END;
GO

-- Before: Olivia's fee (OverdueFeeID 5) is 120.00 owed, 40.00 repaid
SELECT OverdueFeeID, CustomerID, TotalOwed, TotalRepaid, OutstandingBalance
FROM OverdueFee WHERE OverdueFeeID = 5;

-- A 20.00 card repayment
INSERT INTO Repayment (OverdueFeeID, CustomerID, PaymentMethodID, Amount)
VALUES (5, 3, 2, 20.00);

-- After: 60.00 repaid, 60.00 outstanding
SELECT OverdueFeeID, CustomerID, TotalOwed, TotalRepaid, OutstandingBalance
FROM OverdueFee WHERE OverdueFeeID = 5;

-- An overpayment is refused
BEGIN TRY
    INSERT INTO Repayment (OverdueFeeID, CustomerID, PaymentMethodID, Amount)
    VALUES (5, 3, 2, 500.00);
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorReturned;
END CATCH;
GO

-- ----------------------------------------------------------------------------
-- 10c. Query: repayment channel mix
-- How customers pay off overdue fees, for planning collection channels.
-- ----------------------------------------------------------------------------
SELECT
    pm.MethodName                    AS PaymentMethod,
    COUNT(r.RepaymentID)             AS NumberOfRepayments,
    SUM(r.Amount)                    AS TotalRepaid,
    CAST(SUM(r.Amount) * 100.0 / (SELECT SUM(Amount) FROM Repayment) AS DECIMAL(5,2)) AS PercentOfAllRepayments
FROM PaymentMethod AS pm
LEFT JOIN Repayment AS r ON r.PaymentMethodID = pm.PaymentMethodID
GROUP BY pm.MethodName
ORDER BY TotalRepaid DESC;
GO


-- ============================================================================
-- SECTION 11: SECURITY ROLES
-- ============================================================================
-- Staff work through procedures and views, never the base tables. Each role
-- gets only what its job needs.

CREATE ROLE CustomerServiceRole;
CREATE ROLE CollectionsRole;
CREATE ROLE ReportingRole;
GO

GRANT EXECUTE ON sp_SearchAccountsByName TO CustomerServiceRole;
GRANT EXECUTE ON sp_InsertNewCustomer    TO CustomerServiceRole;
GRANT EXECUTE ON sp_UpdateCustomer       TO CustomerServiceRole;

GRANT EXECUTE ON sp_GetDuePayments                 TO CollectionsRole;
GRANT SELECT  ON vw_CustomersLowRepayment          TO CollectionsRole;
GRANT SELECT  ON vw_AllTransactionsWithOverdueFees TO CollectionsRole;
GRANT EXECUTE ON fn_CountCustomersLowRepayment     TO CollectionsRole;

GRANT SELECT ON vw_CustomerAccountSummary         TO ReportingRole;
GRANT SELECT ON vw_AllTransactionsWithOverdueFees TO ReportingRole;
GO
