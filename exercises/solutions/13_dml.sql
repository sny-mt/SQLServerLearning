/* ============================================================
   解答例 13 — データ操作 (INSERT / UPDATE / DELETE / MERGE)
   対象演習: exercises/13_dml.md
   ------------------------------------------------------------
   ★重要: 本章はデータを実際に書き換える。サンプルDBを壊さないため、
     すべての解答を BEGIN TRAN ... ROLLBACK で囲む(または一時テーブル
     #… を使う)。COMMIT は絶対にしないこと。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 新規社員を1人追加(列リストは必ず明示)
BEGIN TRAN;

INSERT INTO dbo.Employees
    (EmployeeId, FirstName, LastName, DepartmentId, ManagerId, HireDate, Salary, Email)
VALUES
    (14, N'翔太', N'新井', 1, 1, '2024-04-01', 400000, N'arai@example.com');

SELECT * FROM dbo.Employees WHERE EmployeeId = 14;   -- 確認

ROLLBACK;   -- 元に戻す


-- Q2. 複数行を1文で追加
BEGIN TRAN;

INSERT INTO dbo.Categories (CategoryId, CategoryName)
VALUES
    (6, N'雑貨'),
    (7, N'ソフトウェア');

SELECT * FROM dbo.Categories ORDER BY CategoryId;    -- 確認

ROLLBACK;


-- Q3. 商品2の単価を10%値下げ
BEGIN TRAN;

UPDATE dbo.Products
SET    UnitPrice = UnitPrice * 0.9
WHERE  ProductId = 2;

SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;

ROLLBACK;


-- Q4. Categories から書籍(5)を削除
BEGIN TRAN;

DELETE FROM dbo.Categories
WHERE  CategoryId = 5;

SELECT @@ROWCOUNT AS 削除行数;    -- 1 のはず

ROLLBACK;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. UPDATE ... FROM で開発部の社員を5%昇給
BEGIN TRAN;

UPDATE e
SET    e.Salary = e.Salary * 1.05
FROM   dbo.Employees   AS e
JOIN   dbo.Departments AS d ON d.DepartmentId = e.DepartmentId
WHERE  d.DepartmentName = N'開発部';

SELECT EmployeeId, LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  DepartmentId = 2                -- 開発部
ORDER  BY EmployeeId;

ROLLBACK;


-- Q6. 廃番かつ注文明細で未使用の商品を削除
--     廃番は 5(USBハブ) と 12(ホチキス)。注文で使われている方は
--     NOT EXISTS で除外され、参照整合性違反も避けられる。
BEGIN TRAN;

DELETE p
FROM   dbo.Products AS p
WHERE  p.Discontinued = 1
  AND  NOT EXISTS (SELECT 1 FROM dbo.OrderDetails AS od
                   WHERE od.ProductId = p.ProductId);

SELECT @@ROWCOUNT AS 削除行数;

ROLLBACK;


-- Q7. INSERT ... SELECT で売上集計を一時テーブルへ
BEGIN TRAN;

CREATE TABLE #SalesSummary (
    ProductId   INT PRIMARY KEY,
    ProductName NVARCHAR(100),
    合計数量     INT,
    売上合計     DECIMAL(18,2)
);

INSERT INTO #SalesSummary (ProductId, ProductName, 合計数量, 売上合計)
SELECT p.ProductId,
       p.ProductName,
       SUM(od.Quantity),
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
FROM   dbo.OrderDetails AS od
JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
GROUP  BY p.ProductId, p.ProductName;

SELECT * FROM #SalesSummary ORDER BY 売上合計 DESC;

ROLLBACK;   -- #SalesSummary も破棄される
-- 補足: 一時テーブルはセッション終了で自動削除されるが、
--       明示的に消したいなら DROP TABLE #SalesSummary; とする。


-- Q8. OUTPUT 句で昇給前後の給与を出力(人事部を3%昇給)
BEGIN TRAN;

UPDATE e
SET    e.Salary = e.Salary * 1.03
OUTPUT inserted.EmployeeId,
       deleted.Salary  AS 昇給前,
       inserted.Salary AS 昇給後
FROM   dbo.Employees   AS e
JOIN   dbo.Departments AS d ON d.DepartmentId = e.DepartmentId
WHERE  d.DepartmentName = N'人事部';

ROLLBACK;

-- (別解) DepartmentId を直接指定してもよい(人事部=4)
-- UPDATE dbo.Employees
-- SET    Salary = Salary * 1.03
-- OUTPUT inserted.EmployeeId, deleted.Salary AS 昇給前, inserted.Salary AS 昇給後
-- WHERE  DepartmentId = 4;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. WHERE 付け忘れの危険
--     元のクエリは WHERE が無いため「全社員」の給与に +50000 してしまう。
--     対象を限定する WHERE を付け、トランザクションで保護するのが正しい。
BEGIN TRAN;

UPDATE dbo.Employees
SET    Salary = Salary + 50000
WHERE  DepartmentId = 1;              -- 営業部だけを対象にする

SELECT @@ROWCOUNT AS 更新行数;        -- 想定件数(営業部=4名)か確認
SELECT EmployeeId, LastName, Salary FROM dbo.Employees WHERE DepartmentId = 1;

ROLLBACK;


-- Q10. MERGE による UPSERT(Categories のコピーで練習)
BEGIN TRAN;

SELECT * INTO #CatTarget FROM dbo.Categories;

;WITH ソース AS (
    SELECT * FROM (VALUES
        (3, N'ステーショナリー'),   -- 既存(3=文房具)→ 名称更新
        (6, N'雑貨')                 -- 新規 → 追加
    ) AS s (CategoryId, CategoryName)
)
MERGE #CatTarget AS T
USING ソース      AS S
    ON  T.CategoryId = S.CategoryId
WHEN MATCHED THEN
    UPDATE SET T.CategoryName = S.CategoryName
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CategoryId, CategoryName)
    VALUES (S.CategoryId, S.CategoryName)
OUTPUT $action, inserted.CategoryId, inserted.CategoryName AS 変更後, deleted.CategoryName AS 変更前;

SELECT * FROM #CatTarget ORDER BY CategoryId;

ROLLBACK;   -- #CatTarget も破棄


-- Q11. MERGE で在庫マスタを同期(3方向: MATCHED / NOT MATCHED BY TARGET / BY SOURCE)
BEGIN TRAN;

CREATE TABLE #Stock (ProductId INT PRIMARY KEY, Qty INT);
INSERT INTO #Stock (ProductId, Qty) VALUES (1, 10), (2, 5), (99, 0);

;WITH 新在庫 AS (
    SELECT * FROM (VALUES
        (1, 8),
        (2, 7),
        (3, 20)
    ) AS s (ProductId, Qty)
)
MERGE #Stock AS T
USING 新在庫 AS S
    ON  T.ProductId = S.ProductId
WHEN MATCHED THEN                          -- 両方にある(1,2)→ 数量更新
    UPDATE SET T.Qty = S.Qty
WHEN NOT MATCHED BY TARGET THEN            -- ソースのみ(3)→ 挿入
    INSERT (ProductId, Qty) VALUES (S.ProductId, S.Qty)
WHEN NOT MATCHED BY SOURCE THEN            -- ターゲットのみ(99)→ 削除
    DELETE
OUTPUT $action, inserted.ProductId, inserted.Qty, deleted.ProductId;

SELECT * FROM #Stock ORDER BY ProductId;   -- 1=8, 2=7, 3=20, 99は消える

ROLLBACK;


-- Q12. トランザクションの原子性(UPDATE と DELETE がまとめて取り消される)
-- 変更前の状態を確認
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products WHERE ProductId IN (1, 20);

BEGIN TRAN;
    UPDATE dbo.Products SET UnitPrice = UnitPrice * 0.5 WHERE ProductId = 1;   -- 値下げ
    DELETE FROM dbo.Products WHERE ProductId = 20;                            -- 削除

    -- トランザクション内の途中経過(1は半額、20は消えている)
    SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (1, 20);
ROLLBACK;

-- ROLLBACK 後: 2つの操作が「まとめて」取り消され、元に戻っている
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (1, 20);

-- 説明: BEGIN TRAN 〜 ROLLBACK は1つの原子的な単位。COMMIT していないので、
--       その間の UPDATE も DELETE も「全部なかったこと」になる(All or Nothing)。
