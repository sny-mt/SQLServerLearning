/* ============================================================
   解答例 08 — ウィンドウ関数
   対象演習: exercises/08_window_functions.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 行を潰さず、各社員に「所属部門の平均給与」を付ける
--     GROUP BY と違い 13 行がそのまま残る。
SELECT EmployeeId, LastName, DepartmentId, Salary,
       AVG(Salary) OVER (PARTITION BY DepartmentId) AS 部門平均給与
FROM   dbo.Employees;

-- Q2. 部門ごとに給与の高い順で順位付け
--     順位関数は OVER 内の ORDER BY が必須。
SELECT DepartmentId, LastName, Salary,
       ROW_NUMBER() OVER (PARTITION BY DepartmentId ORDER BY Salary DESC) AS 部門内順位
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, 部門内順位;

-- Q3. カテゴリ内で単価の高い順に順位付け
SELECT CategoryId, ProductName, UnitPrice,
       ROW_NUMBER() OVER (PARTITION BY CategoryId ORDER BY UnitPrice DESC) AS カテゴリ内順位
FROM   dbo.Products
WHERE  CategoryId IS NOT NULL
ORDER  BY CategoryId, カテゴリ内順位;

-- Q4. 顧客ごとの注文連番(古い順)
--     OrderDate だけだと同日でタイになりうるので OrderId を足して安定させる。
SELECT CustomerId, OrderId, OrderDate,
       ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId) AS 顧客内注文連番
FROM   dbo.Orders
ORDER  BY CustomerId, 顧客内注文連番;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. ROW_NUMBER / RANK / DENSE_RANK の違い(注文件数で顧客を順位付け)
--     ROW_NUMBER … タイでも連番(重複なし)
--     RANK       … タイは同順位、その後は番号が飛ぶ
--     DENSE_RANK … タイは同順位、その後も飛ばない
WITH 注文数 AS (
    SELECT CustomerId,
           COUNT(*) AS 注文件数
    FROM   dbo.Orders
    GROUP  BY CustomerId
)
SELECT CustomerId, 注文件数,
       ROW_NUMBER() OVER (ORDER BY 注文件数 DESC) AS row_number,
       RANK()       OVER (ORDER BY 注文件数 DESC) AS rank,
       DENSE_RANK() OVER (ORDER BY 注文件数 DESC) AS dense_rank
FROM   注文数
ORDER  BY 注文件数 DESC, CustomerId;

-- Q6. 部門内での給与構成比(%)
--     分母を SUM(...) OVER (PARTITION BY ...) にして行を潰さず割り算する。
--     100.0 と掛けることで整数割り算の切り捨てを避ける。
SELECT DepartmentId, LastName, Salary,
       SUM(Salary) OVER (PARTITION BY DepartmentId)                          AS 部門給与合計,
       CAST(100.0 * Salary
            / SUM(Salary) OVER (PARTITION BY DepartmentId) AS DECIMAL(5,1))  AS 部門内構成比_pct
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;

-- Q7. 月別売上と累計(running total)
--     ORDER BY を付けた SUM が累計になる。既定フレーム(RANGE)の落とし穴を避け、
--     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW を明示して 1 行ずつ加算する。
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       SUM(月売上) OVER (ORDER BY 月
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS 累計売上
FROM   月次
ORDER  BY 月;

-- Q8. 月別売上と前月比較(LAG)
--     最初の月は前月がないため 前月売上・前月差 が NULL になる。
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       LAG(月売上) OVER (ORDER BY 月)              AS 前月売上,
       月売上 - LAG(月売上) OVER (ORDER BY 月)      AS 前月差
FROM   月次
ORDER  BY 月;

-- (発展) 前月比(%)も付けたい場合
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月, 月売上,
       LAG(月売上) OVER (ORDER BY 月)                             AS 前月売上,
       CAST(100.0 * 月売上 / LAG(月売上) OVER (ORDER BY 月)
            AS DECIMAL(6,1))                                     AS 前月比_pct
FROM   月次
ORDER  BY 月;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 給与で 4 分割し、最上位の層(=1)だけを取り出す
--     ウィンドウ関数は WHERE で直接使えないので、CTE で層番号を列にしてから絞り込む。
--     13 行 → 4 分割は 4,3,3,3 行に配分され、層 1 は 4 人になる。
WITH 四分位 AS (
    SELECT LastName, Salary,
           NTILE(4) OVER (ORDER BY Salary DESC) AS 給与四分位
    FROM   dbo.Employees
)
SELECT LastName, Salary, 給与四分位
FROM   四分位
WHERE  給与四分位 = 1
ORDER  BY Salary DESC;

-- Q10. LAST_VALUE の罠 —「各部門で最も給与の低い社員名」を全行に付ける
--      ✗ 既定フレームは RANGE ... CURRENT ROW(現在行まで)なので、
--        各行が「その行自身」の値になり、最下位にならない。
SELECT DepartmentId, LastName, Salary,
       LAST_VALUE(LastName) OVER (PARTITION BY DepartmentId ORDER BY Salary DESC) AS 誤_最下位給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;

--      ○ フレームを末尾まで広げると、部門で最も給与の低い人が全行に付く。
SELECT DepartmentId, LastName, Salary,
       LAST_VALUE(LastName) OVER (PARTITION BY DepartmentId ORDER BY Salary DESC
                                  ROWS BETWEEN UNBOUNDED PRECEDING
                                           AND UNBOUNDED FOLLOWING)               AS 部門最下位給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;

--      (別解) FIRST_VALUE を昇順で使えばフレーム指定なしでも最下位が取れる。
SELECT DepartmentId, LastName, Salary,
       FIRST_VALUE(LastName) OVER (PARTITION BY DepartmentId ORDER BY Salary ASC) AS 部門最下位給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;

-- Q11. 直近 3 か月(当月＋前 2 か月)の移動平均
--      先頭付近は存在する月だけで平均される(1 か月目=当月のみ、2 か月目=2 か月平均)。
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月, 月売上,
       AVG(月売上) OVER (ORDER BY 月
                         ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS 三か月移動平均
FROM   月次
ORDER  BY 月;

-- Q12. 顧客ごとの前回注文からの経過日数
--      LAG で前回の OrderDate を持ってきて DATEDIFF で日数を求める。
--      各顧客の初回注文は前回がないため NULL。
SELECT CustomerId, OrderId, OrderDate,
       LAG(OrderDate) OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId) AS 前回注文日,
       DATEDIFF(DAY,
                LAG(OrderDate) OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId),
                OrderDate)                                                       AS 前回からの日数
FROM   dbo.Orders
ORDER  BY CustomerId, OrderDate, OrderId;
