/* ============================================================
   解答例 06 — サブクエリ
   対象演習: exercises/06_subqueries.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 全社平均給与より高い社員(スカラーサブクエリ)
--     平均はおよそ 55.2 万円。佐藤・鈴木・伊藤・渡辺・小林・吉田が該当。
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  Salary > (SELECT AVG(Salary) FROM dbo.Employees);

-- Q2. 一度でも注文された商品(IN + サブクエリ)
SELECT ProductName
FROM   dbo.Products
WHERE  ProductId IN (SELECT ProductId FROM dbo.OrderDetails);

-- Q3. 廃番商品を除いた商品(NOT IN で廃番の ProductId 集合を除外)
--     集合側の ProductId は NOT NULL なので NOT IN でも安全。
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  ProductId NOT IN (
           SELECT ProductId
           FROM   dbo.Products
           WHERE  Discontinued = 1
       );

-- (別解) この単純なケースなら直接書くほうが明快
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  Discontinued = 0;

-- Q4. 各顧客の注文件数(SELECT 内の相関スカラーサブクエリ)
--     注文の無い顧客(ラムダソフト)は 0 件になる。
SELECT c.CustomerName,
       ( SELECT COUNT(*)
         FROM   dbo.Orders AS o
         WHERE  o.CustomerId = c.CustomerId ) AS 注文件数
FROM   dbo.Customers AS c;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 一度も注文していない顧客(NOT EXISTS)。該当はラムダソフト。
SELECT c.CustomerName, c.City
FROM   dbo.Customers AS c
WHERE  NOT EXISTS ( SELECT 1
                    FROM   dbo.Orders AS o
                    WHERE  o.CustomerId = c.CustomerId );

-- Q6. 各部門で最高給の社員(相関サブクエリ)
--     結果: 佐藤(営業) / 伊藤(開発) / 小林(マーケ) / 吉田(人事)。
--     部署未定の佐々木は内側 MAX が NULL となり除外される。
SELECT e.LastName,
       e.DepartmentId,
       e.Salary
FROM   dbo.Employees AS e
WHERE  e.Salary = ( SELECT MAX(e2.Salary)
                    FROM   dbo.Employees AS e2
                    WHERE  e2.DepartmentId = e.DepartmentId );

-- Q7. 部門ごとの平均給与を派生テーブルにし、平均 50万円以上の部門を出す。
--     派生テーブルには別名(d)が必須。
SELECT d.DepartmentId,
       d.平均給与
FROM   ( SELECT DepartmentId,
                AVG(Salary) AS 平均給与
         FROM   dbo.Employees
         WHERE  DepartmentId IS NOT NULL
         GROUP  BY DepartmentId ) AS d
WHERE  d.平均給与 >= 500000;

-- Q8. 開発部(2)の誰よりも高給の社員(> ALL)。
--     開発部の最高給は伊藤の78万。それを上回るのは佐藤(95万)だけ。
SELECT LastName, Salary
FROM   dbo.Employees
WHERE  Salary > ALL ( SELECT Salary
                      FROM   dbo.Employees
                      WHERE  DepartmentId = 2 );

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 理由: Customers.SalesRepId には NULL(担当なしの顧客)が含まれる。
--     NOT IN は x <> 2 AND x <> 3 AND x <> 4 AND x <> NULL と同義で、
--     x <> NULL が常に UNKNOWN になるため全体が TRUE になれず 0 件になる。
--     → NOT EXISTS で書き換える(NULL に影響されない)。
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  NOT EXISTS ( SELECT 1
                    FROM   dbo.Customers AS c
                    WHERE  c.SalesRepId = e.EmployeeId );

-- (別解) NOT IN のままにするなら、サブクエリ側で NULL を除外する
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  e.EmployeeId NOT IN ( SELECT c.SalesRepId
                             FROM   dbo.Customers AS c
                             WHERE  c.SalesRepId IS NOT NULL );

-- Q10. 担当営業が、その顧客の注文の受注担当も務めている顧客(EXISTS)
SELECT c.CustomerName, c.SalesRepId
FROM   dbo.Customers AS c
WHERE  EXISTS ( SELECT 1
                FROM   dbo.Orders AS o
                WHERE  o.CustomerId = c.CustomerId
                  AND  o.EmployeeId = c.SalesRepId );

-- Q11. 廃番でない商品を NOT EXISTS で(廃番集合に自分が無いことを見る)
SELECT p.ProductName, p.UnitPrice
FROM   dbo.Products AS p
WHERE  NOT EXISTS ( SELECT 1
                    FROM   dbo.Products AS d
                    WHERE  d.ProductId = p.ProductId
                      AND  d.Discontinued = 1 );

-- (発展) 注文明細に一度でも登場した、廃番でない商品
SELECT p.ProductName, p.UnitPrice
FROM   dbo.Products AS p
WHERE  p.Discontinued = 0
  AND  EXISTS ( SELECT 1
                FROM   dbo.OrderDetails AS od
                WHERE  od.ProductId = p.ProductId );
