/* ============================================================
   サンプルデータベース: SalesLearning
   目的 : T-SQL クエリ演習用の共通スキーマ
   対象 : SQL Server 2016 以降 (OFFSET-FETCH, STRING_SPLIT 等を使用)
   使い方: 01 → 02 の順に実行する
   ============================================================ */

-- データベースを作り直す (存在すれば削除)
IF DB_ID(N'SalesLearning') IS NOT NULL
BEGIN
    ALTER DATABASE SalesLearning SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SalesLearning;
END;
GO

CREATE DATABASE SalesLearning;
GO

USE SalesLearning;
GO

/* ------------------------------------------------------------
   マスタ系テーブル
   ------------------------------------------------------------ */

-- 部門
CREATE TABLE dbo.Departments
(
    DepartmentId   INT           NOT NULL CONSTRAINT PK_Departments PRIMARY KEY,
    DepartmentName NVARCHAR(50)  NOT NULL,
    Location       NVARCHAR(50)  NULL
);
GO

-- 社員 (ManagerId は自己参照 = 上司)
CREATE TABLE dbo.Employees
(
    EmployeeId   INT            NOT NULL CONSTRAINT PK_Employees PRIMARY KEY,
    FirstName    NVARCHAR(50)   NOT NULL,
    LastName     NVARCHAR(50)   NOT NULL,
    DepartmentId INT            NULL,
    ManagerId    INT            NULL,
    HireDate     DATE           NOT NULL,
    Salary       DECIMAL(10, 0) NOT NULL,
    Email        NVARCHAR(100)  NULL,
    CONSTRAINT FK_Employees_Departments
        FOREIGN KEY (DepartmentId) REFERENCES dbo.Departments (DepartmentId),
    CONSTRAINT FK_Employees_Manager
        FOREIGN KEY (ManagerId)    REFERENCES dbo.Employees   (EmployeeId)
);
GO

-- 商品カテゴリ
CREATE TABLE dbo.Categories
(
    CategoryId   INT          NOT NULL CONSTRAINT PK_Categories PRIMARY KEY,
    CategoryName NVARCHAR(50) NOT NULL
);
GO

-- 商品
CREATE TABLE dbo.Products
(
    ProductId    INT            NOT NULL CONSTRAINT PK_Products PRIMARY KEY,
    ProductName  NVARCHAR(100)  NOT NULL,
    CategoryId   INT            NULL,
    UnitPrice    DECIMAL(10, 0) NOT NULL,
    Discontinued BIT            NOT NULL CONSTRAINT DF_Products_Discontinued DEFAULT (0),
    CONSTRAINT FK_Products_Categories
        FOREIGN KEY (CategoryId) REFERENCES dbo.Categories (CategoryId)
);
GO

-- 顧客
CREATE TABLE dbo.Customers
(
    CustomerId   INT           NOT NULL CONSTRAINT PK_Customers PRIMARY KEY,
    CustomerName NVARCHAR(100) NOT NULL,
    City         NVARCHAR(50)  NULL,
    Region       NVARCHAR(50)  NULL,
    SalesRepId   INT           NULL,   -- 担当営業 = Employees.EmployeeId
    CONSTRAINT FK_Customers_Employees
        FOREIGN KEY (SalesRepId) REFERENCES dbo.Employees (EmployeeId)
);
GO

/* ------------------------------------------------------------
   トランザクション系テーブル
   ------------------------------------------------------------ */

-- 注文ヘッダ
CREATE TABLE dbo.Orders
(
    OrderId    INT  NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerId INT  NOT NULL,
    EmployeeId INT  NULL,          -- 受注担当
    OrderDate  DATE NOT NULL,
    ShipDate   DATE NULL,          -- 未出荷は NULL
    CONSTRAINT FK_Orders_Customers
        FOREIGN KEY (CustomerId) REFERENCES dbo.Customers (CustomerId),
    CONSTRAINT FK_Orders_Employees
        FOREIGN KEY (EmployeeId) REFERENCES dbo.Employees (EmployeeId)
);
GO

-- 注文明細
CREATE TABLE dbo.OrderDetails
(
    OrderId   INT            NOT NULL,
    ProductId INT            NOT NULL,
    Quantity  INT            NOT NULL,
    UnitPrice DECIMAL(10, 0) NOT NULL,   -- 注文時点の単価 (Products.UnitPrice のスナップショット)
    Discount  DECIMAL(4, 2)  NOT NULL CONSTRAINT DF_OrderDetails_Discount DEFAULT (0),  -- 0.00〜1.00
    CONSTRAINT PK_OrderDetails PRIMARY KEY (OrderId, ProductId),
    CONSTRAINT FK_OrderDetails_Orders
        FOREIGN KEY (OrderId)   REFERENCES dbo.Orders   (OrderId),
    CONSTRAINT FK_OrderDetails_Products
        FOREIGN KEY (ProductId) REFERENCES dbo.Products (ProductId)
);
GO

PRINT N'スキーマ作成が完了しました。続けて 02_seed_data.sql を実行してください。';
GO
