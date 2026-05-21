-- ================================================
-- Enable CDC and create users table
-- ================================================

USE master;
GO

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'cdc_example')
BEGIN
    CREATE DATABASE cdc_example;
END
GO

USE cdc_example;
GO

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'cdc_example' AND is_cdc_enabled = 1)
BEGIN
    EXEC sys.sp_cdc_enable_db;
END
GO

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

IF NOT EXISTS (SELECT * FROM cdc.change_tables WHERE capture_instance = 'dbo_users')
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name   = N'users',
        @role_name     = NULL;
END
GO

INSERT INTO dbo.users (name, email, age) VALUES ('Alice', 'alice@example.com', 30);
INSERT INTO dbo.users (name, email, age) VALUES ('Bob', 'bob@example.com', 25);
INSERT INTO dbo.users (name, email, age) VALUES ('Charlie', 'charlie@example.com', 35);
GO

PRINT 'Setup completed successfully';
GO