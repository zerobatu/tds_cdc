-- ================================================
-- Enable CDC on the database and create test tables
-- ================================================

USE master;
GO

-- Create test database
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'cdc_test')
BEGIN
    CREATE DATABASE cdc_test;
END
GO

USE cdc_test;
GO

-- Enable CDC on the database
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'cdc_test' AND is_cdc_enabled = 1)
BEGIN
    EXEC sys.sp_cdc_enable_db;
END
GO

-- Create test tables
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'users' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE dbo.users (
        id    INT IDENTITY(1,1) PRIMARY KEY,
        name  NVARCHAR(100) NOT NULL,
        email NVARCHAR(255),
        age   INT,
        inserted_at DATETIME2 DEFAULT SYSUTCDATETIME(),
        updated_at DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END
GO

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'orders' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE dbo.orders (
        id         INT IDENTITY(1,1) PRIMARY KEY,
        user_id    INT NOT NULL,
        amount     DECIMAL(10,2) NOT NULL,
        status     NVARCHAR(20) DEFAULT 'pending',
        created_at DATETIME2 DEFAULT SYSUTCDATETIME()
    );
END
GO

-- Enable CDC on the tables
IF NOT EXISTS (SELECT * FROM cdc.change_tables WHERE capture_instance = 'dbo_users')
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name   = N'users',
        @role_name     = NULL;
END
GO

IF NOT EXISTS (SELECT * FROM cdc.change_tables WHERE capture_instance = 'dbo_orders')
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name   = N'orders',
        @role_name     = NULL;
END
GO

-- Insert sample data
INSERT INTO dbo.users (name, email, age) VALUES ('Alice', 'alice@example.com', 30);
INSERT INTO dbo.users (name, email, age) VALUES ('Bob', 'bob@example.com', 25);
INSERT INTO dbo.users (name, email, age) VALUES ('Charlie', 'charlie@example.com', 35);
GO

INSERT INTO dbo.orders (user_id, amount, status) VALUES (1, 99.99, 'pending');
INSERT INTO dbo.orders (user_id, amount, status) VALUES (2, 49.50, 'completed');
GO

-- Verify CDC is working
SELECT capture_instance, object_id, source_object_id FROM cdc.change_tables;
GO

PRINT 'CDC setup completed successfully';
GO