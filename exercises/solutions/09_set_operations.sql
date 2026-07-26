/* ============================================================
   解答例 09 — 集合演算 (UNION など)
   対象演習: exercises/09_set_operations.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 東京の顧客名と東京の部門名を縦に1列で(重複はそのまま)
SELECT CustomerName AS 名称
FROM   dbo.Customers
WHERE  City = N'東京'
UNION ALL
SELECT DepartmentName
FROM   dbo.Departments
WHERE  Location = N'東京';

-- Q2. 市と所在地を1列にまとめ、重複を除いて一覧
SELECT City AS 地名
FROM   dbo.Customers
UNION
SELECT Location
FROM   dbo.Departments;

-- Q3. UNION ALL に変えて違いを確認
--     UNION は結果全体で重複を1つにまとめる(内部で並べ替え/ハッシュが走る)。
--     UNION ALL は重複チェックをせずそのまま縦連結するので、
--     同じ地名が複数回現れ、重複排除がない分だけ速い。
SELECT City AS 地名
FROM   dbo.Customers
UNION ALL
SELECT Location
FROM   dbo.Departments;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q4. 担当あり顧客の担当社員Id と 担当なし顧客 を区分ラベル付きで縦に並べる
SELECT SalesRepId AS 社員Id, N'担当あり' AS 区分
FROM   dbo.Customers
WHERE  SalesRepId IS NOT NULL
UNION ALL
SELECT SalesRepId, N'担当なし'
FROM   dbo.Customers
WHERE  SalesRepId IS NULL;

-- Q5. 注文実績のある顧客Id と、注文なし顧客Id
-- 注文実績あり
SELECT DISTINCT CustomerId
FROM   dbo.Orders;

-- 注文なし(全顧客 − 注文実績のある顧客) → 顧客11(ラムダソフト)だけが残る
SELECT CustomerId FROM dbo.Customers
EXCEPT
SELECT CustomerId FROM dbo.Orders;

-- Q6. 顧客の担当社員 と 受注担当社員 の両方に現れる社員Id
SELECT SalesRepId FROM dbo.Customers WHERE SalesRepId IS NOT NULL
INTERSECT
SELECT EmployeeId FROM dbo.Orders    WHERE EmployeeId IS NOT NULL;

-- Q7. Q1 を名称の昇順に(ORDER BY は全体の末尾に1つだけ)
SELECT CustomerName AS 名称
FROM   dbo.Customers
WHERE  City = N'東京'
UNION ALL
SELECT DepartmentName
FROM   dbo.Departments
WHERE  Location = N'東京'
ORDER  BY 名称;          -- 先頭SELECTの別名で指定。ORDER BY 1 でも可

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q8. 理由: 1つ目の SELECT は2列(CustomerName, City)だが
--     2つ目の SELECT は1列(DepartmentName)しかなく、列数が揃っていない。
--     集合演算は各 SELECT の列数を揃える必要があるためエラーになる。
--     → 列数を合わせる(所在地の列を足す)。列名は先頭SELECTが採用される。
SELECT CustomerName AS 名称, City AS 地
FROM   dbo.Customers
WHERE  City = N'東京'
UNION ALL
SELECT DepartmentName, Location
FROM   dbo.Departments
WHERE  Location = N'東京';

-- Q9. 注文なし顧客を NOT EXISTS で(CustomerId と CustomerName の2列)
SELECT c.CustomerId, c.CustomerName
FROM   dbo.Customers AS c
WHERE  NOT EXISTS (SELECT 1
                   FROM   dbo.Orders AS o
                   WHERE  o.CustomerId = c.CustomerId);
--   ・EXCEPT 版: 「Id集合の差」を取るだけなら簡潔で読みやすい。
--   ・NOT EXISTS 版: 顧客名など他の列も一緒に返したいときや、
--     相関条件が複雑なときに向く。NULL があっても安全(NOT IN と違い誤動作しない)。

-- Q10. 集合演算での NULL の扱い
--      担当NULLの顧客が複数いても、UNION は NULL どうしを「同一」とみなすため、
--      さらに NULL を1行足しても、結果に現れる NULL はちょうど1つだけになる。
--      (通常の比較 NULL = NULL は「不明」だが、集合演算の重複判定では真の扱い)
SELECT SalesRepId FROM dbo.Customers
UNION
SELECT NULL;
