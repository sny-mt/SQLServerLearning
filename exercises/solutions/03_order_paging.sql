/* ============================================================
   解答例 03 — 並べ替えとページング
   対象演習: exercises/03_order_paging.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 給与の高い順
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;

-- Q2. 単価の安い順(昇順)。ASC は既定なので省略できる
SELECT ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice ASC;

-- (同じ結果) ASC を省略した形
SELECT ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice;

-- Q3. 部署ID昇順、同部署内は給与の高い順(複数キー)
SELECT DepartmentId, LastName, Salary
FROM   dbo.Employees
ORDER  BY DepartmentId ASC, Salary DESC;

-- Q4. 注文日の古い順。同日は OrderId で安定させる
SELECT OrderId, OrderDate
FROM   dbo.Orders
ORDER  BY OrderDate ASC, OrderId ASC;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 税込単価を別名にし、その別名で並べ替え(ORDER BY では別名が使える)
SELECT ProductName        AS 商品名,
       UnitPrice          AS 単価,
       UnitPrice * 1.1    AS 税込単価
FROM   dbo.Products
ORDER  BY 税込単価 DESC;

-- Q6. 給与トップ3(TOP は ORDER BY と併用する)
SELECT TOP (3) LastName, FirstName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;

-- Q7. 単価の高い商品トップ5
SELECT TOP (5) ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice DESC;

-- Q8. まず Email 昇順。SQL Server は NULL を最小扱いにするため、
--     昇順では NULL(社員8 中村)が先頭に来る。
SELECT EmployeeId, LastName, Email
FROM   dbo.Employees
ORDER  BY Email ASC;

-- NULL を必ず末尾に回し、それ以外は Email 昇順にする
SELECT EmployeeId, LastName, Email
FROM   dbo.Employees
ORDER  BY CASE WHEN Email IS NULL THEN 1 ELSE 0 END,  -- NULL を後ろへ
          Email ASC;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 給与の高い順で 4〜6位(4件目から3件)を OFFSET-FETCH で
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC
OFFSET 3 ROWS               -- 上位3件を飛ばす
FETCH  NEXT 3 ROWS ONLY;    -- そこから3件

-- Q10. 1ページ4件・3ページ目。OFFSET = (p - 1) * size = (3-1)*4 = 8
--      注文日の古い順、同日は OrderId 順で安定させる。
SELECT OrderId, OrderDate
FROM   dbo.Orders
ORDER  BY OrderDate ASC, OrderId ASC
OFFSET (3 - 1) * 4 ROWS
FETCH  NEXT 4 ROWS ONLY;

-- Q11. TOP (3) と TOP (3) WITH TIES の比較
--      WITH TIES は「最後の行(3位)と ORDER BY キー(Salary)が同値の行」を
--      すべて含めるため、3位と同額の社員がいれば 3 件を超えて返る。
--      このデータの給与は全員異なるため、実際には両者とも 3 件で一致する。
--      (WITH TIES は ORDER BY が必須である点にも注意。)
SELECT TOP (3) LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;

SELECT TOP (3) WITH TIES LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;

-- Q12. 主張は「誤り」。
--      ORDER BY を書かないかぎり結果の順序は一切保証されない。
--      主キー順に見えるのは偶然で、インデックスの選択・並列実行・データ変化などで
--      同じクエリでも並びが変わりうる。順序が意味を持つなら必ず ORDER BY を書く。
--      ORDER BY 無しの TOP (3) は「どの3件が返るか」自体が不定になり危険。
--      → 意図した上位3件を得るには ORDER BY が必須。
SELECT TOP (3) LastName, Salary
FROM   dbo.Employees;         -- ✗ どの3件が返るか不定(順序保証なし)

SELECT TOP (3) LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;        -- ○ 給与上位3件が確実に返る
