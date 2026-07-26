/* ============================================================
   分析系・大規模検証用データ: SalesLearning
   目的 : 列ストアインデックス / パーティショニング / バッチモードの
          学習用(トピック30・31)
   前提 : 01 / 02 を実行済みであること
   注意 : 既存テーブルには一切手を触れません。dbo.SalesFact を新規作成します。
   時間 : 1000万行で 1〜3分程度(環境による)。
          遅い場合は下の @Total を 2000000 などに減らしてください。
   ============================================================ */

USE SalesLearning;
GO

SET NOCOUNT ON;
GO

DROP TABLE IF EXISTS dbo.SalesFact;
GO

CREATE TABLE dbo.SalesFact
(
    SaleId     BIGINT         NOT NULL,
    SaleDate   DATE           NOT NULL,   -- 2015-01-01 〜 2024-12-31(ほぼ日付順に格納される)
    CustomerId INT            NOT NULL,   -- 1〜1000 (合成ディメンション。dbo.Customers とは無関係)
    ProductId  INT            NOT NULL,   -- 1〜20   (dbo.Products と結合可能)
    EmployeeId INT            NOT NULL,   -- 1〜13   (dbo.Employees と結合可能)
    RegionId   INT            NOT NULL,   -- 1〜8
    Quantity   INT            NOT NULL,
    UnitPrice  DECIMAL(10, 0) NOT NULL,
    Discount   DECIMAL(4, 2)  NOT NULL,
    Amount     DECIMAL(14, 2) NOT NULL,
    CONSTRAINT PK_SalesFact PRIMARY KEY CLUSTERED (SaleId)
);
GO

/* ------------------------------------------------------------
   バッチ分割して投入する

   ※ なぜ 1 文でまとめて INSERT しないのか:
      1000万行を1トランザクションで入れるとトランザクションログが巨大化する。
      実務でも大量投入はバッチに割るのが定石(この分割自体が学習ポイント)。
   ------------------------------------------------------------ */
DECLARE @Total    INT = 10000000,   -- ← 生成行数。重ければ 2000000 に減らす
        @Batch    INT = 1000000,
        @Done     INT = 0,
        @PerDay   INT;

-- 2015-01-01 から 2024-12-31 まで 3653 日。1日あたり何行にするか。
SET @PerDay = @Total / 3653;
IF @PerDay < 1 SET @PerDay = 1;

WHILE @Done < @Total
BEGIN
    IF @Done + @Batch > @Total SET @Batch = @Total - @Done;

    ;WITH E1(n) AS (
        SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)
    ),
    E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
    E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
    E8(n) AS (SELECT 1 FROM E4 AS a CROSS JOIN E4 AS b),
    T AS (
        SELECT TOP (@Batch)
               @Done + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM   E8
    )
    INSERT INTO dbo.SalesFact
        (SaleId, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
         Quantity, UnitPrice, Discount, Amount)
    SELECT
        n,
        /* ★重要: 日付を n に比例させ、ほぼ日付順に格納する。
           列ストアのセグメント除外は「セグメント内の値の範囲が狭いこと」で効く。
           日付をランダムに散らすと全セグメントが全期間を含み、除外が一切効かない。 */
        DATEADD(DAY, (n - 1) / @PerDay, '2015-01-01'),
        (n % 1000) + 1,
        (n % 20) + 1,
        (n % 13) + 1,
        (n % 8) + 1,
        (n % 10) + 1,
        ((n % 50) + 1) * 100,
        CAST((n % 5) * 5 AS DECIMAL(4,2)) / 100,
        CAST( ((n % 10) + 1) * (((n % 50) + 1) * 100)
              * (1 - CAST((n % 5) * 5 AS DECIMAL(4,2)) / 100) AS DECIMAL(14,2))
    FROM T;

    SET @Done += @Batch;
    RAISERROR (N'  投入済み: %d 行', 0, 1, @Done) WITH NOWAIT;
END;
GO

/* ------------------------------------------------------------
   確認
   ------------------------------------------------------------ */
SELECT COUNT_BIG(*) AS 行数,
       MIN(SaleDate) AS 最古,
       MAX(SaleDate) AS 最新,
       SUM(Amount)   AS 売上合計
FROM   dbo.SalesFact;
GO

/* ============================================================
   ここでは列ストアインデックスもパーティションも作りません。

   トピック30(列ストア)・31(パーティショニング)の演習で、
   学習者が自分で作り、行ストアとの差を計測するためです。

   演習で作るオブジェクトの想定名:
     - dbo.SalesFactCS                     … 列ストア版のコピー
     - CCI_SalesFactCS                     … クラスター化列ストアインデックス
     - pf_SalesByYear / ps_SalesByYear     … パーティション関数 / スキーム
     - dbo.SalesFactPartitioned            … パーティション表

   丸ごと作り直す場合はこのスクリプトを再実行してください。
   ============================================================ */
