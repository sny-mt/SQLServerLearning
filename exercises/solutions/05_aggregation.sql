/* ============================================================
   解答例 05 — 集計とグループ化
   対象演習: exercises/05_aggregation.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 全社員の件数・合計・平均・最低・最高
SELECT COUNT(*)     AS 社員数,
       SUM(Salary)  AS 給与合計,
       AVG(Salary)  AS 平均給与,
       MIN(Salary)  AS 最低給与,
       MAX(Salary)  AS 最高給与
FROM   dbo.Employees;

-- Q2. 最古・最新の注文日(MIN/MAX は日付にも使える)
SELECT MIN(OrderDate) AS 最古の注文日,
       MAX(OrderDate) AS 最新の注文日
FROM   dbo.Orders;

-- Q3. COUNT の3つの書き方の違い
--     COUNT(*)                     = 13  … 行数そのもの
--     COUNT(Email)                 = 12  … 社員8(中村)は Email が NULL なので数えない
--     COUNT(DepartmentId)          = 12  … 社員13(佐々木)は DepartmentId が NULL なので数えない
--     COUNT(DISTINCT DepartmentId) = 4   … 社員がいる部署は 1〜4 の4種類。NULL は数えない。
--                                          (社員のいない経理部5も現れない)
SELECT COUNT(*)                     AS 全社員,
       COUNT(Email)                 AS Email有り,
       COUNT(DepartmentId)          AS 部署有り,
       COUNT(DISTINCT DepartmentId) AS 部署の種類数
FROM   dbo.Employees;

-- Q4. 部署ごとの人数と平均給与
--     社員13(DepartmentId = NULL)は「NULL のグループ」として1行になる。
SELECT DepartmentId,
       COUNT(*)    AS 人数,
       AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;

-- Q5. カテゴリごとの商品数
--     CategoryId が NULL の商品(19 高級万年筆・20 ノベルティグッズ)は
--     「NULL のグループ」として商品数2にまとまる。
SELECT CategoryId,
       COUNT(*) AS 商品数
FROM   dbo.Products
GROUP  BY CategoryId;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q6. NULL の見出しを「未分類」にする
SELECT ISNULL(CAST(CategoryId AS NVARCHAR(10)), N'未分類') AS カテゴリ,
       COUNT(*) AS 商品数
FROM   dbo.Products
GROUP  BY CategoryId
ORDER  BY CategoryId;    -- NULL は先頭(最小扱い)に並ぶ

-- (別解) CASE でラベル付け
SELECT CASE WHEN CategoryId IS NULL THEN N'未分類'
            ELSE CAST(CategoryId AS NVARCHAR(10)) END AS カテゴリ,
       COUNT(*) AS 商品数
FROM   dbo.Products
GROUP  BY CategoryId
ORDER  BY CategoryId;

-- Q7. 平均給与が 50万超の部署だけ。部署未設定(NULL)は集計前に WHERE で除外。
--     ・WHERE  DepartmentId IS NOT NULL … 集計前の行の絞り込み
--     ・HAVING AVG(Salary) > 500000     … 集計後のグループの絞り込み(集約関数は HAVING に書く)
SELECT DepartmentId,
       COUNT(*)    AS 人数,
       AVG(Salary) AS 平均給与
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
GROUP  BY DepartmentId
HAVING AVG(Salary) > 500000;

-- Q8. 顧客別の売上合計(注文と明細を結合してから集計)
SELECT o.CustomerId,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上合計
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY o.CustomerId
ORDER  BY 売上合計 DESC;

-- Q9. 年・月ごとの売上と注文件数
--     COUNT(*) は明細行数になってしまうので、
--     注文の数は COUNT(DISTINCT o.OrderId) で数える(1注文に複数明細があるため)。
SELECT YEAR(o.OrderDate)  AS 年,
       MONTH(o.OrderDate) AS 月,
       COUNT(DISTINCT o.OrderId) AS 注文件数,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY YEAR(o.OrderDate), MONTH(o.OrderDate)
ORDER  BY 年, 月;

-- Q10. 理由: LastName は集約されておらず、GROUP BY にも含まれていない。
--      グループ内には複数の社員がいるため「どの LastName を返すか」が決まらずエラーになる。
--      GROUP BY を使う SELECT には「GROUP BY の列」か「集約関数」しか書けない。
--      → 意図(部署ごとの平均給与)どおりにするには LastName を外す。
SELECT DepartmentId,
       AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q11. 地域 × 担当ごとの顧客数に、地域ごとの小計と全体総計を ROLLUP で足す
SELECT Region,
       SalesRepId,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY ROLLUP (Region, SalesRepId);

-- Q12. GROUPING() で「小計・総計の行」と「元データの NULL(担当なし)」を見分ける
--      ・GROUPING(SalesRepId) = 1                       → 担当の小計行 →「(小計)」
--      ・GROUPING(SalesRepId) = 0 かつ SalesRepId IS NULL → 元データが担当なし(顧客9・11)→「(担当なし)」
SELECT CASE WHEN GROUPING(Region) = 1     THEN N'(全地域)'
            ELSE ISNULL(Region, N'(地域なし)') END        AS 地域,
       CASE WHEN GROUPING(SalesRepId) = 1 THEN N'(小計)'
            WHEN SalesRepId IS NULL       THEN N'(担当なし)'
            ELSE CAST(SalesRepId AS NVARCHAR(10)) END     AS 担当,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY ROLLUP (Region, SalesRepId)
ORDER  BY GROUPING(Region), Region,
         GROUPING(SalesRepId), SalesRepId;

-- Q13. 「地域ごと」「担当ごと」「総計」だけを GROUPING SETS で列挙する
--      (Region)     … 地域ごと
--      (SalesRepId) … 担当ごと
--      ()           … 総計(グループ化なし)
SELECT Region,
       SalesRepId,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY GROUPING SETS ((Region), (SalesRepId), ());

-- Q14. 主張は「誤り」。
--      COUNT(*)   は行数そのものを数える(列の NULL に関係なく、その行があれば数える)。
--      COUNT(列)  はその列が NULL でない行だけを数える。
--      Employees では Email が NULL の社員8(中村)がいるため、
--      COUNT(*) = 13、COUNT(Email) = 12 と値が食い違う。
--      よって単純な行数が欲しいときは COUNT(*) を使う(置き換えは常には成り立たない)。
SELECT COUNT(*)     AS 全社員,     -- 13
       COUNT(Email) AS Email有り   -- 12(社員8 は Email が NULL)
FROM   dbo.Employees;
