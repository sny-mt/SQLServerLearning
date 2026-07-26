/* ============================================================
   解答例 01 — SELECT の基礎
   対象演習: exercises/01_select_basics.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 商品名と単価の2列
SELECT ProductName, UnitPrice
FROM   dbo.Products;

-- Q2. 日本語の別名を付ける
SELECT ProductName AS 商品名,
       UnitPrice   AS 単価
FROM   dbo.Products;

-- Q3. 市の一覧を重複なく
SELECT DISTINCT City
FROM   dbo.Customers;

-- Q4. 姓名を連結した氏名 (姓 名)
SELECT LastName + N' ' + FirstName AS 氏名
FROM   dbo.Employees;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 税込単価(10%)
SELECT ProductName        AS 商品名,
       UnitPrice          AS 単価,
       UnitPrice * 1.1    AS 税込単価
FROM   dbo.Products;

-- Q6. 市と地域の組み合わせを重複なく
SELECT DISTINCT City, Region
FROM   dbo.Customers;

-- Q7. Email をそのまま表示 (NULL の見え方を確認)
--     社員8(中村)と、Email 未登録の社員が NULL 表示になる。
SELECT EmployeeId, LastName, FirstName, Email
FROM   dbo.Employees;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q8. 理由: WHERE は SELECT より先に評価されるため、
--     SELECT で定義した別名「税込単価」を WHERE では参照できない。
--     → 式を直接書く(または CTE/サブクエリにする)。
SELECT UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
WHERE  UnitPrice * 1.1 > 10000;

-- (別解) CTE で一度列にしてから絞り込む
WITH P AS (
    SELECT ProductName,
           UnitPrice * 1.1 AS 税込単価
    FROM   dbo.Products
)
SELECT * FROM P
WHERE  税込単価 > 10000;

-- Q9. + 連結 と CONCAT の NULL 挙動の違い
--     Email が NULL の社員では、+ 連結の結果は行全体が NULL になるが、
--     CONCAT は NULL を空文字として扱うため氏名部分は残る。
SELECT LastName + FirstName AS 氏名,
       LastName + FirstName + N'/' + Email        AS 連結_プラス,
       CONCAT(LastName, FirstName, N'/', Email)   AS 連結_CONCAT
FROM   dbo.Employees;
