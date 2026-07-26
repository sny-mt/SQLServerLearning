/* ============================================================
   解答例 20 — 動的SQL
   対象演習: exercises/20_dynamic_sql.md
   ------------------------------------------------------------
   ★方針:
     - 値は必ず sys.sp_executesql のパラメータで渡す(連結しない)。
     - 識別子(列名・テーブル名)はパラメータ化できないため、
       ホワイトリスト検証 + QUOTENAME() を通してから連結する。
     - SQL文を入れる変数は必ず NVARCHAR(MAX)。
     - 実行前に PRINT / SELECT で生成SQLを目視確認する。
     - データを変更する解答は BEGIN TRAN ... ROLLBACK で囲む(COMMIT しない)。
     - 作成したプロシージャは DROP PROCEDURE IF EXISTS で必ず後片付けする。
   ★各問は GO で区切ってある(同名変数を何度も DECLARE するため)。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. もっとも基本の動的SQL。生成SQLを PRINT / SELECT で確認してから実行する。
DECLARE @sql NVARCHAR(MAX);          -- ★必ず NVARCHAR(MAX)

SET @sql = N'
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY ProductId;';

PRINT @sql;                          -- メッセージタブ(改行が保たれる。4000文字で切れる点に注意)
SELECT @sql AS 生成SQL;              -- 結果グリッド(長文でも保持される)

EXEC sys.sp_executesql @sql;
GO


-- Q2. 値はパラメータで渡す。@CategoryId を連結しないのがポイント。
DECLARE @CategoryId INT = 1;
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
WHERE  CategoryId = @CategoryId
ORDER  BY UnitPrice DESC;';

PRINT @sql;

EXEC sys.sp_executesql @sql,
     N'@CategoryId INT',             -- ② パラメータの宣言
     @CategoryId = @CategoryId;      -- ③ 実際の値
GO


-- Q3. OUTPUT パラメータで、動的SQLの中で計算した値を呼び出し元に戻す。
--     ★宣言部と実引数の「両方」に OUTPUT が必要。片方でも忘れると無言で NULL になる。
DECLARE @CustomerId INT = 1;
DECLARE @OrderCount INT;
DECLARE @Total      DECIMAL(18,2);
DECLARE @sql        NVARCHAR(MAX);

SET @sql = N'
SELECT @cnt = COUNT(DISTINCT o.OrderId),
       @sum = SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
WHERE  o.CustomerId = @CustomerId;';

PRINT @sql;

EXEC sys.sp_executesql @sql,
     N'@CustomerId INT, @cnt INT OUTPUT, @sum DECIMAL(18,2) OUTPUT',
     @CustomerId = @CustomerId,
     @cnt = @OrderCount OUTPUT,      -- ← OUTPUT を忘れない
     @sum = @Total      OUTPUT;

SELECT @CustomerId  AS 顧客Id,
       @OrderCount  AS 注文件数,     -- 顧客1は 1001/1004/1011/1020 の4件
       @Total       AS 売上合計;
GO


-- Q4. SQLインジェクションの体感 — 危険な連結版 と 安全なパラメータ版
DECLARE @Input NVARCHAR(100);
DECLARE @bad   NVARCHAR(MAX);

-- (1-a) 危険な版。正常な入力なら「一見」正しく動く
SET @Input = N'アルファ商事';
SET @bad = N'SELECT CustomerId, CustomerName FROM dbo.Customers
WHERE CustomerName = N''' + @Input + N''';';
PRINT @bad;
EXEC (@bad);        -- 1行だけ返る

-- (1-b) 同じコードに攻撃入力を与える
--       @Input の中身は  ' OR 1 = 1 --   (先頭がシングルクォート)
SET @Input = N''' OR 1 = 1 --';
SET @bad = N'SELECT CustomerId, CustomerName FROM dbo.Customers
WHERE CustomerName = N''' + @Input + N''';';
PRINT @bad;
/* 生成されるSQL:
     SELECT CustomerId, CustomerName FROM dbo.Customers
     WHERE CustomerName = N'' OR 1 = 1 --';
   → 入力のシングルクォートが文字列リテラルを途中で閉じ、
     続く OR 1 = 1 が「SQLコード」として解釈される。
     さらに -- で末尾の閉じクォートがコメント化され、構文エラーにもならない。
     結果、絞り込みが消滅して顧客12件すべてが返る。
     同じ手口で「; DROP TABLE ...; --」のような文の追加も可能。 */
EXEC (@bad);        -- 12行すべて返ってしまう

-- (2) 安全な版。同じ攻撃入力でも「ただの文字列」としてしか扱われない
SET @Input = N''' OR 1 = 1 --';
EXEC sys.sp_executesql
     N'SELECT CustomerId, CustomerName
       FROM   dbo.Customers
       WHERE  CustomerName = @Name;',
     N'@Name NVARCHAR(100)',
     @Name = @Input;   -- → 0行。そんな名前の顧客はいないので何も返らない = 攻撃不成立

-- ★結論: 対策は「入力のフィルタリング」ではなく「パラメータ化」ただ一つ。
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. ORDER BY の列を実行時に決める(識別子はパラメータ化できない)
--     → ホワイトリスト検証 + QUOTENAME の二重防御
DECLARE @SortColumn SYSNAME     = N'UnitPrice';
DECLARE @SortDir    NVARCHAR(4) = N'DESC';
DECLARE @sql        NVARCHAR(MAX);

-- ① 列名のホワイトリスト検証(許可した3列以外は拒否)
IF @SortColumn NOT IN (N'ProductId', N'ProductName', N'UnitPrice')
    THROW 50001, N'許可されていない並べ替え列が指定されました。', 1;

-- ② 方向も列挙で検証する(ここを素通しにすると穴になる)
IF @SortDir NOT IN (N'ASC', N'DESC')
    THROW 50002, N'並べ替え方向は ASC / DESC のみです。', 1;

-- ③ 識別子は QUOTENAME を通して連結
SET @sql = N'
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY ' + QUOTENAME(@SortColumn) + N' ' + @SortDir + N';';

PRINT @sql;
EXEC sys.sp_executesql @sql;
GO

-- (別解) 列の実在をカタログビューで確認する方式。
--        列が増減しても検証コードを直さずに済む反面、
--        「見せたくない列」まで許してしまうので用途に応じて使い分ける。
DECLARE @SortColumn SYSNAME = N'ProductName';
DECLARE @sql NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1
               FROM   sys.columns
               WHERE  object_id = OBJECT_ID(N'dbo.Products')
                 AND  name      = @SortColumn)
    THROW 50001, N'指定された列は dbo.Products に存在しません。', 1;

SET @sql = N'SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY ' + QUOTENAME(@SortColumn) + N';';

PRINT @sql;
EXEC sys.sp_executesql @sql;
GO

-- (確認) 許可外の値を与えるとエラーになること
--        ↓ コメントを外して実行すると Msg 50001 が返る
-- DECLARE @SortColumn SYSNAME = N'Salary';
-- IF @SortColumn NOT IN (N'ProductId', N'ProductName', N'UnitPrice')
--     THROW 50001, N'許可されていない並べ替え列が指定されました。', 1;
GO


-- Q6. 可変検索条件 — 指定された条件だけを組み立てる(方式C)
DECLARE @City       NVARCHAR(50) = N'東京';
DECLARE @Region     NVARCHAR(50) = NULL;
DECLARE @SalesRepId INT          = NULL;
DECLARE @sql        NVARCHAR(MAX);

SET @sql = N'
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  1 = 1';                       -- ★条件を常に AND で足せるようにする定石

IF @City       IS NOT NULL SET @sql += N'
  AND City = @City';
IF @Region     IS NOT NULL SET @sql += N'
  AND Region = @Region';
IF @SalesRepId IS NOT NULL SET @sql += N'
  AND SalesRepId = @SalesRepId';

SET @sql += N'
ORDER BY CustomerId;';

PRINT @sql;                          -- ★生成SQLを必ず確認

-- 使っていないパラメータもまとめて渡してよい(参照されなければ無視される)
EXEC sys.sp_executesql @sql,
     N'@City NVARCHAR(50), @Region NVARCHAR(50), @SalesRepId INT',
     @City = @City, @Region = @Region, @SalesRepId = @SalesRepId;
-- → 東京の顧客(1 アルファ商事 / 7 イータ建設 / 11 ラムダソフト)が返る
GO

-- (パターン2) 地域だけ指定 → WHERE に Region の条件だけが入る
DECLARE @City       NVARCHAR(50) = NULL;
DECLARE @Region     NVARCHAR(50) = N'関西';
DECLARE @SalesRepId INT          = NULL;
DECLARE @sql        NVARCHAR(MAX);

SET @sql = N'
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  1 = 1';

IF @City       IS NOT NULL SET @sql += N'
  AND City = @City';
IF @Region     IS NOT NULL SET @sql += N'
  AND Region = @Region';
IF @SalesRepId IS NOT NULL SET @sql += N'
  AND SalesRepId = @SalesRepId';

SET @sql += N'
ORDER BY CustomerId;';

PRINT @sql;
EXEC sys.sp_executesql @sql,
     N'@City NVARCHAR(50), @Region NVARCHAR(50), @SalesRepId INT',
     @City = @City, @Region = @Region, @SalesRepId = @SalesRepId;
GO

-- (パターン3) すべて NULL → WHERE 1 = 1 だけになり、全12件が返る
DECLARE @sql NVARCHAR(MAX) = N'
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  1 = 1
ORDER BY CustomerId;';

PRINT @sql;
EXEC sys.sp_executesql @sql;
GO


-- Q7. 同じ要件を静的SQLで書く(方式A / 方式B)
DECLARE @City       NVARCHAR(50) = N'東京';
DECLARE @Region     NVARCHAR(50) = NULL;
DECLARE @SalesRepId INT          = NULL;

-- 方式A: (@x IS NULL OR 列 = @x)。読みやすいが、性能面に問題がある。
--   ・実行プランは「最初に実行されたときのパラメータ」でコンパイルされキャッシュされる。
--   ・例えば「@City だけ指定」で作られたプランが、後の「@SalesRepId だけ指定」の
--     呼び出しにもそのまま使い回される(パラメータ・スニッフィングによるプランの偏り)。
--   ・どの列にもインデックスを効かせにくく、結果として全表スキャンに倒れやすい。
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  (@City       IS NULL OR City       = @City)
  AND  (@Region     IS NULL OR Region     = @Region)
  AND  (@SalesRepId IS NULL OR SalesRepId = @SalesRepId)
ORDER  BY CustomerId;

-- 方式B: OPTION (RECOMPILE) を付ける。実務での第一候補。
--   ・毎回コンパイルし直すため、その回の実際のパラメータに最適なプランが選ばれる
--     (キャッシュされたプランを使い回さない = 偏りが起きない)。
--   ・さらに「@Region IS NULL が真」と分かっている条件はコンパイル時に丸ごと除去される。
--     結果として「必要な条件だけのSQL」を動的に組み立てたのとほぼ同じプランになる。
--   ・代償は毎回のコンパイル費用。実行頻度が高く軽いクエリには不向き
--     → そのときだけ Q6 の動的SQL(方式C)に進む。
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  (@City       IS NULL OR City       = @City)
  AND  (@Region     IS NULL OR Region     = @Region)
  AND  (@SalesRepId IS NULL OR SalesRepId = @SalesRepId)
ORDER  BY CustomerId
OPTION (RECOMPILE);
GO


-- Q8. テーブル名を引数にして行数を返す(識別子の連結 + 実在検証)
DECLARE @TableName SYSNAME = N'Orders';
DECLARE @sql NVARCHAR(MAX);
DECLARE @cnt INT;

-- ① 実在するユーザーテーブル('U')かを検証。存在しなければ OBJECT_ID は NULL
IF OBJECT_ID(N'dbo.' + QUOTENAME(@TableName), N'U') IS NULL
    THROW 50003, N'指定されたテーブルは存在しません。', 1;

-- ② 識別子は QUOTENAME を通して連結する
SET @sql = N'SELECT @c = COUNT(*) FROM dbo.' + QUOTENAME(@TableName) + N';';
PRINT @sql;

EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @cnt OUTPUT;

SELECT @TableName AS テーブル, @cnt AS 行数;   -- Orders → 20
GO

-- 同じ手順で OrderDetails を数える(→ 42)
DECLARE @TableName SYSNAME = N'OrderDetails';
DECLARE @sql NVARCHAR(MAX);
DECLARE @cnt INT;

IF OBJECT_ID(N'dbo.' + QUOTENAME(@TableName), N'U') IS NULL
    THROW 50003, N'指定されたテーブルは存在しません。', 1;

SET @sql = N'SELECT @c = COUNT(*) FROM dbo.' + QUOTENAME(@TableName) + N';';
PRINT @sql;
EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @cnt OUTPUT;

SELECT @TableName AS テーブル, @cnt AS 行数;
GO

-- (確認) 存在しないテーブル名は連結する前に弾かれる
--        ↓ コメントを外すと Msg 50003 が返る(動的SQLは組み立てられもしない)
-- DECLARE @TableName SYSNAME = N'NotExists';
-- IF OBJECT_ID(N'dbo.' + QUOTENAME(@TableName), N'U') IS NULL
--     THROW 50003, N'指定されたテーブルは存在しません。', 1;
GO


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q9. 動的 PIVOT(10章の宿題の回収) — 地域 × 年 の売上
--     手順: ①列リストを作る → ②PIVOT 文を組み立てる → ③sp_executesql で実行
DECLARE @cols NVARCHAR(MAX);
DECLARE @sql  NVARCHAR(MAX);

-- ① 実在する年から列見出しの一覧を作る。
--    ・年は数値なので、そのままでは識別子にならない → QUOTENAME が [2023] の角括弧を付ける
--    ・STRING_AGG は SQL Server 2017 以降
--    ・WITHIN GROUP (ORDER BY ...) が無いと列の並び順が不定になり得る
SELECT @cols = STRING_AGG(QUOTENAME(y.年), N', ') WITHIN GROUP (ORDER BY y.年)
FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y;

SELECT @cols AS 生成した列リスト;    -- → [2023], [2024]

-- ② PIVOT 文を組み立てる。
--    ソースは「地域 / 年 / 売上」の3列だけ(余計な列は暗黙のグループ化キーになる = 10章3節)
SET @sql = N'
SELECT *
FROM (
    SELECT c.Region                                       AS 地域,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY 地域;';

-- ③ 生成SQLを確認してから実行
PRINT @sql;
EXEC sys.sp_executesql @sql;
GO

-- (別解) 空セルを 0 で埋めたい場合。列リストが動的なので、
--        0埋め用の SELECT リストも一緒に組み立てる。
DECLARE @cols NVARCHAR(MAX), @selectList NVARCHAR(MAX), @sql NVARCHAR(MAX);

SELECT @cols       = STRING_AGG(QUOTENAME(y.年), N', ') WITHIN GROUP (ORDER BY y.年),
       @selectList = STRING_AGG(N'COALESCE(' + QUOTENAME(y.年) + N', 0) AS ' + QUOTENAME(y.年),
                                N', ') WITHIN GROUP (ORDER BY y.年)
FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y;

SET @sql = N'
SELECT 地域, ' + @selectList + N'
FROM (
    SELECT c.Region                                       AS 地域,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY 地域;';

PRINT @sql;
EXEC sys.sp_executesql @sql;
GO


-- Q10. 列リストの組み立てを FOR XML PATH + STUFF で(SQL Server 2016 でも動く書き方)
DECLARE @cols NVARCHAR(MAX);
DECLARE @sql  NVARCHAR(MAX);

--  ・FOR XML PATH(N'') … 要素名なしで連結した1つの文字列を作る
--  ・.value(N'.', N'NVARCHAR(MAX)') … & や < が実体参照(&amp; など)に化けるのを防ぐ
--  ・STUFF(..., 1, 2, N'') … 先頭の区切り ', '(2文字)を削る
SELECT @cols = STUFF((
        SELECT N', ' + QUOTENAME(y.年)
        FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y
        ORDER  BY y.年
        FOR XML PATH(N''), TYPE
    ).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @cols AS 生成した列リスト;    -- → [2023], [2024](Q9 と同じ)

SET @sql = N'
SELECT *
FROM (
    SELECT c.Region                                       AS 地域,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY 地域;';

PRINT @sql;
EXEC sys.sp_executesql @sql;
GO


-- Q11. 動的 PIVOT をストアドプロシージャにまとめる(カテゴリ × 年)
DROP PROCEDURE IF EXISTS dbo.usp_SalesPivotByCategory;   -- SQL Server 2016 以降の書き方
GO

CREATE PROCEDURE dbo.usp_SalesPivotByCategory
    @Debug BIT = 0        -- 1 なら実行せず生成SQLを PRINT するだけ
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cols NVARCHAR(MAX);
    DECLARE @sql  NVARCHAR(MAX);

    SELECT @cols = STRING_AGG(QUOTENAME(y.年), N', ') WITHIN GROUP (ORDER BY y.年)
    FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y;

    -- ★STRING_AGG は対象行が0件だと NULL を返す。NULL を連結すると @sql が丸ごと NULL になる
    IF @cols IS NULL
    BEGIN
        SELECT N'対象データがありません。' AS メッセージ;
        RETURN;
    END;

    -- カテゴリ未設定(CategoryId が NULL)の商品は LEFT JOIN + COALESCE で (未分類) にまとめる
    SET @sql = N'
SELECT *
FROM (
    SELECT COALESCE(cat.CategoryName, N''(未分類)'')      AS カテゴリ,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Orders       AS o    ON o.OrderId      = od.OrderId
    JOIN   dbo.Products     AS p    ON p.ProductId    = od.ProductId
    LEFT   JOIN dbo.Categories AS cat ON cat.CategoryId = p.CategoryId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY カテゴリ;';

    IF @Debug = 1
    BEGIN
        PRINT @sql;       -- ★PRINT は 4000 文字で切れる。長くなるなら SELECT @sql を使う
        RETURN;
    END;

    EXEC sys.sp_executesql @sql;
END;
GO

-- 動作確認
EXEC dbo.usp_SalesPivotByCategory @Debug = 1;   -- 生成SQLだけ表示
EXEC dbo.usp_SalesPivotByCategory;              -- 実際にクロス集計を出力
GO

-- ★後片付け(サンプルDBにオブジェクトを残さない)
DROP PROCEDURE IF EXISTS dbo.usp_SalesPivotByCategory;
GO


-- Q12. スコープの実験 — 動的SQLの中と外は「別の世界」
CREATE TABLE #Scope (Id INT, Memo NVARCHAR(50));
INSERT INTO #Scope VALUES (1, N'呼び出し元で作成');

DECLARE @v INT = 99;

-- (a) 呼び出し元の一時テーブル #Scope は「見える」
--     → 1行(1, 呼び出し元で作成)が返る。#temp はセッション単位なのでバッチをまたいで共有される
EXEC sys.sp_executesql N'SELECT * FROM #Scope;';

-- (b) 呼び出し元のローカル変数 @v は「見えない」
--     → コメントを外すと Msg 137「スカラー変数 "@v" を宣言してください。」
--       動的SQLは別バッチとして実行されるため、外側の DECLARE は届かない
-- EXEC sys.sp_executesql N'SELECT @v;';

-- (c) 値を渡したいなら「パラメータ」で明示的に渡す(これが正解)
EXEC sys.sp_executesql N'SELECT @v AS 受け取った値;', N'@v INT', @v = @v;

-- (d) 動的SQLの「中で」作った一時テーブルは、動的SQLが終わると消える
EXEC sys.sp_executesql N'CREATE TABLE #Inner (X INT); INSERT INTO #Inner VALUES (1);';
--     → コメントを外すと「オブジェクト名 '#Inner' が無効です」
--       #Inner は動的SQLのスコープで作られ、その終了とともに破棄されるため外からは見えない
-- SELECT * FROM #Inner;

-- (e) 呼び出し元で作っておいた #Scope への INSERT は、呼び出し元に反映される
--     → 動的SQLの結果セットを呼び出し元へ渡す定石がこれ
--       (スカラー値なら OUTPUT パラメータ、行セットなら呼び出し元の #temp 経由)
--     ★文字列リテラルの中のリテラルはシングルクォートを二重化する: N''...''
EXEC sys.sp_executesql N'INSERT INTO #Scope VALUES (2, N''動的SQLから追加'');';
SELECT * FROM #Scope;    -- 2行になる

-- 後片付け
DROP TABLE #Scope;
GO


-- Q13. 動的SQLでの UPDATE。値は必ずパラメータ、全体を BEGIN TRAN ... ROLLBACK で囲む
BEGIN TRAN;

DECLARE @ProductId INT           = 2;      -- ワイヤレスマウス
DECLARE @Rate      DECIMAL(5,2)  = 0.90;   -- 10% 値下げ
DECLARE @sql       NVARCHAR(MAX);

SET @sql = N'
UPDATE dbo.Products
SET    UnitPrice = UnitPrice * @Rate
WHERE  ProductId = @ProductId;';

PRINT @sql;                                -- ★実行前に生成SQLを確認

EXEC sys.sp_executesql @sql,
     N'@ProductId INT, @Rate DECIMAL(5,2)',
     @ProductId = @ProductId, @Rate = @Rate;

SELECT ProductId, ProductName, UnitPrice   -- 2800 → 2520 になっていることを確認
FROM   dbo.Products
WHERE  ProductId = @ProductId;

ROLLBACK;   -- ★変更をなかったことにする(COMMIT は絶対にしない)
GO

-- 元に戻っていることの確認(2800 のまま)
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
WHERE  ProductId = 2;
GO
