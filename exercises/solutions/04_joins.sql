/* ============================================================
   解答例 04 — テーブル結合 (JOIN)
   対象演習: exercises/04_joins.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 社員と所属部署名 (INNER JOIN)
--     部署 NULL の佐々木彩、社員のいない経理部は現れない。
SELECT e.LastName        AS 社員,
       d.DepartmentName  AS 部署
FROM   dbo.Employees   AS e
INNER JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId;

-- Q2. 商品とカテゴリ名 (INNER JOIN)
--     CategoryId が NULL の高級万年筆・ノベルティグッズは落ちる。
SELECT p.ProductName  AS 商品名,
       c.CategoryName AS カテゴリ
FROM   dbo.Products   AS p
INNER JOIN dbo.Categories AS c
       ON p.CategoryId = c.CategoryId;

-- Q3. すべての社員を残す (LEFT JOIN)
--     佐々木彩は部署名 NULL で現れる。
SELECT e.LastName        AS 社員,
       d.DepartmentName  AS 部署
FROM   dbo.Employees   AS e
LEFT JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId
ORDER BY e.EmployeeId;

-- Q4. すべての部署を残す (Departments を左に LEFT JOIN)
--     社員のいない経理部が、社員側 NULL で現れる。
SELECT d.DepartmentName  AS 部署,
       e.LastName        AS 社員
FROM   dbo.Departments AS d
LEFT JOIN dbo.Employees AS e
       ON e.DepartmentId = d.DepartmentId
ORDER BY d.DepartmentId;

-- (別解) Employees を左にした RIGHT JOIN でも同じ結果になる。
-- SELECT d.DepartmentName, e.LastName
-- FROM   dbo.Employees   AS e
-- RIGHT JOIN dbo.Departments AS d ON e.DepartmentId = d.DepartmentId;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 顧客と担当営業 (SalesRepId → EmployeeId)
--     担当未設定の顧客も残し、代替表示する。
SELECT c.CustomerName                     AS 顧客,
       ISNULL(e.LastName, N'(担当未設定)') AS 担当営業
FROM   dbo.Customers AS c
LEFT JOIN dbo.Employees AS e
       ON c.SalesRepId = e.EmployeeId
ORDER BY c.CustomerId;

-- Q6. 注文 × 顧客 × 受注担当社員
SELECT o.OrderId,
       o.OrderDate,
       c.CustomerName  AS 顧客,
       e.LastName      AS 受注担当
FROM   dbo.Orders    AS o
INNER JOIN dbo.Customers AS c ON o.CustomerId = c.CustomerId
INNER JOIN dbo.Employees AS e ON o.EmployeeId = e.EmployeeId
ORDER BY o.OrderId;

-- Q7. 注文明細の売上一覧 (4テーブル結合)
SELECT o.OrderId,
       c.CustomerName AS 顧客,
       p.ProductName  AS 商品,
       od.Quantity * od.UnitPrice * (1 - od.Discount) AS 明細売上
FROM   dbo.Orders        AS o
INNER JOIN dbo.Customers     AS c  ON o.CustomerId = c.CustomerId
INNER JOIN dbo.OrderDetails  AS od ON o.OrderId    = od.OrderId
INNER JOIN dbo.Products      AS p  ON od.ProductId = p.ProductId
ORDER BY o.OrderId, p.ProductName;

-- Q8. 自己結合: 社員とその上司
--     社長(ManagerId=NULL)も残すため LEFT JOIN。
SELECT e.LastName AS 社員,
       m.LastName AS 上司
FROM   dbo.Employees AS e
LEFT JOIN dbo.Employees AS m
       ON e.ManagerId = m.EmployeeId
ORDER BY e.EmployeeId;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 注文が1件もない顧客 (LEFT JOIN + IS NULL)
--     → ラムダソフトだけが残る。
SELECT c.CustomerName AS 顧客
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o ON c.CustomerId = o.CustomerId
WHERE  o.OrderId IS NULL;

-- Q10. (A) と (B) の違いの説明
--   (A) 右側テーブル Orders の条件 (ShipDate IS NOT NULL) を ON に書いている。
--       LEFT JOIN は左表 Customers を全行残すため、注文のない顧客(ラムダソフト)も
--       Orders 側 NULL で結果に残る。ON の条件は「どの注文を結び付けるか」を絞るだけ。
--   (B) 同じ条件を WHERE に書いている。注文のない顧客は o.ShipDate が NULL のまま
--       WHERE に渡り、NULL IS NOT NULL は偽なので捨てられる。
--       → LEFT JOIN が実質 INNER JOIN に化け、注文のない顧客は消える。
--   結論: 外部結合で「残したい側」を守る条件は ON に、結果を絞る条件は WHERE に書く。

-- (A) 再掲: 注文のない顧客も残る
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
      AND o.ShipDate IS NOT NULL
ORDER BY c.CustomerId;

-- (B) 再掲: 実質 INNER になり、注文のない顧客は消える
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
WHERE  o.ShipDate IS NOT NULL
ORDER BY c.CustomerId;

-- Q11. FULL OUTER JOIN: 社員のいない部署 も 部署のない社員 も両方残る
--      経理部(社員 NULL)と佐々木彩(部署名 NULL)が同じ結果に現れる。
SELECT d.DepartmentName AS 部署,
       e.LastName       AS 社員
FROM   dbo.Employees   AS e
FULL OUTER JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId
ORDER BY d.DepartmentId, e.EmployeeId;
