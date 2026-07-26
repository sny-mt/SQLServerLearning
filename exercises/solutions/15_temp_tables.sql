/* ============================================================
   解答例 15 — 一時テーブルとテーブル変数
   対象演習: exercises/15_temp_tables.md

   注意 : Q8 / Q9 / Q11 は dbo.OrdersBig(100万行)を使います。
          先に sample-db/03_bulk_data.sql を実行しておくこと。
   方針 : 本物のテーブルは一切変更しません。作った一時オブジェクトは
          すべて DROP TABLE IF EXISTS で後片付けします。
   ============================================================ */
USE SalesLearning;
GO

SET NOCOUNT ON;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. SELECT INTO で #EmpList を作る(部署未設定の社員も残す)
DROP TABLE IF EXISTS #EmpList;      -- 前回の残骸を必ず消してから作る

SELECT e.EmployeeId,
       e.LastName + N' ' + e.FirstName AS 氏名,
       d.DepartmentName,
       e.Salary
INTO   #EmpList
FROM   dbo.Employees        AS e
LEFT   JOIN dbo.Departments AS d ON d.DepartmentId = e.DepartmentId;
--     ↑ INNER JOIN にすると DepartmentId が NULL の佐々木彩(13)が落ちる

SELECT * FROM #EmpList ORDER BY EmployeeId;   -- 13 行
SELECT COUNT(*) AS 行数 FROM #EmpList;

-- 後片付け
DROP TABLE IF EXISTS #EmpList;
GO


-- Q2. CREATE TABLE + INSERT ... SELECT で型を自分で決める
DROP TABLE IF EXISTS #ProductSales;

CREATE TABLE #ProductSales
(
    ProductId   INT            NOT NULL PRIMARY KEY,   -- 制約を定義できるのが CREATE TABLE 版の利点
    ProductName NVARCHAR(100)  NOT NULL,
    合計数量     INT            NOT NULL,
    売上合計     DECIMAL(18, 2) NOT NULL
);

INSERT INTO #ProductSales (ProductId, ProductName, 合計数量, 売上合計)
SELECT p.ProductId,
       p.ProductName,
       SUM(od.Quantity),
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
FROM   dbo.OrderDetails AS od
JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
GROUP  BY p.ProductId, p.ProductName;

SELECT TOP (5)
       ProductName AS 商品名,
       合計数量,
       売上合計
FROM   #ProductSales
ORDER  BY 売上合計 DESC;

-- 後片付け
DROP TABLE IF EXISTS #ProductSales;
GO


-- Q3. テーブル変数 @Cat(宣言〜利用まで GO を挟まない同一バッチで書く)
DECLARE @Cat TABLE
(
    CategoryId   INT          NOT NULL PRIMARY KEY,
    CategoryName NVARCHAR(50) NOT NULL
);

INSERT INTO @Cat (CategoryId, CategoryName)
SELECT CategoryId, CategoryName
FROM   dbo.Categories;

SELECT c.CategoryName        AS カテゴリ,
       COUNT(p.ProductId)    AS 商品数,      -- COUNT(*) だと 0 件が 1 になるので列を数える
       AVG(p.UnitPrice)      AS 平均単価
FROM   @Cat            AS c
LEFT   JOIN dbo.Products AS p ON p.CategoryId = c.CategoryId
GROUP  BY c.CategoryName
ORDER  BY 商品数 DESC;
--  ※ テーブル変数は DROP 不要。バッチ(GO)が終われば自動的に解放される。
GO


-- Q4. ROLLBACK の影響: 一時テーブルは消える / テーブル変数は残る
DROP TABLE IF EXISTS #Memo;
CREATE TABLE #Memo (内容 NVARCHAR(50) NOT NULL);

DECLARE @Memo TABLE (内容 NVARCHAR(50) NOT NULL);

BEGIN TRAN;
    INSERT INTO #Memo (内容) VALUES (N'一時テーブルへの記録');
    INSERT INTO @Memo (内容) VALUES (N'テーブル変数への記録');
ROLLBACK;

SELECT N'#Memo(一時テーブル)' AS 置き場所, 内容 FROM #Memo    -- 0 行
UNION ALL
SELECT N'@Memo(テーブル変数)',            内容 FROM @Memo;   -- 1 行

/* 説明:
   一時テーブルは tempdb 上の「テーブル」であり、通常のテーブルと同じく
   トランザクションのログ対象なので ROLLBACK で INSERT が取り消される。
   一方テーブル変数は「変数」として扱われ、トランザクションのロールバックの
   影響を受けない。そのため、エラーで処理を巻き戻しても残したいログや
   処理結果の記録にはテーブル変数が適している。 */

DROP TABLE IF EXISTS #Memo;
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. (1) 一時テーブルなら索引を「後から」作れる
DROP TABLE IF EXISTS #Recent;

SELECT OrderId, CustomerId, EmployeeId, OrderDate, ShipDate
INTO   #Recent
FROM   dbo.Orders
WHERE  OrderDate >= '2023-07-01';

CREATE NONCLUSTERED INDEX IX_Recent_CustomerId ON #Recent (CustomerId);

SELECT * FROM #Recent ORDER BY OrderDate;

-- 作られた索引の確認
SELECT name AS 索引名, type_desc AS 種別
FROM   tempdb.sys.indexes
WHERE  object_id = OBJECT_ID('tempdb..#Recent');

DROP TABLE IF EXISTS #Recent;
GO

-- Q5. (2) テーブル変数に CREATE INDEX はできない
/*  次を書くと構文エラーになる(テーブル変数は変数なので CREATE INDEX の対象にできない):

        DECLARE @Recent TABLE (OrderId INT, CustomerId INT);
        CREATE NONCLUSTERED INDEX IX_Recent_CustomerId ON @Recent (CustomerId);
        --> メッセージ 102: '@Recent' 付近に不適切な構文があります。

    → 索引は「宣言時」に、制約(PRIMARY KEY / UNIQUE)か
      インライン索引構文(SQL Server 2014 以降)で作るしかない。          */

DECLARE @Recent TABLE
(
    OrderId    INT  NOT NULL PRIMARY KEY,                     -- 制約経由の索引
    CustomerId INT  NOT NULL,
    EmployeeId INT  NULL,
    OrderDate  DATE NOT NULL,
    ShipDate   DATE NULL,
    INDEX IX_Recent_CustomerId NONCLUSTERED (CustomerId)      -- インライン索引(2014+)
);

INSERT INTO @Recent (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
SELECT OrderId, CustomerId, EmployeeId, OrderDate, ShipDate
FROM   dbo.Orders
WHERE  OrderDate >= '2023-07-01';

SELECT * FROM @Recent ORDER BY OrderDate;
GO


-- Q6. (1) CTE を 2 回参照する版
WITH CustSales AS (
    SELECT c.CustomerId,
           c.CustomerName,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上合計
    FROM   dbo.Customers    AS c
    JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
    GROUP  BY c.CustomerId, c.CustomerName
)
SELECT s.CustomerName AS 顧客名,
       s.売上合計
FROM   CustSales AS s                                     -- ← 1 回目の参照
WHERE  s.売上合計 > (SELECT AVG(売上合計) FROM CustSales)   -- ← 2 回目の参照
ORDER  BY s.売上合計 DESC;

-- Q6. (2) 一時テーブルに 1 回だけ落としてから 2 回参照する版
DROP TABLE IF EXISTS #CustSales;

SELECT c.CustomerId,
       c.CustomerName,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上合計
INTO   #CustSales
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
GROUP  BY c.CustomerId, c.CustomerName;

SELECT s.CustomerName AS 顧客名,
       s.売上合計
FROM   #CustSales AS s
WHERE  s.売上合計 > (SELECT AVG(売上合計) FROM #CustSales)
ORDER  BY s.売上合計 DESC;

DROP TABLE IF EXISTS #CustSales;

/* Q6. (3) 実行プランの観察:
   (1) の CTE 版では Orders / OrderDetails を読んで集計する部分が
       プラン上に「2 か所」現れる。CTE は名前を付けた定義にすぎず、
       実体化されないため、参照した回数だけ評価されうる。
   (2) の一時テーブル版では集計は 1 回だけで、以降は #CustSales を
       読むだけになる。
   このサンプルは 20 行程度なので体感差は無いが、集計元が数百万行に
   なると「重い中間結果を複数回参照するなら一時テーブル」の効果が出る。 */
GO


-- Q7. SELECT INTO の落とし穴(型は引き継ぐ、制約は引き継がない)
DROP TABLE IF EXISTS #EmpCopy;

SELECT * INTO #EmpCopy FROM dbo.Employees;

-- 列名・データ型・NULL 許容を確認する
SELECT c.column_id      AS 列番号,
       c.name           AS 列名,
       t.name           AS データ型,
       c.max_length     AS 最大バイト長,
       c.precision      AS 精度,
       c.scale          AS 位取り,
       c.is_nullable    AS NULL許容,
       c.is_identity    AS IDENTITY
FROM   tempdb.sys.columns AS c
JOIN   tempdb.sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE  c.object_id = OBJECT_ID('tempdb..#EmpCopy')
ORDER  BY c.column_id;

-- 主キーが引き継がれていないことの確認(ヒープ = index_id 0 の行しか無い)
SELECT index_id, name AS 索引名, type_desc AS 種別
FROM   tempdb.sys.indexes
WHERE  object_id = OBJECT_ID('tempdb..#EmpCopy');
--> HEAP の 1 行だけ。PK_Employees は引き継がれていない。

-- 主キーを後から追加する(NOT NULL であることを念のため保証してから)
ALTER TABLE #EmpCopy ALTER COLUMN EmployeeId INT NOT NULL;
ALTER TABLE #EmpCopy ADD CONSTRAINT PK_EmpCopy PRIMARY KEY (EmployeeId);

SELECT index_id, name AS 索引名, type_desc AS 種別
FROM   tempdb.sys.indexes
WHERE  object_id = OBJECT_ID('tempdb..#EmpCopy');
--> CLUSTERED の PK_EmpCopy が増えている。

/* ポイント:
   - 型・長さ・NULL 許容は「ソースの式」から推論される。
   - PK / UNIQUE / 既定値 / 外部キー / 索引は一切引き継がれない。
   - IDENTITY 属性だけは引き継がれてしまう。外したいときは
     SELECT ISNULL(EmployeeId, 0) AS EmployeeId ... のように式で包む。 */

DROP TABLE IF EXISTS #EmpCopy;
GO


-- Q8. 一時テーブルに落とす効果を論理読み取りで測る(dbo.OrdersBig)
SET STATISTICS IO ON;
GO

-- (1) OrdersBig を「2 回」直接スキャンする
SELECT CustomerId, COUNT(*) AS 件数, SUM(Amount) AS 売上合計
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01'
GROUP  BY CustomerId
ORDER  BY 売上合計 DESC;

SELECT EmployeeId, COUNT(*) AS 件数, SUM(Amount) AS 売上合計
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01'
GROUP  BY EmployeeId
ORDER  BY 売上合計 DESC;
GO

-- (2) 一時テーブルに「1 回だけ」落としてから 2 回集計する
DROP TABLE IF EXISTS #Orders2024;
GO

SELECT OrderId, CustomerId, EmployeeId, Amount
INTO   #Orders2024
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';        -- 約 10 万行

SELECT CustomerId, COUNT(*) AS 件数, SUM(Amount) AS 売上合計
FROM   #Orders2024
GROUP  BY CustomerId
ORDER  BY 売上合計 DESC;

SELECT EmployeeId, COUNT(*) AS 件数, SUM(Amount) AS 売上合計
FROM   #Orders2024
GROUP  BY EmployeeId
ORDER  BY 売上合計 DESC;
GO

/* 観察(メッセージタブの「論理読み取り数」を比較する):
   - (1) は OrdersBig(100万行・非クラスタ化索引なし)を 2 回フルスキャンするため、
     100万行分のクラスタ化索引スキャンが 2 回ぶん計上される。
   - (2) は OrdersBig のスキャンが 1 回だけ。以降は約 10 万行の
     #Orders2024 を読むだけなので、2 本目以降の論理読み取りが桁違いに小さい。
   - つまり「同じ絞り込み結果を何度も使う」なら一時テーブルに落とすのが有効。
     逆に 1 回しか使わないなら、落とす書き込みコストのぶん損になる。 */

DROP TABLE IF EXISTS #Orders2024;
GO
SET STATISTICS IO OFF;
GO


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 統計情報の有無が推定行数をどう変えるか(実際の実行プランを含めて実行する: Ctrl + M)

-- まず自分の環境の互換性レベルを確認する(150 以上なら 2019+ の遅延コンパイルが効く)
SELECT name         AS データベース,
       compatibility_level AS 互換性レベル
FROM   sys.databases
WHERE  name = N'SalesLearning';
GO

-- (A) テーブル変数版
DECLARE @T TABLE
(
    OrderId    INT NOT NULL PRIMARY KEY,
    CustomerId INT NOT NULL,
    Amount     DECIMAL(12, 0) NOT NULL
);

INSERT INTO @T (OrderId, CustomerId, Amount)
SELECT OrderId, CustomerId, Amount
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';        -- 約 10 万行

SELECT @@ROWCOUNT AS 投入行数;

-- ① そのまま(統計情報が無い)
SELECT c.CustomerName, COUNT(*) AS 件数, SUM(t.Amount) AS 売上合計
FROM   @T AS t
JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
GROUP  BY c.CustomerName;

-- ② 実際の行数でコンパイルさせる
SELECT c.CustomerName, COUNT(*) AS 件数, SUM(t.Amount) AS 売上合計
FROM   @T AS t
JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
GROUP  BY c.CustomerName
OPTION (RECOMPILE);
GO

-- (B) 一時テーブル版
DROP TABLE IF EXISTS #T;
GO

SELECT OrderId, CustomerId, Amount
INTO   #T
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';

CREATE CLUSTERED INDEX IX_T_CustomerId ON #T (CustomerId);

SELECT c.CustomerName, COUNT(*) AS 件数, SUM(t.Amount) AS 売上合計
FROM   #T AS t
JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
GROUP  BY c.CustomerName;

-- 一時テーブルは統計情報を持つ(存在の確認)
SELECT s.name AS 統計名, sp.rows AS 行数, sp.last_updated AS 最終更新
FROM   tempdb.sys.stats AS s
CROSS  APPLY tempdb.sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('tempdb..#T');

DROP TABLE IF EXISTS #T;
GO

/* 観察:
   - 互換性レベル 140 以下(または SQL Server 2017 以前)では、
     (A)① のテーブル変数スキャンは「推定行数 1」対「実際の行数 約100,000」と
     大きく乖離する。この見積もりのもとで Nested Loops が選ばれると、
     10 万回のループになり極端に遅くなる = 実行プランの破綻。
   - (A)② の OPTION (RECOMPILE) を付けると、実際の行数でコンパイルされるため
     推定行数が実際に近づき、Hash Match など適切な結合が選ばれる。
   - 互換性レベル 150 以上(SQL Server 2019+)では、テーブル変数の
     遅延コンパイルにより (A)① でも推定行数がほぼ実際の値になる。
     ただし「行数」が直るだけで、列の値の分布(ヒストグラム)は分からない。
   - (B) の一時テーブルは統計情報を持つため、最初から推定が正しい。
     さらに索引を後から張れるので、繰り返し結合する場合はより有利。
   結論: 「テーブル変数だから遅い」のではなく「見積もりが外れるから遅い」。
         行数が読めない/多い中間結果は一時テーブルに落とすのが安全。 */


-- Q10. グローバル一時テーブルのスコープ
-- 【セッション A(このウィンドウ)で実行】
DROP TABLE IF EXISTS ##SharedList;
DROP TABLE IF EXISTS #EmpList;

SELECT DepartmentId, DepartmentName, Location
INTO   ##SharedList
FROM   dbo.Departments;

SELECT EmployeeId, LastName, FirstName
INTO   #EmpList
FROM   dbo.Employees;

SELECT * FROM ##SharedList;   -- セッション A では当然見える
GO

/* 【セッション B(別のクエリウィンドウを開いて実行)】

       USE SalesLearning;

       -- ○ 成功する: グローバル一時テーブルは全セッションから見える
       SELECT * FROM ##SharedList;

       -- ✗ 失敗する: ローカル一時テーブルは作成セッション専用
       SELECT * FROM #EmpList;
       --> メッセージ 208: オブジェクト名 '#EmpList' が無効です。
*/

-- 【セッション A に戻って後片付け】
DROP TABLE IF EXISTS ##SharedList;
DROP TABLE IF EXISTS #EmpList;
GO

/* 実務でグローバル一時テーブルをあまり使わない理由:
   - 名前がセッション間で共有されるため、同じ処理が同時に走ると
     同名衝突やデータの混在が起きる(ローカル #t のような自動的な名前分離が無い)。
   - 「作成セッションが終了し、かつ誰も参照していない」ときに消えるという
     寿命の分かりにくさがあり、消し忘れが tempdb に残り続けやすい。
   → セッションをまたいで共有したいなら、恒久テーブル + 明示的な削除のほうが安全。 */


-- Q11. 段階的に一時テーブルへ落とす実務パターン(dbo.OrdersBig)
DROP TABLE IF EXISTS #対象;
DROP TABLE IF EXISTS #集計;
GO

-- 【段①】まず母集合を小さくする(2024 年 かつ 完了)
SELECT OrderId, CustomerId, EmployeeId, Amount
INTO   #対象
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01'
  AND  OrderDate <  '2025-01-01'
  AND  Status = N'完了';

CREATE CLUSTERED INDEX IX_対象 ON #対象 (CustomerId, EmployeeId);

-- 【段②】顧客 × 担当社員で集計する
SELECT CustomerId,
       EmployeeId,
       COUNT(*)    AS 件数,
       SUM(Amount) AS 売上合計
INTO   #集計
FROM   #対象
GROUP  BY CustomerId, EmployeeId;

CREATE CLUSTERED INDEX IX_集計 ON #集計 (CustomerId, EmployeeId);

-- 【段③】マスタを結合して見せ方を整え、上位 10 件
SELECT TOP (10)
       c.CustomerName                   AS 顧客名,
       e.LastName + N' ' + e.FirstName  AS 担当者,
       s.件数,
       s.売上合計
FROM   #集計         AS s
JOIN   dbo.Customers AS c ON c.CustomerId = s.CustomerId
JOIN   dbo.Employees AS e ON e.EmployeeId = s.EmployeeId
ORDER  BY s.売上合計 DESC;

-- 【後片付け】
DROP TABLE IF EXISTS #対象;
DROP TABLE IF EXISTS #集計;
GO

/* CTE 1 本で書くのと比べた利点(2 つ以上):
   ① デバッグしやすい。段①・段②をそれぞれ単独で SELECT して
      中身と件数を確認できる。CTE 1 本だと途中結果を覗けない。
   ② 実行プランが安定する。段ごとに統計情報が作られるので、
      見積もり誤差が次の段に伝播・増幅しにくい。
   ③ 早い段階で母集合を小さくし、そこに索引を張れる。
      段②・段③は 100万行ではなく絞り込み後の行数だけを扱う。
   ④ そのままストアドプロシージャの中身にできる(→ 16章)。
   ※ ただし軽い処理まで段に分けると tempdb への書き込みコストで
     かえって遅くなるので、「重い」「複数回参照する」「索引が欲しい」
     段だけを落とすこと。 */
