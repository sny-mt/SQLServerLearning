/* ============================================================
   解答例 17 — ユーザー定義型とテーブル値パラメータ (TVP)
   対象演習: exercises/17_user_defined_types.md
   ------------------------------------------------------------
   ★重要1: 本章は 型(TYPE)・プロシージャ(PROCEDURE)・テーブルを
     作成する。サンプルDBを散らかさないため、最後の Q13 で
     すべて削除する。
   ★重要2: 削除には順序がある。
       DROP PROCEDURE  →  DROP TYPE
     型を使っているプロシージャが残っていると
     DROP TYPE はエラー 3732 で失敗する。「使っている側が先」。
   ★重要3: データを書き換える箇所はすべて
     BEGIN TRAN ... ROLLBACK で囲む。COMMIT は絶対にしない。
   ★重要4: DECLARE した変数はバッチ(GO)をまたげない。
     宣言と使用は同じバッチに書くこと。
   ============================================================ */
USE SalesLearning;
GO

/* 念のため、実行前に前回の残骸を片付けておく
   (プロシージャ → 型 の順であることに注目)                     */
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrderLarge;
DROP PROCEDURE IF EXISTS dbo.usp_MergeOrderDetails;
DROP PROCEDURE IF EXISTS dbo.usp_AddOrderDetail;
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrder;
DROP TYPE      IF EXISTS dbo.OrderDetailType;
DROP TABLE     IF EXISTS dbo.CustomerPhones;
DROP TYPE      IF EXISTS dbo.PhoneNumber;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 別名データ型 dbo.PhoneNumber を作り、sys.types で確認し、変数で使う
CREATE TYPE dbo.PhoneNumber FROM NVARCHAR(20) NOT NULL;
GO

SELECT SCHEMA_NAME(schema_id)       AS スキーマ,
       name                         AS 型名,
       TYPE_NAME(system_type_id)    AS 基になる型,
       max_length                   AS 最大バイト数,   -- NVARCHAR(20) なので 40
       is_nullable                  AS NULL可,         -- NOT NULL 定義なので 0
       is_user_defined              AS ユーザー定義,
       is_table_type                AS テーブル型か    -- 別名型なので 0
FROM   sys.types
WHERE  name = N'PhoneNumber';

-- 変数の型として使う
DECLARE @tel dbo.PhoneNumber = N'03-1234-5678';
SELECT @tel AS 電話番号, LEN(@tel) AS 文字数;
GO


-- Q2. 別名型を列の型に使うテーブルを作り、依存を調べる
CREATE TABLE dbo.CustomerPhones
(
    CustomerId INT             NOT NULL PRIMARY KEY,
    Tel        dbo.PhoneNumber          -- NOT NULL は型の定義に含まれている
);
GO

-- PhoneNumber 型を使っている列の一覧
SELECT OBJECT_SCHEMA_NAME(c.object_id) AS スキーマ,
       OBJECT_NAME(c.object_id)        AS テーブル名,
       c.name                          AS 列名,
       c.is_nullable                   AS NULL可
FROM   sys.columns AS c
JOIN   sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE  t.name = N'PhoneNumber';
GO


-- Q3. 依存があると DROP TYPE は失敗する
--     ↓ 実行するとエラーになる(これが確認したいこと)
--     メッセージ 3732、レベル 16:
--       型 'PhoneNumber' は オブジェクト 'CustomerPhones' で参照されているため
--       削除できません。この型を参照するオブジェクトが他にもある可能性があります。
--     理由: 列の型として使われている = 型が消えるとテーブル定義が壊れるため、
--           SQL Server が依存関係を守って削除を拒否する。
DROP TYPE dbo.PhoneNumber;      -- ✗ ここでエラーになるのが正解
GO

-- 正しい順序 = 「使っている側を先に消す」
DROP TABLE IF EXISTS dbo.CustomerPhones;   -- (1) 使っている側
DROP TYPE  IF EXISTS dbo.PhoneNumber;      -- (2) 型
GO

-- 消えたことを確認(0 行になる)
SELECT name FROM sys.types WHERE name = N'PhoneNumber';
GO


-- Q4. ユーザー定義テーブル型 dbo.OrderDetailType を作る
CREATE TYPE dbo.OrderDetailType AS TABLE
(
    ProductId INT            NOT NULL,
    Quantity  INT            NOT NULL,
    UnitPrice DECIMAL(10, 0) NULL,                 -- NULL なら現在の商品単価を採用する約束
    Discount  DECIMAL(4, 2)  NOT NULL DEFAULT (0), -- 0.00〜1.00
    PRIMARY KEY (ProductId),                       -- 同じ商品が2回来たら弾く
    CHECK (Quantity > 0),
    CHECK (Discount >= 0 AND Discount <= 1)
);
GO
-- ポイント:
--   ・主キー / UNIQUE / CHECK / DEFAULT / NOT NULL は型定義に書ける
--     = 「渡ってくるデータの検品ルール」を型そのものに埋め込める。
--   ・外部キー (FOREIGN KEY) は書けない。参照整合性はプロシージャ側で確認する。
--   ・制約に名前は付けないこと(同じ型を同時に複数使うと名前が衝突する)。

-- 型の列構成を確認する。sys.columns との結合キーは type_table_object_id(ここが要)
SELECT SCHEMA_NAME(tt.schema_id)  AS スキーマ,
       tt.name                    AS 型名,
       c.column_id                AS 列順,
       c.name                     AS 列名,
       TYPE_NAME(c.user_type_id)  AS データ型,
       c.precision, c.scale,
       c.is_nullable              AS NULL可
FROM   sys.table_types AS tt
JOIN   sys.columns     AS c ON c.object_id = tt.type_table_object_id
WHERE  tt.name = N'OrderDetailType'
ORDER  BY c.column_id;

-- 型に定義した主キーも確認できる
SELECT tt.name AS 型名, i.name AS インデックス名, i.type_desc, i.is_primary_key
FROM   sys.table_types AS tt
JOIN   sys.indexes     AS i ON i.object_id = tt.type_table_object_id
WHERE  tt.name = N'OrderDetailType';
GO


-- Q5. テーブル型の変数を宣言して使う
DECLARE @Details AS dbo.OrderDetailType;

INSERT INTO @Details (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 2, 128000, 0.10);            -- ノートPC

INSERT INTO @Details (ProductId, Quantity, UnitPrice)   -- ★ Discount を省略 → 既定値 0
VALUES (2, 5, 2800);                    -- ワイヤレスマウス

INSERT INTO @Details (ProductId, Quantity, UnitPrice, Discount)
VALUES (3, 1, NULL, 0.05);              -- メカニカルキーボード(単価はサーバー側に任せる)

SELECT p.ProductName                                       AS 商品名,
       d.Quantity                                          AS 数量,
       COALESCE(d.UnitPrice, p.UnitPrice)                  AS 採用単価,
       d.Discount                                          AS 割引率,
       d.Quantity * COALESCE(d.UnitPrice, p.UnitPrice)
                  * (1 - d.Discount)                       AS 明細金額
FROM   @Details     AS d
JOIN   dbo.Products AS p ON p.ProductId = d.ProductId
ORDER  BY d.ProductId;
GO


-- Q6. 主キー違反の確認
--     型定義に PRIMARY KEY (ProductId) を書いたので、
--     同じ ProductId を2回入れようとすると主キー違反(エラー 2627)になる。
--     → 実務では「アプリが同じ商品を2行送ってきた」というバグを、
--        サーバー側のロジックを1行も書かずに型だけで弾けるということ。
DECLARE @Dup AS dbo.OrderDetailType;

INSERT INTO @Dup (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 2, 128000, 0.10);

INSERT INTO @Dup (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 3, 128000, 0.00);   -- ✗ メッセージ 2627: 主キー制約違反

SELECT * FROM @Dup;            -- 1 行しか入っていない
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q7. TVP を受け取るストアドプロシージャ
CREATE OR ALTER PROCEDURE dbo.usp_RegisterOrder
    @CustomerId INT,
    @EmployeeId INT,
    @OrderDate  DATE,
    @Details    dbo.OrderDetailType READONLY,   -- ★ READONLY は必須
    @NewOrderId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;          -- エラー時は自動でロールバック

    -- (1) 入力の検証 -------------------------------------------------
    --     TVP に NULL は渡せない。引数を省略すると「0 行」として届くので、
    --     空判定は EXISTS で行う。
    IF NOT EXISTS (SELECT 1 FROM @Details)
        THROW 50001, N'注文明細が1行もありません。', 1;

    IF EXISTS (SELECT 1
               FROM   @Details AS d
               WHERE  NOT EXISTS (SELECT 1 FROM dbo.Products AS p
                                  WHERE  p.ProductId = d.ProductId))
        THROW 50002, N'存在しない ProductId が含まれています。', 1;

    -- (2) 登録 -------------------------------------------------------
    BEGIN TRAN;

        -- このサンプルDBの Orders.OrderId は IDENTITY ではないので自前で採番する
        SELECT @NewOrderId = ISNULL(MAX(OrderId), 1000) + 1
        FROM   dbo.Orders WITH (UPDLOCK, HOLDLOCK);

        INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
        VALUES (@NewOrderId, @CustomerId, @EmployeeId, @OrderDate, NULL);

        -- ★ ここが主役: TVP を INSERT ... SELECT で一括投入(ループの代わり)
        INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
        SELECT @NewOrderId,
               d.ProductId,
               d.Quantity,
               COALESCE(d.UnitPrice, p.UnitPrice),   -- 単価未指定なら現在の商品単価
               d.Discount
        FROM   @Details     AS d
        JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;

    COMMIT;
END
GO

-- 実行テスト(BEGIN TRAN ... ROLLBACK で囲むので DB は元のまま)
BEGIN TRAN;

DECLARE @D  AS dbo.OrderDetailType;
DECLARE @Id INT;

INSERT INTO @D (ProductId, Quantity, UnitPrice, Discount)
VALUES (1,  1, NULL, 0.05),
       (2,  3, NULL, 0.00),
       (16, 2, NULL, 0.10);

EXEC dbo.usp_RegisterOrder
     @CustomerId = 1,
     @EmployeeId = 2,
     @OrderDate  = '2024-02-01',
     @Details    = @D,
     @NewOrderId = @Id OUTPUT;

SELECT @Id AS 採番されたOrderId;      -- 既存が 1020 までなので 1021 になる

SELECT o.OrderId, c.CustomerName, p.ProductName, od.Quantity, od.UnitPrice, od.Discount,
       od.Quantity * od.UnitPrice * (1 - od.Discount) AS 明細金額
FROM   dbo.Orders       AS o
JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
JOIN   dbo.Products     AS p  ON p.ProductId  = od.ProductId
WHERE  o.OrderId = @Id
ORDER  BY p.ProductId;

ROLLBACK;   -- 追加した注文をなかったことにする
GO
-- 補足: プロシージャ内の BEGIN TRAN は「入れ子」になるだけ(@@TRANCOUNT が 2 になる)。
--       内側の COMMIT はカウンタを 1 に戻すだけで確定はせず、
--       外側の ROLLBACK ですべてが取り消される。だから学習中も安全に試せる。

-- 空の TVP を渡すと THROW 50001 になることも確認しておく
BEGIN TRAN;
DECLARE @Empty AS dbo.OrderDetailType;   -- 1 行も入れない
DECLARE @Id2 INT;
BEGIN TRY
    EXEC dbo.usp_RegisterOrder 1, 2, '2024-02-01', @Empty, @Id2 OUTPUT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;   -- 50001
END CATCH
ROLLBACK;
GO


-- Q8. READONLY を付け忘れたときのエラーと、TVP が変更できないことの確認

--     (a) READONLY を外すと、そもそも CREATE PROCEDURE が失敗する。
--         メッセージ 352、レベル 15:
--           テーブル値パラメーター "@Details" は READONLY と宣言する必要があります。
--         ↓ 確認したいときだけコメントを外して実行すること
/*
CREATE PROCEDURE dbo.usp_Bad
    @Details dbo.OrderDetailType        -- ✗ READONLY が無い
AS
BEGIN
    SELECT * FROM @Details;
END
GO
*/

--     (b) READONLY を付けたプロシージャの中で TVP を書き換えようとすると失敗する。
--         メッセージ 10700、レベル 16:
--           テーブル値パラメーター "@Details" は読み取り専用のため変更できません。
--         UPDATE / INSERT / DELETE すべて不可。OUTPUT パラメーターにもできない。
/*
CREATE OR ALTER PROCEDURE dbo.usp_Bad2
    @Details dbo.OrderDetailType READONLY
AS
BEGIN
    UPDATE @Details SET Quantity = 0;   -- ✗ 読み取り専用
END
GO
*/

--     (c) 加工したいときの正解:
--         別のテーブル変数、または一時テーブルに SELECT で写してから操作する。
--         (この「写す」テクニックは Q11 の性能対策とまったく同じ)
CREATE OR ALTER PROCEDURE dbo.usp_ShowNormalized
    @Details dbo.OrderDetailType READONLY
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Work AS dbo.OrderDetailType;      -- ★ 書き換え可能なコピーを作る

    INSERT INTO @Work (ProductId, Quantity, UnitPrice, Discount)
    SELECT ProductId, Quantity, UnitPrice, Discount
    FROM   @Details;

    UPDATE @Work SET Discount = 0 WHERE Discount > 0.5;   -- コピーなら更新できる

    SELECT * FROM @Work;
END
GO

DECLARE @D8 AS dbo.OrderDetailType;
INSERT INTO @D8 (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 1, NULL, 0.80),
       (2, 1, NULL, 0.10);
EXEC dbo.usp_ShowNormalized @D8;      -- 商品1の割引率が 0 に補正されている
GO

DROP PROCEDURE IF EXISTS dbo.usp_ShowNormalized;   -- 確認用なのでここで片付ける
GO


-- Q9. MERGE による明細の一括 UPSERT
CREATE OR ALTER PROCEDURE dbo.usp_MergeOrderDetails
    @OrderId INT,
    @Details dbo.OrderDetailType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    MERGE dbo.OrderDetails AS tgt
    USING (SELECT d.ProductId,
                  d.Quantity,
                  COALESCE(d.UnitPrice, p.UnitPrice) AS UnitPrice,
                  d.Discount
           FROM   @Details     AS d
           JOIN   dbo.Products AS p ON p.ProductId = d.ProductId) AS src
       ON  tgt.OrderId   = @OrderId
       AND tgt.ProductId = src.ProductId

    WHEN MATCHED AND (tgt.Quantity  <> src.Quantity
                   OR tgt.UnitPrice <> src.UnitPrice
                   OR tgt.Discount  <> src.Discount)
        THEN UPDATE SET tgt.Quantity  = src.Quantity,
                        tgt.UnitPrice = src.UnitPrice,
                        tgt.Discount  = src.Discount

    WHEN NOT MATCHED BY TARGET
        THEN INSERT (OrderId, ProductId, Quantity, UnitPrice, Discount)
             VALUES (@OrderId, src.ProductId, src.Quantity, src.UnitPrice, src.Discount)

    -- ★★ この AND tgt.OrderId = @OrderId が命綱 ★★
    --     MERGE のターゲットは dbo.OrderDetails 全体。書き忘れると
    --     「ソースに無い行」= 他の注文の明細まで全部 DELETE されてしまう。
    WHEN NOT MATCHED BY SOURCE AND tgt.OrderId = @OrderId
        THEN DELETE

    OUTPUT $action                                     AS 操作,
           ISNULL(INSERTED.ProductId, DELETED.ProductId) AS 商品Id,
           DELETED.Quantity                            AS 変更前数量,
           INSERTED.Quantity                           AS 変更後数量;
END
GO

-- 実行テスト
BEGIN TRAN;

SELECT * FROM dbo.OrderDetails WHERE OrderId = 1001 ORDER BY ProductId;   -- 実行前

DECLARE @D9 AS dbo.OrderDetailType;
INSERT INTO @D9 (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 10, NULL, 0.20),     -- 既存なら UPDATE / 無ければ INSERT
       (9, 50, NULL, 0.00);     -- INSERT

EXEC dbo.usp_MergeOrderDetails @OrderId = 1001, @Details = @D9;

SELECT * FROM dbo.OrderDetails WHERE OrderId = 1001 ORDER BY ProductId;   -- 実行後
SELECT COUNT(*) AS 他注文の明細件数 FROM dbo.OrderDetails WHERE OrderId <> 1001;  -- 減っていない

ROLLBACK;
GO

-- (別解) ターゲット自体を CTE で 1 注文に絞ると、絞り込みの書き忘れ事故を防げる。
/*
WITH tgt AS (SELECT * FROM dbo.OrderDetails WHERE OrderId = @OrderId)
MERGE tgt
USING (...) AS src ON tgt.ProductId = src.ProductId
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED BY TARGET THEN INSERT (...) VALUES (...)
WHEN NOT MATCHED BY SOURCE THEN DELETE;      -- 絞り込み済みなので安全
*/


-- Q10. 「1行ずつ N 回」 vs 「TVP で1回」

-- 1行だけ登録するプロシージャ(方式A 用)
CREATE OR ALTER PROCEDURE dbo.usp_AddOrderDetail
    @OrderId   INT,
    @ProductId INT,
    @Quantity  INT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
    SELECT @OrderId, @ProductId, @Quantity, p.UnitPrice, 0
    FROM   dbo.Products AS p
    WHERE  p.ProductId = @ProductId;
END
GO

-- 【方式A】ループで 10 回呼ぶ
BEGIN TRAN;

DECLARE @OidA INT = (SELECT ISNULL(MAX(OrderId), 1000) + 1 FROM dbo.Orders);
INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
VALUES (@OidA, 1, 2, '2024-02-05', NULL);

DECLARE @i INT = 1;
WHILE @i <= 10
BEGIN
    EXEC dbo.usp_AddOrderDetail @OrderId = @OidA, @ProductId = @i, @Quantity = @i;
    SET @i += 1;
END

SELECT @OidA AS 方式A_OrderId, COUNT(*) AS 明細件数
FROM   dbo.OrderDetails WHERE OrderId = @OidA;

ROLLBACK;
GO

-- 【方式B】TVP に詰めて 1 回で登録
BEGIN TRAN;

DECLARE @OidB INT = (SELECT ISNULL(MAX(OrderId), 1000) + 1 FROM dbo.Orders);
INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
VALUES (@OidB, 1, 2, '2024-02-05', NULL);

DECLARE @D10 AS dbo.OrderDetailType;
INSERT INTO @D10 (ProductId, Quantity)
VALUES (1,1),(2,2),(3,3),(4,4),(5,5),(6,6),(7,7),(8,8),(9,9),(10,10);

INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)   -- ★ 1 文だけ
SELECT @OidB, d.ProductId, d.Quantity, COALESCE(d.UnitPrice, p.UnitPrice), d.Discount
FROM   @D10         AS d
JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;

SELECT @OidB AS 方式B_OrderId, COUNT(*) AS 明細件数
FROM   dbo.OrderDetails WHERE OrderId = @OidB;

ROLLBACK;
GO

/* Q10 の説明 ------------------------------------------------------
   結果はどちらも明細 10 行で同じ。ではどこが違うのか。

   このスクリプトは「SQL Server の中だけ」で 10 回ループしているので、
   本当の差が見えない。実務ではループを回すのは
   ★アプリケーション側★ であり、EXEC 1 回ごとに
   「アプリ → ネットワーク → SQL Server → ネットワーク → アプリ」
   という 往復(ラウンドトリップ)が発生する。

     方式A: ラウンドトリップ 10 回(明細 500 行なら 500 回)
     方式B: ラウンドトリップ  1 回(明細 500 行でも 1 回)

   1 往復に 1ms かかる環境なら、500 行の登録は
     方式A = 0.5 秒がまるまる待ち時間
     方式B = 1ms
   DB サーバーが物理的に離れているほど差は劇的に開く。

   さらに方式B には次の利点もある。
     ・プロシージャ内で 1 トランザクションにまとめられる
       (方式A は途中で落ちると中途半端な状態が残りうる)
     ・検証(存在チェック・重複チェック)を「集合」として 1 回で行える
     ・ロックの保持が短時間で済み、ログ出力もまとまる

   これが TVP を使う最大の理由。
------------------------------------------------------------------ */


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q11. TVP を一時テーブルに受け直してから処理する
CREATE OR ALTER PROCEDURE dbo.usp_RegisterOrderLarge
    @CustomerId INT,
    @EmployeeId INT,
    @OrderDate  DATE,
    @Details    dbo.OrderDetailType READONLY,
    @NewOrderId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ★ TVP → 一時テーブルへ受け直す
    CREATE TABLE #Details
    (
        ProductId INT            NOT NULL PRIMARY KEY,
        Quantity  INT            NOT NULL,
        UnitPrice DECIMAL(10, 0) NULL,
        Discount  DECIMAL(4, 2)  NOT NULL
    );

    INSERT INTO #Details (ProductId, Quantity, UnitPrice, Discount)
    SELECT ProductId, Quantity, UnitPrice, Discount
    FROM   @Details;

    IF NOT EXISTS (SELECT 1 FROM #Details)
        THROW 50001, N'注文明細が1行もありません。', 1;

    IF EXISTS (SELECT 1
               FROM   #Details AS d
               WHERE  NOT EXISTS (SELECT 1 FROM dbo.Products AS p
                                  WHERE  p.ProductId = d.ProductId))
        THROW 50002, N'存在しない ProductId が含まれています。', 1;

    BEGIN TRAN;

        SELECT @NewOrderId = ISNULL(MAX(OrderId), 1000) + 1
        FROM   dbo.Orders WITH (UPDLOCK, HOLDLOCK);

        INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
        VALUES (@NewOrderId, @CustomerId, @EmployeeId, @OrderDate, NULL);

        -- これ以降は #Details を使う。統計情報があるので適切なプランが選ばれる
        INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
        SELECT @NewOrderId, d.ProductId, d.Quantity,
               COALESCE(d.UnitPrice, p.UnitPrice), d.Discount
        FROM   #Details     AS d
        JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;

    COMMIT;

    DROP TABLE #Details;
END
GO

-- 実行テスト
BEGIN TRAN;

DECLARE @D11 AS dbo.OrderDetailType;
DECLARE @Id11 INT;

INSERT INTO @D11 (ProductId, Quantity, UnitPrice, Discount)
VALUES (6, 4, NULL, 0.00),
       (7, 2, NULL, 0.15);

EXEC dbo.usp_RegisterOrderLarge 4, 4, '2024-02-10', @D11, @Id11 OUTPUT;

SELECT * FROM dbo.OrderDetails WHERE OrderId = @Id11;

ROLLBACK;
GO

/* Q11 の説明 ------------------------------------------------------
   なぜわざわざ写すのか:

   TVP の実体は「テーブル変数」であり、テーブル変数は
   ★統計情報を持たない★(15章)。そのためオプティマイザーは
   TVP の行数を「1 行」と見積もる。実際に 5 万行入っていてもだ。

   結果、「1 行なら最適」なプラン=ネステッドループ結合が選ばれ、
   実際には大量行が流れてきて内側テーブルへのアクセスが
   何万回も繰り返される → 極端に遅くなる。
   実行プランで「推定行数 1 / 実際の行数 50000」という乖離を見たら、これ。

   一時テーブル(#Details)に写すと
     ・統計情報が作られる → 行数に見合ったプランが選ばれる
     ・インデックスを追加で張れる
     ・READONLY ではないので中身を加工できる
   というメリットが得られる。写すコストと引き換えなので、
   数十〜数百行なら不要、数千行を超えるなら効いてくる、が目安。

   写す以外の対策:
     (1) TVP を参照するクエリに OPTION (RECOMPILE) を付ける
         → 実行時の実際の行数を見てプランを立て直す。
           ただし毎回コンパイルするので CPU を使う。高頻度の軽い
           クエリには使わない。
     (2) SQL Server 2019 以降 + 互換性レベル 150 以上にする
         → 「テーブル変数の遅延コンパイル」により、実際の行数で
           プランが作られるようになり問題がかなり緩和される。
           確認: SELECT name, compatibility_level FROM sys.databases
                 WHERE name = DB_NAME();
------------------------------------------------------------------ */


-- Q12. 型定義の変更 (Discount を DECIMAL(4,2) → DECIMAL(5,3) に)

--   (a) ALTER TYPE は存在しない。次のような構文は書けない。
--       ALTER TYPE dbo.OrderDetailType ...;      -- ✗ そんな構文は無い

--   (b) そのまま DROP TYPE すると失敗する。
--       メッセージ 3732、レベル 16:
--         型 'OrderDetailType' は オブジェクト 'usp_RegisterOrder' で
--         参照されているため削除できません。
DROP TYPE dbo.OrderDetailType;      -- ✗ ここでエラーになるのが正解
GO

--   (c) 正しい手順 (1) — 誰がこの型を使っているか調べる
SELECT OBJECT_SCHEMA_NAME(p.object_id) AS スキーマ,
       OBJECT_NAME(p.object_id)        AS オブジェクト名,
       o.type_desc                     AS 種類,
       p.name                          AS パラメーター名
FROM   sys.parameters AS p
JOIN   sys.types      AS t ON t.user_type_id = p.user_type_id
JOIN   sys.objects    AS o ON o.object_id    = p.object_id
WHERE  t.name = N'OrderDetailType'
ORDER  BY オブジェクト名;
GO

--   (d) 正しい手順 (2) — 依存するプロシージャを先に削除する
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrderLarge;
DROP PROCEDURE IF EXISTS dbo.usp_MergeOrderDetails;
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrder;
GO

--   (e) 正しい手順 (3) — 型を削除して作り直す
DROP TYPE IF EXISTS dbo.OrderDetailType;
GO

CREATE TYPE dbo.OrderDetailType AS TABLE
(
    ProductId INT            NOT NULL,
    Quantity  INT            NOT NULL,
    UnitPrice DECIMAL(10, 0) NULL,
    Discount  DECIMAL(5, 3)  NOT NULL DEFAULT (0),   -- ★ 変更点: 0.125 のような3桁が扱える
    PRIMARY KEY (ProductId),
    CHECK (Quantity > 0),
    CHECK (Discount >= 0 AND Discount <= 1)
);
GO

--   (f) 正しい手順 (4) — プロシージャを作り直す(定義は Q7 と同じ)
CREATE OR ALTER PROCEDURE dbo.usp_RegisterOrder
    @CustomerId INT,
    @EmployeeId INT,
    @OrderDate  DATE,
    @Details    dbo.OrderDetailType READONLY,
    @NewOrderId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Details)
        THROW 50001, N'注文明細が1行もありません。', 1;

    IF EXISTS (SELECT 1
               FROM   @Details AS d
               WHERE  NOT EXISTS (SELECT 1 FROM dbo.Products AS p
                                  WHERE  p.ProductId = d.ProductId))
        THROW 50002, N'存在しない ProductId が含まれています。', 1;

    BEGIN TRAN;

        SELECT @NewOrderId = ISNULL(MAX(OrderId), 1000) + 1
        FROM   dbo.Orders WITH (UPDLOCK, HOLDLOCK);

        INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
        VALUES (@NewOrderId, @CustomerId, @EmployeeId, @OrderDate, NULL);

        INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
        SELECT @NewOrderId, d.ProductId, d.Quantity,
               COALESCE(d.UnitPrice, p.UnitPrice), d.Discount
        FROM   @Details     AS d
        JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;

    COMMIT;
END
GO

--   (g) 変わったことを確認する: Discount の precision=5 / scale=3 になっている
SELECT tt.name AS 型名, c.name AS 列名,
       TYPE_NAME(c.user_type_id) AS データ型,
       c.precision, c.scale
FROM   sys.table_types AS tt
JOIN   sys.columns     AS c ON c.object_id = tt.type_table_object_id
WHERE  tt.name = N'OrderDetailType'
ORDER  BY c.column_id;
GO

--   (h) 新しい型で動作確認
BEGIN TRAN;

DECLARE @D12 AS dbo.OrderDetailType;
DECLARE @Id12 INT;

INSERT INTO @D12 (ProductId, Quantity, UnitPrice, Discount)
VALUES (13, 6, NULL, 0.125);     -- ★ 3桁の割引率

EXEC dbo.usp_RegisterOrder 5, 3, '2024-02-15', @D12, @Id12 OUTPUT;

-- 注意: OrderDetails.Discount は DECIMAL(4,2) のままなので、
--       0.125 は格納時に 0.13 に丸められる。
--       型を広げるときは「渡す側」だけでなく「入れる先」も見直すこと。
SELECT ProductId, Quantity, UnitPrice, Discount FROM dbo.OrderDetails WHERE OrderId = @Id12;

ROLLBACK;
GO

/* 補足: 本番環境で無停止に変えたいとき ----------------------------
   上の手順は、一瞬とはいえプロシージャが存在しない時間ができる。
   それが許されない場合は
     (1) 新しい名前の型 dbo.OrderDetailType_v2 を作る
     (2) それを使う新しいプロシージャを追加する
     (3) アプリを新プロシージャに切り替える
     (4) 旧プロシージャ → 旧型 の順に削除する
   という「並走させてから捨てる」進め方をする。
   型名にバージョンを付けるのは実務でよく見る割り切り。
------------------------------------------------------------------ */


-- Q13. 後片付け(★プロシージャ → 型 の順で!)
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrderLarge;   -- Q12(d) で削除済みだが念のため
DROP PROCEDURE IF EXISTS dbo.usp_MergeOrderDetails;    -- 同上
DROP PROCEDURE IF EXISTS dbo.usp_AddOrderDetail;
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrder;
GO

DROP TYPE IF EXISTS dbo.OrderDetailType;
GO

-- 別名型とテーブルは Q3 で片付け済み。念のためもう一度(順序は テーブル → 型)
DROP TABLE IF EXISTS dbo.CustomerPhones;
DROP TYPE  IF EXISTS dbo.PhoneNumber;
GO

-- 確認 (1): ユーザー定義型が残っていないこと(0 行になれば OK)
SELECT SCHEMA_NAME(schema_id) AS スキーマ, name AS 型名, is_table_type AS テーブル型か
FROM   sys.types
WHERE  is_user_defined = 1;

-- 確認 (2): テーブル型が残っていないこと(0 行になれば OK)
SELECT name AS 型名 FROM sys.table_types WHERE is_user_defined = 1;

-- 確認 (3): 本章で作ったプロシージャが残っていないこと(0 行になれば OK)
SELECT name AS プロシージャ名
FROM   sys.procedures
WHERE  name IN (N'usp_RegisterOrder', N'usp_RegisterOrderLarge',
                N'usp_MergeOrderDetails', N'usp_AddOrderDetail',
                N'usp_ShowNormalized');

-- 確認 (4): データが元どおりであること(20 行 / 42 行)
SELECT (SELECT COUNT(*) FROM dbo.Orders)       AS 注文件数,     -- 20
       (SELECT COUNT(*) FROM dbo.OrderDetails) AS 明細件数;     -- 42
GO
