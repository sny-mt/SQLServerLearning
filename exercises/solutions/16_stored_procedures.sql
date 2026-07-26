/* ============================================================
   解答例 16 — ストアドプロシージャとユーザー定義関数
   対象演習: exercises/16_stored_procedures.md

   ⚠️ このスクリプトはオブジェクトを作成します。
      各問の最後、および Q13 で DROP まで行い、
      サンプルDBに何も残らないようにしてあります。
      データを変更する Q7 は BEGIN TRAN ... ROLLBACK で囲んでいます。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. パラメータなしの商品一覧プロシージャ
--     ポイント: CREATE PROCEDURE はバッチの先頭でなければならないので前後を GO で区切る。
--               1行目の SET NOCOUNT ON; は「件数メッセージ」を抑制する定型。
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_GetProducts
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProductId,
           p.ProductName,
           p.UnitPrice,
           p.Discontinued
    FROM   dbo.Products AS p
    ORDER  BY p.UnitPrice DESC;
END;
GO

EXEC dbo.usp_Ex16_GetProducts;
GO


-- Q2. CREATE OR ALTER で作り直し、既定値付きパラメータを追加する
--     ポイント: @IncludeDiscontinued = 0 が既定値。呼び出し時に省略できる。
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_GetProducts
    @IncludeDiscontinued BIT = 0          -- 0 = 廃番を除外(既定), 1 = 含める
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProductId,
           p.ProductName,
           p.UnitPrice,
           p.Discontinued
    FROM   dbo.Products AS p
    WHERE  @IncludeDiscontinued = 1
       OR  p.Discontinued = 0
    ORDER  BY p.UnitPrice DESC;
END;
GO

-- ① 引数なし(既定値 0 が使われ、廃番の 5:USBハブ / 12:ホチキス は出ない)
EXEC dbo.usp_Ex16_GetProducts;

-- ② 名前付き呼び出し(実務ではこちらを使う。パラメータが増減しても壊れにくい)
EXEC dbo.usp_Ex16_GetProducts @IncludeDiscontinued = 1;

-- ③ 位置指定呼び出し(短いが、定義変更で静かに壊れるので非推奨)
EXEC dbo.usp_Ex16_GetProducts 1;
GO


-- Q3. 顧客の注文一覧を返すプロシージャ(必須パラメータ)
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_GetCustomerOrders
    @CustomerId INT                        -- 既定値なし = 必須
AS
BEGIN
    SET NOCOUNT ON;

    SELECT o.OrderId,
           o.OrderDate,
           o.ShipDate
    FROM   dbo.Orders AS o
    WHERE  o.CustomerId = @CustomerId
    ORDER  BY o.OrderDate, o.OrderId;
END;
GO

EXEC dbo.usp_Ex16_GetCustomerOrders @CustomerId = 1;    -- 注文 1001,1004,1011,1020
EXEC dbo.usp_Ex16_GetCustomerOrders @CustomerId = 11;   -- 注文なし → 0 行(エラーではない)
GO


-- Q4. 基礎パートの後片付け
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_GetProducts;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_GetCustomerOrders;
GO

-- 消えたことの確認(0 行になるはず)
SELECT o.name AS オブジェクト名, o.type_desc AS 種別
FROM   sys.objects AS o
WHERE  o.type = 'P'
  AND  o.name LIKE 'usp[_]Ex16[_]%';
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. OUTPUT パラメータで注文件数と売上合計を返す
--     ポイント: 注文はあるが明細が無い場合もあるので LEFT JOIN + ISNULL。
--               注文件数は明細で行が増えるため COUNT(DISTINCT o.OrderId)。
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_CustomerStats
    @CustomerId  INT,
    @OrderCount  INT           OUTPUT,
    @TotalAmount DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @OrderCount  = COUNT(DISTINCT o.OrderId),
           @TotalAmount = ISNULL(SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)), 0)
    FROM   dbo.Orders            AS o
    LEFT   JOIN dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    WHERE  o.CustomerId = @CustomerId;
END;
GO

-- 呼び出し側: EXEC にも OUTPUT を書くこと(書き忘れると変数は NULL のまま)
DECLARE @cnt1 INT, @amt1 DECIMAL(18,2),
        @cnt2 INT, @amt2 DECIMAL(18,2);

EXEC dbo.usp_Ex16_CustomerStats
        @CustomerId  = 1,
        @OrderCount  = @cnt1 OUTPUT,
        @TotalAmount = @amt1 OUTPUT;

EXEC dbo.usp_Ex16_CustomerStats
        @CustomerId  = 11,          -- 注文が無い顧客
        @OrderCount  = @cnt2 OUTPUT,
        @TotalAmount = @amt2 OUTPUT;

SELECT N'顧客1'  AS 顧客, @cnt1 AS 注文件数, @amt1 AS 売上合計
UNION ALL
SELECT N'顧客11',        @cnt2,             @amt2;
GO


-- Q6. RETURN で状態コードを返す
--     0 = 販売中 / 1 = 廃番 / 2 = 存在しない
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_CheckProduct
    @ProductId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Products WHERE ProductId = @ProductId)
        RETURN 2;                       -- ガード節: 即座に抜ける

    IF EXISTS (SELECT 1 FROM dbo.Products
               WHERE ProductId = @ProductId AND Discontinued = 1)
        RETURN 1;

    -- 販売中のときだけ商品情報を結果セットで返す
    SELECT ProductId, ProductName, CategoryId, UnitPrice
    FROM   dbo.Products
    WHERE  ProductId = @ProductId;

    RETURN 0;
END;
GO

DECLARE @rc1 INT, @rc2 INT, @rc3 INT;

EXEC @rc1 = dbo.usp_Ex16_CheckProduct @ProductId = 1;     -- ノートPC(販売中) → 0
EXEC @rc2 = dbo.usp_Ex16_CheckProduct @ProductId = 5;     -- USBハブ(廃番)   → 1
EXEC @rc3 = dbo.usp_Ex16_CheckProduct @ProductId = 999;   -- 存在しない        → 2

SELECT @rc1 AS 商品1の戻り値, @rc2 AS 商品5の戻り値, @rc3 AS 商品999の戻り値;
GO

/* Q6 の説明:
   RETURN で「売上金額」などのデータを返してはいけない理由。
     ・返せる型は int だけ。DECIMAL の金額も NVARCHAR の名称も返せない。
     ・NULL を返せない(RETURN NULL は 0 に変換される)ため「値が無い」を表現できない。
     ・値は1個しか返せない。
   → RETURN は「成功/失敗などの状態コード」専用。
      データを返すなら 結果セット(SELECT)か OUTPUT パラメータを使う。            */


-- Q7. TRY...CATCH + トランザクション + THROW
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_ApplyDiscount
    @OrderId  INT,
    @Discount DECIMAL(5,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                 -- エラー時にトランザクションを確実に異常終了扱いにする

    BEGIN TRY
        -- 入力チェック(THROW の直前の文は必ず ; で終えること)
        IF NOT EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderId = @OrderId)
            THROW 50010, N'指定された注文が存在しません。', 1;

        IF @Discount < 0.00 OR @Discount > 1.00
            THROW 50011, N'割引率は 0.00 〜 1.00 の範囲で指定してください。', 1;

        BEGIN TRAN;
            UPDATE dbo.OrderDetails
            SET    Discount = @Discount
            WHERE  OrderId  = @OrderId;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;   -- 開いていたら必ず戻す
        THROW;                          -- 元のエラー番号・メッセージのまま再送出
    END CATCH;
END;
GO

-- 正常系: 外側を BEGIN TRAN ... ROLLBACK で囲んでサンプルDBを守る
BEGIN TRAN;

    SELECT OrderId, ProductId, Quantity, UnitPrice, Discount AS 更新前割引率
    FROM   dbo.OrderDetails
    WHERE  OrderId = 1001;

    EXEC dbo.usp_Ex16_ApplyDiscount @OrderId = 1001, @Discount = 0.15;

    SELECT OrderId, ProductId, Quantity, UnitPrice, Discount AS 更新後割引率
    FROM   dbo.OrderDetails
    WHERE  OrderId = 1001;

ROLLBACK;   -- 変更をすべて取り消す
GO

-- 異常系①: 存在しない注文 → 50010
BEGIN TRY
    EXEC dbo.usp_Ex16_ApplyDiscount @OrderId = 9999, @Discount = 0.10;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS エラーメッセージ;
END CATCH;
GO

-- 異常系②: 割引率が範囲外 → 50011
BEGIN TRY
    EXEC dbo.usp_Ex16_ApplyDiscount @OrderId = 1001, @Discount = 1.50;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS エラーメッセージ;
END CATCH;
GO

/* Q7 のポイント:
   ・引数なしの THROW; は CATCH 専用で、捕まえたエラーをそのまま再送出する。
     エラー番号・メッセージ・重大度が保たれるので、再送出はこれ一択。
   ・IF @@TRANCOUNT > 0 ROLLBACK; を CATCH の定型にしないと、
     トランザクションが開きっぱなしになりロックを持ち続ける。                      */


-- Q8. スカラー関数と、同じ計算の iTVF
CREATE OR ALTER FUNCTION dbo.fn_Ex16_LineAmount
(
    @Quantity  INT,
    @UnitPrice DECIMAL(18,2),
    @Discount  DECIMAL(5,2)
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    RETURN @Quantity * @UnitPrice * (1 - @Discount);
END;
GO

SELECT TOP (10)
       od.OrderId,
       od.ProductId,
       dbo.fn_Ex16_LineAmount(od.Quantity, od.UnitPrice, od.Discount) AS 明細金額
FROM   dbo.OrderDetails AS od
ORDER  BY od.OrderId, od.ProductId;
GO

-- 同じ計算を「1列だけ返す iTVF」にする(スカラーUDF置き換えの定石)
CREATE OR ALTER FUNCTION dbo.fn_Ex16_LineAmountTVF
(
    @Quantity  INT,
    @UnitPrice DECIMAL(18,2),
    @Discount  DECIMAL(5,2)
)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(@Quantity * @UnitPrice * (1 - @Discount) AS DECIMAL(18,2)) AS 明細金額
);
GO

SELECT TOP (10)
       od.OrderId,
       od.ProductId,
       a.明細金額
FROM   dbo.OrderDetails AS od
CROSS  APPLY dbo.fn_Ex16_LineAmountTVF(od.Quantity, od.UnitPrice, od.Discount) AS a
ORDER  BY od.OrderId, od.ProductId;
GO

/* Q8 の説明: スカラーUDFが遅い理由(2つ以上)
   ① 行ごとに1回ずつ呼び出される(RBAR)。100万行なら100万回の呼び出しコスト。
   ② クエリ全体の並列実行を阻害し、シリアルプランに落ちることがある。
   ③ 関数内部のコストが実行プランに現れず、遅い原因が見えない。
   ④ WHERE dbo.fn_Xxx(列) = 値 と書くと非SARGableになりインデックスが使えない。
   ※ SQL Server 2019(互換性レベル150以上)の「スカラーUDFインライン化」で
      多くが式に展開され改善されたが、除外条件が多く常に効くわけではない。
      インライン化可否は sys.sql_modules の is_inlineable 列で確認できる。
   → iTVF + CROSS APPLY に書き換えれば、直接式を書いたのと同じプランになる。      */


-- Q9. 地域別の顧客売上を返す iTVF(推奨形)
--     ポイント: 本体は SELECT 1文のみ。BEGIN...END も DECLARE も書けない。
CREATE OR ALTER FUNCTION dbo.fn_Ex16_RegionSales
(
    @Region NVARCHAR(50)
)
RETURNS TABLE
AS
RETURN
(
    SELECT c.CustomerId,
           c.CustomerName,
           COUNT(DISTINCT o.OrderId)                            AS 注文件数,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))   AS 売上合計
    FROM   dbo.Customers    AS c
    JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
    WHERE  c.Region = @Region
    GROUP  BY c.CustomerId, c.CustomerName
);
GO

SELECT * FROM dbo.fn_Ex16_RegionSales(N'関東') ORDER BY 売上合計 DESC;
SELECT * FROM dbo.fn_Ex16_RegionSales(N'関西') ORDER BY 売上合計 DESC;
GO


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q10. 直近N件の注文を返す iTVF と OUTER APPLY / CROSS APPLY の違い
CREATE OR ALTER FUNCTION dbo.fn_Ex16_LatestOrders
(
    @CustomerId INT,
    @TopN       INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (@TopN)
           o.OrderId,
           o.OrderDate,
           o.ShipDate
    FROM   dbo.Orders AS o
    WHERE  o.CustomerId = @CustomerId
    ORDER  BY o.OrderDate DESC, o.OrderId DESC
);
GO

-- OUTER APPLY: 注文が無い顧客(11)も NULL 付きで残る
SELECT c.CustomerId,
       c.CustomerName,
       c.Region,
       l.OrderId,
       l.OrderDate,
       l.ShipDate
FROM   dbo.Customers AS c
OUTER  APPLY dbo.fn_Ex16_LatestOrders(c.CustomerId, 2) AS l
ORDER  BY c.CustomerId, l.OrderDate DESC;

-- CROSS APPLY: 右辺が 0 行の顧客は左の行ごと消える(顧客11 が結果に出ない)
SELECT c.CustomerId,
       c.CustomerName,
       c.Region,
       l.OrderId,
       l.OrderDate,
       l.ShipDate
FROM   dbo.Customers AS c
CROSS  APPLY dbo.fn_Ex16_LatestOrders(c.CustomerId, 2) AS l
ORDER  BY c.CustomerId, l.OrderDate DESC;
GO

/* Q10 の説明:
   CROSS APPLY は INNER JOIN 相当で、右辺(関数)が 0 行を返した左の行は捨てられる。
   OUTER APPLY は LEFT JOIN 相当で、左の行を残し右辺の列を NULL にする。
   サンプルDBでは顧客11(ラムダソフト)に注文が無いため、
   CROSS APPLY では顧客11 の行が消え、OUTER APPLY では残る。                     */


-- Q11. Q9 と同じ集計を MSTVF で書く
CREATE OR ALTER FUNCTION dbo.fn_Ex16_RegionSalesMS
(
    @Region NVARCHAR(50)
)
RETURNS @Result TABLE
(
    CustomerId   INT           NOT NULL PRIMARY KEY,
    CustomerName NVARCHAR(100) NOT NULL,
    注文件数      INT           NOT NULL,
    売上合計      DECIMAL(18,2) NULL
)
AS
BEGIN
    INSERT INTO @Result (CustomerId, CustomerName, 注文件数, 売上合計)
    SELECT c.CustomerId,
           c.CustomerName,
           COUNT(DISTINCT o.OrderId),
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
    FROM   dbo.Customers    AS c
    JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
    WHERE  c.Region = @Region
    GROUP  BY c.CustomerId, c.CustomerName;

    RETURN;      -- 引数なしの RETURN で @Result の中身を返す
END;
GO

SELECT * FROM dbo.fn_Ex16_RegionSalesMS(N'関東') ORDER BY 売上合計 DESC;

-- 結果は iTVF 版と同じ(件数を突き合わせて確認)
SELECT (SELECT COUNT(*) FROM dbo.fn_Ex16_RegionSales(N'関東'))   AS iTVF行数,
       (SELECT COUNT(*) FROM dbo.fn_Ex16_RegionSalesMS(N'関東')) AS MSTVF行数;
GO

/* Q11 の説明:
   ・iTVF は呼び出し元のクエリに「展開(インライン化)」されるため、
     オプティマイザが全体を1つのプランとして最適化できる。
     述語の押し下げ・結合順の入れ替え・並列化がすべて効き、統計情報も元テーブルのものが使われる。
   ・MSTVF は本体が展開されずブラックボックスになる。戻り値のテーブル変数には統計情報が無く、
     推定行数が固定値になる(SQL Server 2014 以降の新CEで 100 行、旧CEでは 1 行)。
     実際が100万行でも「100行」として計画されるため Nested Loops が選ばれ、壊滅的に遅くなりうる。
   ・SQL Server 2017(互換性レベル140以上)のインターリーブ実行で見積もり誤りは緩和されたが、
     「本体が展開されない」という本質は変わらない。
   → 第一選択は必ず iTVF。1文で書けないときだけ MSTVF を検討する。                */


-- Q12. 一時テーブルで段階的に処理するプロシージャ
CREATE OR ALTER PROCEDURE dbo.usp_Ex16_SalesReport
    @FromDate DATE,
    @ToDate   DATE
AS
BEGIN
    SET NOCOUNT ON;

    ----------------------------------------------------------
    -- ① 対象期間の注文を絞り込む
    ----------------------------------------------------------
    CREATE TABLE #TargetOrders (
        OrderId    INT  NOT NULL PRIMARY KEY,
        CustomerId INT  NOT NULL,
        OrderDate  DATE NOT NULL
    );

    INSERT INTO #TargetOrders (OrderId, CustomerId, OrderDate)
    SELECT o.OrderId, o.CustomerId, o.OrderDate
    FROM   dbo.Orders AS o
    WHERE  o.OrderDate >= @FromDate
      AND  o.OrderDate <  DATEADD(DAY, 1, @ToDate);   -- 終端は「翌日未満」で安全に

    ----------------------------------------------------------
    -- ② 注文ごとの金額を集計
    ----------------------------------------------------------
    CREATE TABLE #OrderAmount (
        OrderId INT           NOT NULL PRIMARY KEY,
        Amount  DECIMAL(18,2) NOT NULL
    );

    INSERT INTO #OrderAmount (OrderId, Amount)
    SELECT od.OrderId,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
    FROM   dbo.OrderDetails AS od
    JOIN   #TargetOrders    AS t ON t.OrderId = od.OrderId
    GROUP  BY od.OrderId;

    ----------------------------------------------------------
    -- ③ 顧客単位にまとめて返す
    ----------------------------------------------------------
    SELECT c.CustomerId,
           c.CustomerName,
           c.Region,
           COUNT(*)                         AS 注文件数,
           SUM(a.Amount)                    AS 売上合計,
           CAST(AVG(a.Amount) AS DECIMAL(18,2)) AS 平均注文金額
    FROM   #TargetOrders AS t
    JOIN   #OrderAmount  AS a ON a.OrderId = t.OrderId
    JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
    GROUP  BY c.CustomerId, c.CustomerName, c.Region
    ORDER  BY 売上合計 DESC;
END;
GO

EXEC dbo.usp_Ex16_SalesReport @FromDate = '2023-01-01', @ToDate = '2023-12-31';
GO

-- 一時テーブルの寿命の確認:
-- プロシージャ内で作った #TargetOrders は「プロシージャ終了時に自動で破棄」される。
-- 下の行のコメントを外すと「オブジェクト名 '#TargetOrders' が無効です」エラーになる。
-- SELECT * FROM #TargetOrders;
GO


------------------------------------------------------------
-- Q13. 後片付け(必ず実行すること)
------------------------------------------------------------

DROP PROCEDURE IF EXISTS dbo.usp_Ex16_GetProducts;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_GetCustomerOrders;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_CustomerStats;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_CheckProduct;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_ApplyDiscount;
DROP PROCEDURE IF EXISTS dbo.usp_Ex16_SalesReport;
GO

DROP FUNCTION IF EXISTS dbo.fn_Ex16_LineAmount;
DROP FUNCTION IF EXISTS dbo.fn_Ex16_LineAmountTVF;
DROP FUNCTION IF EXISTS dbo.fn_Ex16_RegionSales;
DROP FUNCTION IF EXISTS dbo.fn_Ex16_RegionSalesMS;
DROP FUNCTION IF EXISTS dbo.fn_Ex16_LatestOrders;
GO

-- 残っていないことの確認(0 行になれば OK)
SELECT o.name      AS オブジェクト名,
       o.type_desc AS 種別
FROM   sys.objects AS o
WHERE  o.type IN ('P', 'FN', 'IF', 'TF')   -- P=プロシージャ, FN=スカラー, IF=iTVF, TF=MSTVF
  AND  (o.name LIKE 'usp[_]Ex16[_]%' OR o.name LIKE 'fn[_]Ex16[_]%');
GO

-- (参考) SQL Server 2016 より前の環境では IF EXISTS が使えないため次のように書く
--   IF OBJECT_ID('dbo.usp_Ex16_GetProducts', 'P')  IS NOT NULL DROP PROCEDURE dbo.usp_Ex16_GetProducts;
--   IF OBJECT_ID('dbo.fn_Ex16_LineAmount',   'FN') IS NOT NULL DROP FUNCTION  dbo.fn_Ex16_LineAmount;
--   IF OBJECT_ID('dbo.fn_Ex16_RegionSales',  'IF') IS NOT NULL DROP FUNCTION  dbo.fn_Ex16_RegionSales;
--   IF OBJECT_ID('dbo.fn_Ex16_RegionSalesMS','TF') IS NOT NULL DROP FUNCTION  dbo.fn_Ex16_RegionSalesMS;
