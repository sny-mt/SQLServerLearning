/* ============================================================
   解答例 21 — 実務頻出クエリパターン集
   対象演習: exercises/21_query_patterns.md

   注意 : データを変更する問題(Q5・Q11)は、すべて一時テーブル(#名前)の
          コピーに対して操作しています。dbo. のテーブルは一切変更しません。
          各問の最後で DROP TABLE IF EXISTS により後片付けします。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 顧客ごとの最新注文(注文の無い顧客も残す)
--     ポイント: OUTER APPLY にすると、TOP(1) が 0 行でも親の行が NULL 付きで残る。
--               ORDER BY に OrderId を足してタイブレークを効かせている。
SELECT c.CustomerId,
       c.CustomerName,
       o.OrderId,
       o.OrderDate
FROM   dbo.Customers AS c
OUTER  APPLY (
    SELECT TOP (1) o2.OrderId, o2.OrderDate
    FROM   dbo.Orders AS o2
    WHERE  o2.CustomerId = c.CustomerId
    ORDER  BY o2.OrderDate DESC, o2.OrderId DESC
) AS o
ORDER  BY c.CustomerId;

-- (別解) ROW_NUMBER + LEFT JOIN。注文の無い顧客を残すには LEFT JOIN が必須。
--        rn = 1 の条件は WHERE ではなく ON 側に書かないと LEFT JOIN が内部結合に化ける。
WITH 順位付き AS (
    SELECT o.CustomerId, o.OrderId, o.OrderDate,
           ROW_NUMBER() OVER (PARTITION BY o.CustomerId
                              ORDER BY o.OrderDate DESC, o.OrderId DESC) AS 新しい順
    FROM   dbo.Orders AS o
)
SELECT c.CustomerId, c.CustomerName, r.OrderId, r.OrderDate
FROM   dbo.Customers AS c
LEFT   JOIN 順位付き AS r
       ON  r.CustomerId = c.CustomerId
       AND r.新しい順   = 1
ORDER  BY c.CustomerId;


-- Q2. カテゴリごとの単価トップ2
WITH 順位付き AS (
    SELECT p.CategoryId,
           p.ProductId,
           p.ProductName,
           p.UnitPrice,
           ROW_NUMBER() OVER (PARTITION BY p.CategoryId
                              ORDER BY p.UnitPrice DESC, p.ProductId) AS 順位
    FROM   dbo.Products AS p
    WHERE  p.CategoryId IS NOT NULL
)
SELECT cat.CategoryName,
       r.ProductName,
       r.UnitPrice,
       r.順位
FROM   順位付き        AS r
JOIN   dbo.Categories AS cat ON cat.CategoryId = r.CategoryId
WHERE  r.順位 <= 2
ORDER  BY cat.CategoryId, r.順位;

-- (別解) CROSS APPLY 版。カテゴリ 5 行 × TOP(2) のシークで済む。
SELECT cat.CategoryName,
       p.ProductName,
       p.UnitPrice
FROM   dbo.Categories AS cat
CROSS  APPLY (
    SELECT TOP (2) p2.ProductName, p2.UnitPrice
    FROM   dbo.Products AS p2
    WHERE  p2.CategoryId = cat.CategoryId
    ORDER  BY p2.UnitPrice DESC, p2.ProductId
) AS p
ORDER  BY cat.CategoryId, p.UnitPrice DESC;


-- Q3. 注文ごとの商品名カンマ区切り (STRING_AGG / SQL Server 2017 以降)
--     ポイント: 並び順は ORDER BY ではなく WITHIN GROUP (ORDER BY ...) で指定する。
--               入力を NVARCHAR(MAX) にキャストしておくと長さ超過エラーを避けられる。
SELECT o.OrderId,
       o.OrderDate,
       STRING_AGG(CAST(p.ProductName AS NVARCHAR(MAX)), N', ')
           WITHIN GROUP (ORDER BY p.ProductName) AS 商品一覧,
       COUNT(*)                                  AS 明細件数
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId  = o.OrderId
JOIN   dbo.Products     AS p  ON p.ProductId = od.ProductId
GROUP  BY o.OrderId, o.OrderDate
ORDER  BY o.OrderId;


-- Q4. 顧客3(ガンマ物産)の 2023年 月次売上を、売上のない月も 0 で埋めて 12 行出す
--     顧客3 の注文は 1003(2月)・1008(4月)・1016(9月) の 3 件だけ。
--     → 番号表でカレンダーを作り、集計結果を LEFT JOIN + ISNULL でゼロ埋めする。
DECLARE @開始 DATE = '2023-01-01';   -- 月初日に揃える
DECLARE @終了 DATE = '2023-12-01';

WITH E1(n) AS (
    SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)   -- 10 行
),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),                          -- 100 行
カレンダー AS (
    SELECT TOP (DATEDIFF(MONTH, @開始, @終了) + 1)
           DATEADD(MONTH, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @開始) AS 月
    FROM   E2
),
月次売上 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    WHERE  o.CustomerId = 3
      AND  o.OrderDate >= '2023-01-01'
      AND  o.OrderDate <  '2024-01-01'
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT cal.月,
       ISNULL(s.売上, 0) AS 売上
FROM   カレンダー AS cal
LEFT   JOIN 月次売上 AS s ON s.月 = cal.月
ORDER  BY cal.月;
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 重複行の検出と削除(一時テーブル上で実施)

-- ① コピーを作る。SELECT INTO は PK / 制約を引き継がないので重複を入れられる。
DROP TABLE IF EXISTS #Customers;

SELECT CustomerId, CustomerName, City, Region, SalesRepId
INTO   #Customers
FROM   dbo.Customers;

-- ② わざと二重登録を作る
INSERT INTO #Customers (CustomerId, CustomerName, City, Region, SalesRepId) VALUES
    (101, N'株式会社アルファ商事', N'東京', N'関東',    2),
    (102, N'株式会社アルファ商事', N'東京', N'関東', NULL),
    (103, N'ガンマ物産',          N'大阪', N'関西',    3);

SELECT COUNT(*) AS 削除前件数 FROM #Customers;    -- 15 行

-- ③ 重複グループの検出
SELECT CustomerName, City, COUNT(*) AS 件数
FROM   #Customers
GROUP  BY CustomerName, City
HAVING COUNT(*) > 1
ORDER  BY 件数 DESC, CustomerName;

-- ③' 消える行を DELETE の前に必ず目視する(DELETE と同じ CTE を SELECT で確認)
WITH 重複 AS (
    SELECT CustomerId, CustomerName, City,
           ROW_NUMBER() OVER (PARTITION BY CustomerName, City
                              ORDER BY CustomerId) AS 連番
    FROM   #Customers
)
SELECT * FROM 重複 WHERE 連番 > 1 ORDER BY CustomerName, 連番;

-- ④ CustomerId が最小の 1 件を残して削除する
--    ポイント: SQL Server は CTE を DELETE の対象にできる。実際に消えるのは #Customers の行。
WITH 重複 AS (
    SELECT ROW_NUMBER() OVER (PARTITION BY CustomerName, City
                              ORDER BY CustomerId) AS 連番
    FROM   #Customers
)
DELETE FROM 重複
WHERE  連番 > 1;

-- ⑤ 確認と後片付け
SELECT COUNT(*) AS 削除後件数 FROM #Customers;    -- 12 行
SELECT * FROM #Customers ORDER BY CustomerId;

DROP TABLE IF EXISTS #Customers;
GO


-- Q6. 伝票番号の欠番検出
DROP TABLE IF EXISTS #伝票;

SELECT OrderId AS 伝票番号
INTO   #伝票
FROM   dbo.Orders
WHERE  OrderId NOT IN (1002, 1003, 1010, 1011, 1012);

-- LEAD で「次の番号」を取り、自分 + 1 より大きければそこが欠番。
-- 期待結果: 1002〜1003 (2件) と 1010〜1012 (3件)
WITH 並び AS (
    SELECT 伝票番号,
           LEAD(伝票番号) OVER (ORDER BY 伝票番号) AS 次番号
    FROM   #伝票
)
SELECT 伝票番号 + 1          AS 欠番開始,
       次番号   - 1          AS 欠番終了,
       次番号 - 伝票番号 - 1 AS 欠番件数
FROM   並び
WHERE  次番号 > 伝票番号 + 1
ORDER  BY 欠番開始;

DROP TABLE IF EXISTS #伝票;
GO


-- Q7. 顧客ごとの「注文があった月」の連続区間(連続 2 か月以上のみ)
--     ポイント: 同じ月に複数注文があると行番号がずれるので、まず DISTINCT で一意化する。
--               「通算月数 − 顧客内の行番号」が同じ行が 1 つの塊になる。
--     期待結果: 顧客1(アルファ商事)の 2023-01〜2023-02(2か月)のみ。
WITH 注文月 AS (
    SELECT DISTINCT
           o.CustomerId,
           DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月
    FROM   dbo.Orders AS o
),
グループ化 AS (
    SELECT CustomerId,
           月,
           DATEDIFF(MONTH, '2000-01-01', 月)
             - ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY 月) AS 塊キー
    FROM   注文月
)
SELECT g.CustomerId,
       c.CustomerName,
       MIN(g.月) AS 開始月,
       MAX(g.月) AS 終了月,
       COUNT(*)  AS 連続月数
FROM   グループ化    AS g
JOIN   dbo.Customers AS c ON c.CustomerId = g.CustomerId
GROUP  BY g.CustomerId, c.CustomerName, g.塊キー
HAVING COUNT(*) >= 2
ORDER  BY g.CustomerId, 開始月;


-- Q8. 月次売上 + 年累計 + 3か月移動平均 + 前年同月比
--     ポイント1: 累計・移動平均は ROWS を明示する(既定の RANGE は同値行をまとめてしまう)。
--     ポイント2: 年累計は PARTITION BY YEAR(月) でリセットされる。
--     ポイント3: 前年同月は LAG(...,12)(=12「行」前)ではなく DATEADD(YEAR,-1,月) の
--                自己結合にすると、月が欠測していてもずれない。
--     ※ データは 2023-01〜2024-01 の 13 か月なので、前年同月比が出るのは 2024-01 のみ。
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT t.月,
       t.月売上,
       SUM(t.月売上) OVER (PARTITION BY YEAR(t.月)
                           ORDER BY t.月
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS 年累計,
       CAST(AVG(t.月売上) OVER (ORDER BY t.月
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
            AS DECIMAL(18, 0))                                               AS 三か月移動平均,
       CAST(100.0 * t.月売上 / NULLIF(p.月売上, 0) AS DECIMAL(6, 1))          AS 前年同月比_pct
FROM   月次 AS t
LEFT   JOIN 月次 AS p ON p.月 = DATEADD(YEAR, -1, t.月)
ORDER  BY t.月;

-- (別解) 月の欠測が無いと保証できる場合は LAG(...,12) でも書ける。
--        ただし 1 か月でも抜けていると静かに 1 か月ずれるので注意。
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       LAG(月売上, 12) OVER (ORDER BY 月) AS 前年同月売上,
       CAST(100.0 * 月売上 / NULLIF(LAG(月売上, 12) OVER (ORDER BY 月), 0)
            AS DECIMAL(6, 1))             AS 前年同月比_pct
FROM   月次
ORDER  BY 月;


-- Q9. 2023年 地域別 × 四半期 の売上サマリ(条件付き集計)
--     ポイント: 条件付き件数は COUNT(DISTINCT CASE WHEN ... THEN OrderId END)。
--               ELSE を書かないので条件外は NULL となり、COUNT の対象から自動で外れる。
SELECT ISNULL(c.Region, N'(地域未設定)') AS 地域,
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 1
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q1],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 2
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q2],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 3
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q3],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 4
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q4],
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))                      AS 年間合計,
       COUNT(DISTINCT o.OrderId)                                                AS 注文件数
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
WHERE  o.OrderDate >= '2023-01-01'
  AND  o.OrderDate <  '2024-01-01'
GROUP  BY c.Region
ORDER  BY 年間合計 DESC;

-- (別解) 最下部に総合計行を付けたい場合は WITH ROLLUP + GROUPING()
SELECT CASE WHEN GROUPING(c.Region) = 1 THEN N'【総合計】'
            ELSE ISNULL(c.Region, N'(地域未設定)') END        AS 地域,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))    AS 年間合計,
       COUNT(DISTINCT o.OrderId)                              AS 注文件数
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
WHERE  o.OrderDate >= '2023-01-01'
  AND  o.OrderDate <  '2024-01-01'
GROUP  BY c.Region WITH ROLLUP
ORDER  BY GROUPING(c.Region), 年間合計 DESC;
GO


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q10-1. 商品名カンマ区切り(SQL Server 2016 以前でも動く FOR XML PATH 版)
--        ポイント1: PATH(N'') で要素名を空にすると、タグの付かない単なる連結になる。
--        ポイント2: 先頭に付く N', ' を STUFF(文字列, 1, 2, N'') で除去する(区切り文字は 2 文字)。
--        ポイント3: , TYPE と .value(N'.', N'NVARCHAR(MAX)') はセット。
--                   省くと & や < が XML エスケープされたまま出力される。
SELECT o.OrderId,
       o.OrderDate,
       STUFF(
           (SELECT N', ' + p.ProductName
            FROM   dbo.OrderDetails AS od
            JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
            WHERE  od.OrderId = o.OrderId
            ORDER  BY p.ProductName
            FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'),
           1, 2, N'')                     AS 商品一覧
FROM   dbo.Orders AS o
ORDER  BY o.OrderId;

-- Q10-2. カンマ区切り文字列を行に分解する (STRING_SPLIT / SQL Server 2016 以降)
--        ※ STRING_SPLIT は区切り文字 1 文字のみ。元の順序は保証されない
--          (順序を返す ordinal 列は SQL Server 2022 以降)。
DECLARE @商品リスト NVARCHAR(400) = N'ノートPC,本棚,SQL実践ガイド';

SELECT p.ProductId,
       p.ProductName,
       p.CategoryId,
       p.UnitPrice
FROM   STRING_SPLIT(@商品リスト, N',') AS s
JOIN   dbo.Products AS p ON p.ProductName = LTRIM(RTRIM(s.value))
ORDER  BY p.ProductId;
GO


-- Q11. カーソル処理を 1 文の UPDATE に書き換える(商品ごとの販売数量集計)

-- ① 作業用の一時テーブルを作る
DROP TABLE IF EXISTS #商品集計;

SELECT p.ProductId,
       p.ProductName,
       p.CategoryId,
       CAST(0   AS INT)          AS 販売数量合計,
       CAST(0   AS INT)          AS 販売回数,
       CAST(N'' AS NVARCHAR(10)) AS 販売区分
INTO   #商品集計
FROM   dbo.Products AS p;

-- ② 集合ベースの UPDATE(カーソル 20 回転 → 1 文)
--    ポイント1: 集計は派生表に閉じ込め、LEFT JOIN で「1 度も売れていない商品」も残す。
--    ポイント2: 一度も売れていない商品は s.数量 が NULL なので ISNULL(...,0) で 0 に落とす。
--    ポイント3: 区分判定は CASE 式を SET に直接書けばよく、行ごとの分岐は不要。
UPDATE t
SET    販売数量合計 = ISNULL(s.数量, 0),
       販売回数     = ISNULL(s.回数, 0),
       販売区分     = CASE WHEN ISNULL(s.数量, 0) >= 50 THEN N'主力'
                           WHEN ISNULL(s.数量, 0) >=  1 THEN N'一般'
                           ELSE N'未販売' END
FROM   #商品集計 AS t
LEFT   JOIN (
    SELECT od.ProductId,
           SUM(od.Quantity) AS 数量,
           COUNT(*)         AS 回数
    FROM   dbo.OrderDetails AS od
    GROUP  BY od.ProductId
) AS s ON s.ProductId = t.ProductId;

-- ③ 結果確認(廃番の USBハブ(5)・ホチキス(12)などが「未販売」になる)
SELECT ProductId, ProductName, 販売数量合計, 販売回数, 販売区分
FROM   #商品集計
ORDER  BY 販売数量合計 DESC, ProductId;

-- ④ 後片付け
DROP TABLE IF EXISTS #商品集計;
GO


-- Q12. 2023年で「注文が 1 件も無かった日」の連続期間(10 日以上)
--      ポイント1: 存在しない行(注文の無い日)は元データから取れないので、
--                 番号表で全日付カレンダーを作ってから NOT EXISTS で絞る。
--      ポイント2: 日付から日付は引けないので、DATEADD(DAY, -行番号, 日付) で塊キーを作る。
--                 連続した日付は同じ日付に潰れる。
DECLARE @開始日 DATE = '2023-01-01';
DECLARE @終了日 DATE = '2023-12-31';

WITH E1(n) AS (
    SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)   -- 10 行
),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),                          -- 100 行
E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),                          -- 10,000 行
カレンダー AS (
    SELECT TOP (DATEDIFF(DAY, @開始日, @終了日) + 1)
           DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @開始日) AS 日付
    FROM   E4
),
注文なし日 AS (
    SELECT cal.日付
    FROM   カレンダー AS cal
    WHERE  NOT EXISTS (SELECT 1
                       FROM   dbo.Orders AS o
                       WHERE  o.OrderDate = cal.日付)
),
グループ化 AS (
    SELECT 日付,
           DATEADD(DAY,
                   -ROW_NUMBER() OVER (ORDER BY 日付),
                   日付) AS 塊キー
    FROM   注文なし日
)
SELECT MIN(日付) AS 開始日,
       MAX(日付) AS 終了日,
       COUNT(*)  AS 日数
FROM   グループ化
GROUP  BY 塊キー
HAVING COUNT(*) >= 10
ORDER  BY 開始日;
GO
