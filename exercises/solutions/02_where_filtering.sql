/* ============================================================
   解答例 02 — WHERE による絞り込み
   対象演習: exercises/02_where_filtering.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 単価 10000 円以上の商品
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  UnitPrice >= 10000;

-- Q2. 給与が 60万円ちょうどではない社員
--     ※ Salary は NULL を含まないため <> でも漏れは無いが、
--        NULL を含む列だと <> は NULL 行を落とす点に注意(Q7 参照)。
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  Salary <> 600000;

-- Q3. 単価 1000〜5000 円(両端含む)
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  UnitPrice BETWEEN 1000 AND 5000;

-- Q4. 部署 1・2・3 のいずれか
SELECT LastName, FirstName, DepartmentId
FROM   dbo.Employees
WHERE  DepartmentId IN (1, 2, 3);

-- Q5. 「ノート」で始まる商品(ノートPC, ノートA5)
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  ProductName LIKE N'ノート%';

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q6. (営業部 または 開発部) かつ 給与 50万円以上
--     括弧で OR を先にまとめ、AND の優先順位に負けないようにする。
SELECT LastName, FirstName, DepartmentId, Salary
FROM   dbo.Employees
WHERE  (DepartmentId = 1 OR DepartmentId = 2)
  AND  Salary >= 500000;

-- Q7. Email が未登録(NULL)の社員(中村大輔)
--     IS NULL を使う。= NULL では取れない(NULL = NULL は UNKNOWN)。
SELECT EmployeeId, LastName, FirstName, Email
FROM   dbo.Employees
WHERE  Email IS NULL;

-- (確認) 下は 0 件になる。= では NULL を判定できないため。
SELECT EmployeeId, LastName, Email
FROM   dbo.Employees
WHERE  Email = NULL;

-- Q8. 担当営業が未割り当ての顧客(イオタ商会・ラムダソフト)
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId IS NULL;

-- Q9. カテゴリ未分類の商品(高級万年筆・ノベルティグッズ)
SELECT ProductName, CategoryId
FROM   dbo.Products
WHERE  CategoryId IS NULL;

-- Q10. 市に「東」を含む顧客(東京の顧客)
SELECT CustomerName, City
FROM   dbo.Customers
WHERE  City LIKE N'%東%';

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q11. 理由: 優先順位は NOT → AND → OR の順。
--       括弧なしだと AND が先に結合し、
--       「DepartmentId=1」または「DepartmentId=2 かつ Salary>=500000」
--       と解釈され、営業部の低給与者まで含んでしまう。
--       → OR を括弧でまとめて意図を固定する。
SELECT LastName, DepartmentId, Salary
FROM   dbo.Employees
WHERE  (DepartmentId = 1 OR DepartmentId = 2)
  AND  Salary >= 500000;

-- Q12. 理由: NOT IN (2, 3, NULL) は
--       SalesRepId <> 2 AND SalesRepId <> 3 AND SalesRepId <> NULL
--       と同義。最後の "<> NULL" は必ず UNKNOWN になり、
--       TRUE AND UNKNOWN = UNKNOWN のため全行が除外され 0 件になる。
--       → リストから NULL を除く。
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId NOT IN (2, 3);

-- (別解) 担当が未割り当て(NULL)の顧客も含めたい場合は
--        OR ... IS NULL を明示的に足す。
--        NOT IN の対象列が NULL の行(NULL <> 2 が UNKNOWN)は
--        そのままでは出てこないため。
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId NOT IN (2, 3)
   OR  SalesRepId IS NULL;

-- Q13. 一度も注文していない顧客(ラムダソフト)
--      NOT EXISTS は「一致する行が存在しない」を評価するだけで、
--      NULL 同士の比較を行わないため NOT IN のような NULL の罠が無い。
SELECT c.CustomerName, c.SalesRepId
FROM   dbo.Customers AS c
WHERE  NOT EXISTS (
           SELECT 1
           FROM   dbo.Orders AS o
           WHERE  o.CustomerId = c.CustomerId
       );

-- Q14. 姓が「佐」または「山」で始まる社員
--      (佐藤太郎・山本恵・山田誠・佐々木彩)
SELECT LastName, FirstName
FROM   dbo.Employees
WHERE  LastName LIKE N'[佐山]%';
