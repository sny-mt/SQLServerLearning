/* ============================================================
   解答例 10 — PIVOT / UNPIVOT
   対象演習: exercises/10_pivot_unpivot.md
   売上 = Quantity * UnitPrice * (1 - Discount)
   年 = YEAR(OrderDate) / 四半期 = DATEPART(QUARTER, OrderDate)
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 地域 × 年 の売上を PIVOT で
--     ソースは「地域・年・売上」の3列だけに絞るのが鉄則。
SELECT *
FROM (
    SELECT c.Region                                        AS 地域,
           YEAR(o.OrderDate)                               AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount)  AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT (
    SUM(売上)
    FOR 年 IN ([2023], [2024])
) AS pvt;

-- Q2. Q1 と同じ結果を SUM(CASE WHEN ...) で
--     CASE は該当年だけ売上を返し、それ以外は NULL。SUM が NULL を無視する。
SELECT c.Region AS 地域,
       SUM(CASE WHEN YEAR(o.OrderDate) = 2023
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2023],
       SUM(CASE WHEN YEAR(o.OrderDate) = 2024
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2024]
FROM   dbo.Orders       AS o
JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
GROUP  BY c.Region;

-- Q3. 地域 × 年 の注文件数を PIVOT (COUNT) で
--     OrderDetails は結合しない(結合すると1注文が明細数だけ重複して数えられる)。
--     COUNT なので該当なしのセルは 0 になる。
SELECT *
FROM (
    SELECT c.Region          AS 地域,
           YEAR(o.OrderDate)  AS 年,
           o.OrderId
    FROM   dbo.Orders    AS o
    JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId
) AS src
PIVOT (
    COUNT(OrderId)
    FOR 年 IN ([2023], [2024])
) AS pvt;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q4. カテゴリ × 年 の売上を CASE 集計で
--     Categories を内部結合するので CategoryId が NULL の商品は自然に除外される。
SELECT cat.CategoryName AS カテゴリ,
       SUM(CASE WHEN YEAR(o.OrderDate) = 2023
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2023],
       SUM(CASE WHEN YEAR(o.OrderDate) = 2024
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2024]
FROM   dbo.OrderDetails AS od
JOIN   dbo.Orders       AS o   ON o.OrderId     = od.OrderId
JOIN   dbo.Products     AS p   ON p.ProductId   = od.ProductId
JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
GROUP  BY cat.CategoryName;

-- Q5. Q4 の空セルを 0 表示に(COALESCE を被せるだけ)
SELECT cat.CategoryName AS カテゴリ,
       COALESCE(SUM(CASE WHEN YEAR(o.OrderDate) = 2023
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END), 0) AS [2023],
       COALESCE(SUM(CASE WHEN YEAR(o.OrderDate) = 2024
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END), 0) AS [2024]
FROM   dbo.OrderDetails AS od
JOIN   dbo.Orders       AS o   ON o.OrderId     = od.OrderId
JOIN   dbo.Products     AS p   ON p.ProductId   = od.ProductId
JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
GROUP  BY cat.CategoryName;

-- Q6. 横持ち(カテゴリ × Q1..Q4)を UNPIVOT で縦持ちに
--     売上が NULL の四半期は行ごと落ちる(UNPIVOT の仕様)。
WITH 横持ち AS (
    SELECT cat.CategoryName AS カテゴリ,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=1
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q1,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=2
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q2,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=3
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q3,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=4
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q4
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Orders       AS o   ON o.OrderId     = od.OrderId
    JOIN   dbo.Products     AS p   ON p.ProductId   = od.ProductId
    JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
    WHERE  YEAR(o.OrderDate) = 2023
    GROUP  BY cat.CategoryName
)
SELECT カテゴリ, 四半期, 売上
FROM   横持ち
UNPIVOT (
    売上 FOR 四半期 IN (Q1, Q2, Q3, Q4)
) AS up
ORDER  BY カテゴリ, 四半期;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q7. 理由: ソースを SELECT * にしたため、OrderId・CustomerId・OrderDate など
--     「集約対象でも FOR 列でもない列」がすべて暗黙のグループ化キーになってしまう。
--     その結果、行が地域単位にまとまらず表が崩れる。
--     → ソースを「地域・年・売上」の3列だけに絞る(= Q1 と同じ形にする)。
SELECT *
FROM (
    SELECT c.Region                                        AS 地域,
           YEAR(o.OrderDate)                               AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount)  AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT (
    SUM(売上)
    FOR 年 IN ([2023], [2024])
) AS pvt;

-- Q8. UNPIVOT を使わず CROSS APPLY (VALUES ...) で縦持ちに。
--     違い: UNPIVOT(Q6)は売上が NULL の四半期を落とすが、
--     CROSS APPLY + VALUES は NULL の四半期も 1 行として残す(全カテゴリ×4行)。
--     ラベル(N'Q1' 等)を自分で書けるのも利点。
WITH 横持ち AS (
    SELECT cat.CategoryName AS カテゴリ,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=1
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q1,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=2
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q2,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=3
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q3,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=4
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q4
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Orders       AS o   ON o.OrderId     = od.OrderId
    JOIN   dbo.Products     AS p   ON p.ProductId   = od.ProductId
    JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
    WHERE  YEAR(o.OrderDate) = 2023
    GROUP  BY cat.CategoryName
)
SELECT h.カテゴリ, v.四半期, v.売上
FROM   横持ち AS h
CROSS  APPLY (VALUES (N'Q1', h.Q1),
                     (N'Q2', h.Q2),
                     (N'Q3', h.Q3),
                     (N'Q4', h.Q4)) AS v(四半期, 売上)
ORDER  BY h.カテゴリ, v.四半期;

-- Q9. 動的 PIVOT: 対象年を手で書かず、実データから列見出しを組み立てる。
--     STRING_AGG は SQL Server 2017 以降。QUOTENAME でインジェクション対策も兼ねる。
DECLARE @cols NVARCHAR(MAX);
DECLARE @sql  NVARCHAR(MAX);

-- ① 実際に存在する年の一覧を [ ] 付きで連結
SELECT @cols = STRING_AGG(QUOTENAME(年), N', ')
FROM (SELECT DISTINCT YEAR(OrderDate) AS 年 FROM dbo.Orders) AS y;

-- ② PIVOT 文を文字列として組み立て
SET @sql = N'
SELECT *
FROM (
    SELECT c.Region AS 地域,
           YEAR(o.OrderDate) AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt;';

-- ③ 実行
EXEC sys.sp_executesql @sql;
