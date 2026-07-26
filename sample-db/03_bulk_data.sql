/* ============================================================
   性能検証用 大量データ: SalesLearning
   目的 : インデックス・実行プラン・統計情報の学習用(トピック15・18)
   前提 : 01 / 02 を実行済みであること
   注意 : 既存の小さいテーブル(Orders 等)には一切手を触れません。
          性能検証専用の dbo.OrdersBig を新規に作ります。
          → 01〜13 の演習結果は変わりません。
   時間 : 環境により 10〜60 秒程度かかります。
   ============================================================ */

USE SalesLearning;
GO

SET NOCOUNT ON;
GO

-- 生成する行数(小さいマシンなら 200000 程度に減らしてもよい)
DECLARE @Rows INT = 1000000;

DROP TABLE IF EXISTS dbo.OrdersBig;

CREATE TABLE dbo.OrdersBig
(
    OrderId    INT            NOT NULL,
    CustomerId INT            NOT NULL,   -- 1〜12 (dbo.Customers と結合可能)
    EmployeeId INT            NOT NULL,   -- 1〜13 (dbo.Employees と結合可能)
    OrderDate  DATE           NOT NULL,   -- 2015-01-01 〜 2024-12-31 に分散
    ShipDate   DATE           NULL,       -- 約5% が NULL(未出荷)
    Status     NVARCHAR(10)   NOT NULL,   -- '完了' 約95% / '保留' 約5%(偏りのある列)
    Amount     DECIMAL(12, 0) NOT NULL,
    CONSTRAINT PK_OrdersBig PRIMARY KEY CLUSTERED (OrderId)
);

/* ------------------------------------------------------------
   番号表(Tally)による集合ベースの一括生成
   ※ ループを使わず 1 文で生成するのがポイント(トピック21で解説)
   ------------------------------------------------------------ */
WITH E1(n) AS (
    SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)   -- 10
),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),                          -- 100
E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),                          -- 10,000
E8(n) AS (SELECT 1 FROM E4 AS a CROSS JOIN E4 AS b),                          -- 100,000,000
Tally AS (
    SELECT TOP (@Rows)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM   E8
)
INSERT INTO dbo.OrdersBig (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate, Status, Amount)
SELECT
    n                                            AS OrderId,
    (n % 12) + 1                                 AS CustomerId,
    (n % 13) + 1                                 AS EmployeeId,
    DATEADD(DAY, n % 3653, '2015-01-01')         AS OrderDate,
    CASE WHEN n % 20 = 0                                       -- 5% は未出荷
         THEN NULL
         ELSE DATEADD(DAY, (n % 7) + 1, DATEADD(DAY, n % 3653, '2015-01-01'))
    END                                          AS ShipDate,
    CASE WHEN n % 20 = 0 THEN N'保留' ELSE N'完了' END          AS Status,
    ((n % 500) + 1) * 1000                       AS Amount
FROM Tally;

PRINT N'dbo.OrdersBig を生成しました。';
GO

/* ------------------------------------------------------------
   確認
   ------------------------------------------------------------ */
SELECT COUNT(*) AS 行数,
       MIN(OrderDate) AS 最古,
       MAX(OrderDate) AS 最新
FROM   dbo.OrdersBig;
GO

/* ============================================================
   ここではあえて非クラスタ化インデックスを作りません。

   トピック18(インデックスと実行プラン)の演習で、
   「インデックスが無い状態のプラン」→「作った後のプラン」を
   自分で比較するためです。

   演習をやり直したくなったら、次の文で追加インデックスを消せます。

     DROP INDEX IF EXISTS IX_OrdersBig_OrderDate ON dbo.OrdersBig;
     DROP INDEX IF EXISTS IX_OrdersBig_Status    ON dbo.OrdersBig;

   丸ごと作り直す場合はこのスクリプトを再実行してください。
   ============================================================ */
