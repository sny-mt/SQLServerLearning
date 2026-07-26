# 16 ストアドプロシージャとユーザー定義関数

> **このトピックのゴール**: 繰り返し使う処理を **ストアドプロシージャ** として
> データベース側に置き、パラメータ・`OUTPUT`・エラー処理まで含めて安全に書けるようになる。
> あわせて **ユーザー定義関数(UDF)** の3種類を区別し、
> **インラインテーブル値関数(iTVF)を第一選択にする** 判断ができるようになる。
>
> **前提**: [15 一時テーブルとテーブル変数](15_temp_tables.md) までを済ませ、
> [13 データ操作 (INSERT/UPDATE/DELETE/MERGE)](13_dml.md) の
> トランザクションと `TRY...CATCH` の基礎を理解していること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **この章は「オブジェクトを作る」章です**
> `CREATE PROCEDURE` / `CREATE FUNCTION` は、実行するとデータベースに **オブジェクトが残ります**。
> 学習用の `SalesLearning` を散らかさないため、本章の例・演習・解答は
> **最後に必ず `DROP PROCEDURE IF EXISTS` / `DROP FUNCTION IF EXISTS` で後片付け**してください。
> また、データを書き換える例は 13 章と同じく **`BEGIN TRAN ... ROLLBACK` で囲みます**。

---

## 1. なぜプロシージャ・関数を使うのか

同じクエリをアプリケーションのあちこちにコピーして貼ると、
仕様変更のたびに全箇所を直す羽目になります。データベース側に **名前を付けて置いておく**と:

- **再利用できる**: 呼び出し側は名前とパラメータだけを知っていればよい。
- **実行プランが再利用される**: 毎回コンパイルし直さなくてよい(第9節)。
- **権限を絞れる**: テーブルへの直接権限を与えず、プロシージャの実行権限だけ渡せる。
- **ネットワーク往復が減る**: 「10 本の SQL を投げる」→「1 回呼ぶ」。

一方で、**ロジックを DB に埋めすぎると保守しづらくなる**という副作用もあります。
「データに近い処理」だけを置く、という線引きを意識しましょう。

## 2. もっとも基本の CREATE PROCEDURE

```sql
CREATE PROCEDURE dbo.usp_GetAllProducts
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProductId, p.ProductName, p.UnitPrice
    FROM   dbo.Products AS p
    ORDER  BY p.UnitPrice DESC;
END;
GO

EXEC dbo.usp_GetAllProducts;
```

- `CREATE PROCEDURE`(略記 `CREATE PROC`)は **バッチの先頭でなければならない**ため、
  直前の文との間に **`GO`** を入れます。定義の終わりにも `GO` を打って区切ります。
- 本体は `AS` のあとに書きます。`BEGIN ... END` は必須ではありませんが、
  **範囲がはっきりする**ので常に付けるのが定石です。
- 呼び出しは `EXEC`(= `EXECUTE`)。

> ⚠️ **名前の先頭に `sp_` を付けない**
> `sp_` で始まる名前は SQL Server が **まず `master` データベースを探しに行く**ため、
> 無駄なコストとシステムプロシージャとの名前衝突のリスクがあります。
> 本プロジェクトでは **`usp_`(user stored procedure)** を接頭辞に使います。
> 関数は `fn_` を使います。

## 3. `SET NOCOUNT ON` を先頭に書く理由

プロシージャの1行目に `SET NOCOUNT ON;` を書くのは、単なる作法ではありません。

SQL Server は文を実行するたびに「`(3 行処理されました)`」という **件数メッセージ
(DONE_IN_PROC)** をクライアントへ返します。`SET NOCOUNT ON` はこれを抑制します。

- **ネットワーク往復が減る**。ループの中で何千回も文を実行するプロシージャでは、
  この 1 行だけで体感できるほど速くなることがあります。
- **クライアントライブラリの誤動作を防ぐ**。ADO.NET / JDBC などは件数メッセージを
  「結果セットの区切り」と解釈することがあり、`SET NOCOUNT OFF` のままだと
  アプリ側で「余計な結果セット」を拾ってしまう事故が起きます。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_NoCountDemo
AS
BEGIN
    SET NOCOUNT ON;      -- ← これが無いと下の各文ごとに件数メッセージが出る

    SELECT COUNT(*) AS 商品数 FROM dbo.Products;
    SELECT COUNT(*) AS 顧客数 FROM dbo.Customers;
END;
GO

EXEC dbo.usp_NoCountDemo;
```

> ⚠️ `SET NOCOUNT ON` は **メッセージを止めるだけ**で、`@@ROWCOUNT` の値には影響しません。
> プロシージャ内で「何行更新したか」を判定する処理はそのまま動きます。

## 4. パラメータ(複数・既定値)と EXEC の呼び出し方

パラメータはプロシージャ名の後ろにカンマ区切りで並べ、`= 値` で **既定値**を与えられます。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetProducts
    @CategoryId          INT           = NULL,      -- NULL = 全カテゴリ
    @MaxUnitPrice        DECIMAL(18,2) = 999999,
    @IncludeDiscontinued BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProductId, p.ProductName, p.CategoryId, p.UnitPrice, p.Discontinued
    FROM   dbo.Products AS p
    WHERE  (@CategoryId IS NULL OR p.CategoryId = @CategoryId)
      AND  p.UnitPrice <= @MaxUnitPrice
      AND  (@IncludeDiscontinued = 1 OR p.Discontinued = 0)
    ORDER  BY p.UnitPrice DESC;
END;
GO
```

### 位置指定と名前付き

```sql
-- ① 位置指定: 定義順に値を並べる
EXEC dbo.usp_GetProducts 1, 50000, 0;

-- ② 名前付き: @パラメータ名 = 値。順序は自由
EXEC dbo.usp_GetProducts @MaxUnitPrice = 50000, @CategoryId = 1;

-- ③ 既定値を使う(指定しなかったものは既定値になる)
EXEC dbo.usp_GetProducts @CategoryId = 3;

-- ④ 位置指定で途中だけ既定値にしたいときは DEFAULT キーワード
EXEC dbo.usp_GetProducts 1, DEFAULT, 1;
```

- **実務では ② の名前付きを使う**のが鉄則です。位置指定は、
  あとからパラメータが増減したときに **静かに壊れます**。
- 位置指定では **途中を飛ばせません**(`DEFAULT` を明示すれば飛ばせる)。
- 名前付きと位置指定を混ぜると、名前付きが出てきた **以降はすべて名前付き**にする必要があります。

> ⚠️ `@CategoryId IS NULL OR p.CategoryId = @CategoryId` のような
> 「オプション条件」は便利ですが、**1つのプランを全パターンで使い回してしまう**
> ため性能が不安定になりがちです(いわゆるキャッチオールクエリ)。
> 対策は第9節と [18 インデックスと実行プラン](18_indexes_execution_plans.md)、
> および [20 動的SQL](20_dynamic_sql.md) で扱います。

## 5. OUTPUT パラメータ — 値を呼び出し元に返す

`OUTPUT` を付けたパラメータは、プロシージャ内で代入した値が **呼び出し元の変数に返り**ます。
「結果セットではなく、スカラー値をいくつか受け取りたい」ときに使います。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetCustomerSummary
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

-- 呼び出し側: 変数を宣言し、EXEC でも OUTPUT を付けるのがポイント
DECLARE @cnt INT, @amt DECIMAL(18,2);

EXEC dbo.usp_GetCustomerSummary
        @CustomerId  = 1,
        @OrderCount  = @cnt OUTPUT,
        @TotalAmount = @amt OUTPUT;

SELECT @cnt AS 注文件数, @amt AS 売上合計;
```

- **`EXEC` 側にも `OUTPUT` を書き忘れない**。書き忘れると値が返らず、変数は `NULL` のままです
  (エラーにならないので気づきにくい典型的なバグ)。
- `OUTPUT` パラメータは **入力としても使えます**(渡した値が初期値になる)。

## 6. RETURN — 戻り値は「状態コード」であって結果ではない

プロシージャは `RETURN 整数` で **`int` の値を1つだけ**返せます。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_TryGetCustomer
    @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = @CustomerId)
        RETURN 1;                 -- 1 = 見つからなかった

    SELECT CustomerId, CustomerName, City, Region
    FROM   dbo.Customers
    WHERE  CustomerId = @CustomerId;

    RETURN 0;                     -- 0 = 正常終了
END;
GO

DECLARE @rc INT;
EXEC @rc = dbo.usp_TryGetCustomer @CustomerId = 99;   -- 存在しない顧客
SELECT @rc AS 戻り値;                                  -- → 1
```

> ⚠️ **`RETURN` は「処理結果を返す手段」ではありません。**
> 返せるのは **`int` 1個だけ**で、`NULL` も返せません(`RETURN NULL` は 0 になります)。
> 用途は **成功/失敗などの状態コード**に限定し、
> **データを返すなら結果セット(`SELECT`)か `OUTPUT` パラメータ**を使ってください。
> 「金額を `RETURN` で返そうとしてハマる」のは初学者の定番です。

- `RETURN` はその時点で **プロシージャを即座に抜けます**(ガード節として便利)。
- 明示しなければ、正常終了時の戻り値は `0` です。

## 7. ALTER / CREATE OR ALTER / DROP IF EXISTS

| やりたいこと | 書き方 |
|---|---|
| 新規作成(既にあるとエラー) | `CREATE PROCEDURE dbo.usp_X ...` |
| 既存の定義を差し替え(無いとエラー) | `ALTER PROCEDURE dbo.usp_X ...` |
| **無ければ作る・あれば差し替え** | `CREATE OR ALTER PROCEDURE dbo.usp_X ...` |
| 削除(無くてもエラーにしない) | `DROP PROCEDURE IF EXISTS dbo.usp_X;` |

```sql
-- SQL Server 2016 SP1 以降: これ1本で「新規作成」と「変更」の両方を兼ねる
CREATE OR ALTER PROCEDURE dbo.usp_GetAllProducts
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.ProductId, p.ProductName, p.UnitPrice, p.Discontinued
    FROM   dbo.Products AS p
    ORDER  BY p.ProductName;
END;
GO
```

- **`CREATE OR ALTER` は SQL Server 2016 SP1 以降**で使えます。デプロイスクリプトを
  「何度流しても同じ結果になる(冪等)」形にできるため、実務での第一選択です。
- `DROP` して `CREATE` し直すと **付与済みの権限が消えます**。`ALTER` / `CREATE OR ALTER` なら権限は保持されます。
- **`DROP ... IF EXISTS` は SQL Server 2016 以降**。それ以前は
  `IF OBJECT_ID('dbo.usp_X', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_X;` と書きます
  (第2引数は プロシージャ `'P'`、スカラー関数 `'FN'`、iTVF `'IF'`、MSTVF `'TF'`)。

```sql
-- 後片付け(まとめて書ける)
DROP PROCEDURE IF EXISTS dbo.usp_NoCountDemo;
DROP PROCEDURE IF EXISTS dbo.usp_TryGetCustomer;
GO
```

## 8. TRY...CATCH とトランザクション、THROW による再送出

13 章で学んだ `TRY...CATCH` は、プロシージャの中でこそ本領を発揮します。
**「トランザクションを開けたら、必ず閉じる」** を型として覚えましょう。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_UpdateShipDate
    @OrderId  INT,
    @ShipDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;            -- エラー時にトランザクションを確実に異常終了扱いにする

    BEGIN TRY
        -- ① 入力チェック(自前のエラーを投げる)
        IF NOT EXISTS (SELECT 1 FROM dbo.Orders WHERE OrderId = @OrderId)
            THROW 50001, N'指定された注文が存在しません。', 1;

        IF @ShipDate < (SELECT OrderDate FROM dbo.Orders WHERE OrderId = @OrderId)
            THROW 50002, N'出荷日を注文日より前にすることはできません。', 1;

        -- ② 実際の更新
        BEGIN TRAN;
            UPDATE dbo.Orders
            SET    ShipDate = @ShipDate
            WHERE  OrderId  = @OrderId;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;   -- 開いていたら必ず戻す
        THROW;                          -- 元のエラーをそのまま呼び出し元へ再送出
    END CATCH;
END;
GO
```

呼び出し(サンプルDBを汚さないよう、**外側を `BEGIN TRAN ... ROLLBACK` で囲みます**)。

```sql
BEGIN TRAN;
    EXEC dbo.usp_UpdateShipDate @OrderId = 1006, @ShipDate = '2023-06-01';
    SELECT OrderId, OrderDate, ShipDate FROM dbo.Orders WHERE OrderId = 1006;
ROLLBACK;

-- 異常系: 存在しない注文 → CATCH で ROLLBACK され、THROW でエラーが伝わる
BEGIN TRY
    EXEC dbo.usp_UpdateShipDate @OrderId = 9999, @ShipDate = '2024-01-01';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()  AS エラー番号,
           ERROR_MESSAGE() AS エラーメッセージ;
END CATCH;
```

### `THROW` と `RAISERROR` の違い

- **`THROW;`(引数なし)** は `CATCH` ブロック専用で、**捕まえたエラーをそのまま再送出**します。
  エラー番号・メッセージ・重大度が保たれるため、**再送出はこれ一択**です。
- **`THROW 番号, メッセージ, 状態;`** で独自エラーを投げられます。番号は **50000 以上**、
  メッセージは `nvarchar(2048)`。**直前の文はセミコロンで終わっている必要があります**。
- `RAISERROR` は書式指定(`%d` など)が使えますが、重大度を自分で決める必要があり、
  再送出では元のエラー番号を保てません。**新規コードでは `THROW` を推奨**します。

> ⚠️ **入れ子のトランザクションに注意**
> 上の呼び出し例では、外側で `BEGIN TRAN` した状態でプロシージャ内の `BEGIN TRAN` が走るため
> `@@TRANCOUNT` は 2 になります。内側の `COMMIT` は **カウントを1減らすだけ**で確定はせず、
> 最終的に外側の `ROLLBACK` ですべてが取り消されます。
> 逆に、**内側で `ROLLBACK` すると入れ子の深さに関係なく全部が巻き戻る**点も重要です。
> 詳しくは [19 トランザクションと分離レベル](19_transactions_isolation.md) で扱います。

## 9. 実務パターン — 一時テーブルで段階的に処理する

複雑な集計は **1本の巨大クエリにせず、一時テーブルに中間結果を置いて段階的に**
組み立てると、読みやすく・デバッグしやすく・プランも安定します
([15 一時テーブルとテーブル変数](15_temp_tables.md) の応用)。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_BuildSalesReport
    @FromDate DATE,
    @ToDate   DATE
AS
BEGIN
    SET NOCOUNT ON;

    ------------------------------------------------------------
    -- ① 対象期間の注文だけを絞り込む
    ------------------------------------------------------------
    CREATE TABLE #TargetOrders (
        OrderId    INT  NOT NULL PRIMARY KEY,
        CustomerId INT  NOT NULL,
        OrderDate  DATE NOT NULL
    );

    INSERT INTO #TargetOrders (OrderId, CustomerId, OrderDate)
    SELECT o.OrderId, o.CustomerId, o.OrderDate
    FROM   dbo.Orders AS o
    WHERE  o.OrderDate >= @FromDate
      AND  o.OrderDate <  DATEADD(DAY, 1, @ToDate);

    ------------------------------------------------------------
    -- ② 注文ごとの金額を集計(明細金額 = Quantity * UnitPrice * (1 - Discount))
    ------------------------------------------------------------
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

    ------------------------------------------------------------
    -- ③ 顧客単位にまとめて返す
    ------------------------------------------------------------
    SELECT c.CustomerId,
           c.CustomerName,
           c.Region,
           COUNT(*)      AS 注文件数,
           SUM(a.Amount) AS 売上合計
    FROM   #TargetOrders AS t
    JOIN   #OrderAmount  AS a ON a.OrderId = t.OrderId
    JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
    GROUP  BY c.CustomerId, c.CustomerName, c.Region
    ORDER  BY 売上合計 DESC;
END;
GO

EXEC dbo.usp_BuildSalesReport @FromDate = '2023-01-01', @ToDate = '2023-12-31';
```

- プロシージャ内で作った **`#一時テーブル` はプロシージャ終了時に自動で破棄**されます
  (明示的な `DROP TABLE` は不要。ただし書いても害はありません)。
- 段階ごとに `SELECT * FROM #TargetOrders;` を挟めば **途中結果を目視デバッグ**できます。
- 一時テーブルには **統計情報が作られる**ため、テーブル変数より
  正確な行数見積もりが得られ、後続の結合プランが安定します。

## 10. 実行プランの再利用とパラメータスニッフィング(概説)

プロシージャを初めて実行すると、SQL Server はその **実行プランをコンパイルしてキャッシュ**し、
2回目以降は再利用します。これがプロシージャの性能上の大きな利点です。

問題は、コンパイル時に SQL Server が **「そのとき渡された実際のパラメータ値」を覗き見して**
最適なプランを作る点です。これを **パラメータスニッフィング (parameter sniffing)** と呼びます。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetCustomerOrders
    @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT o.OrderId, o.OrderDate, o.ShipDate,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 注文金額
    FROM   dbo.Orders            AS o
    LEFT   JOIN dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    WHERE  o.CustomerId = @CustomerId
    GROUP  BY o.OrderId, o.OrderDate, o.ShipDate
    ORDER  BY o.OrderDate;
END;
GO

-- 「ほとんど行が返らない顧客」で最初に実行されると、
-- 少数行に最適な Nested Loops + Key Lookup のプランがキャッシュされる。
EXEC dbo.usp_GetCustomerOrders @CustomerId = 11;   -- 注文が無い顧客

-- その後、大量に返る顧客で呼んでも同じプランを使い回すため、
-- 本来 Hash Join + スキャンが速い場面でも遅いままになることがある。
EXEC dbo.usp_GetCustomerOrders @CustomerId = 1;    -- 注文が多い顧客
```

> 上のサンプルDBは 20 行しかないため体感差は出ませんが、
> 100 万行の `dbo.OrdersBig` のような偏りのあるテーブルでは、
> **同じプロシージャが引数次第で数十倍遅くなる**ことが実際に起きます。

- データの分布に **偏り**があるほど問題が起きやすい(例: `Status` が 95% `N'完了'` の列)。
- 症状は「**昨日まで速かったクエリが今日から急に遅い**」という形で現れます。
  統計情報の更新やサーバ再起動でプランが捨てられ、たまたま別の値で再コンパイルされたためです。

代表的な対処:

| 手段 | 意味 |
|---|---|
| `OPTION (RECOMPILE)` | その文だけ毎回コンパイル。常に最適だがコンパイル費用がかかる |
| `OPTION (OPTIMIZE FOR (@p = 値))` | 特定の値を前提にプランを固定する |
| `OPTION (OPTIMIZE FOR UNKNOWN)` | 平均的な分布を前提にする(極端に外さない代わりに最速でもない) |
| `WITH RECOMPILE`(プロシージャ定義) | 実行のたびにプロシージャ全体を再コンパイル |

> ⚠️ まずは **「そもそも適切なインデックスがあるか」** を疑うのが先です。
> 実行プランの読み方・インデックス設計・スニッフィングの詳しい対処は
> [18 インデックスと実行プラン](18_indexes_execution_plans.md) で掘り下げます。

---

# ユーザー定義関数 (UDF)

UDF には **3種類** あり、性能特性がまったく違います。**種類の区別がこの章の山場**です。

| 種類 | 定義の形 | 返すもの | 性能 |
|---|---|---|---|
| スカラー関数 | `RETURNS 型 AS BEGIN ... RETURN 値 END` | 単一の値 | **遅い**(2019 で改善) |
| **インライン TVF (iTVF)** | `RETURNS TABLE AS RETURN (SELECT ...)` | 結果セット | **速い(推奨)** |
| 多ステートメント TVF (MSTVF) | `RETURNS @t TABLE (...) AS BEGIN ... END` | 結果セット | 遅くなりやすい |

## 11. スカラー関数 — なぜ遅いのか

```sql
CREATE OR ALTER FUNCTION dbo.fn_LineAmount
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

SELECT od.OrderId,
       od.ProductId,
       dbo.fn_LineAmount(od.Quantity, od.UnitPrice, od.Discount) AS 明細金額
FROM   dbo.OrderDetails AS od;
```

読みやすさは魅力ですが、従来のスカラー UDF には次の欠点があります。

1. **行ごとに1回ずつ呼ばれる**。100 万行なら 100 万回の関数呼び出しで、
   そのたびに小さなコンテキスト切り替えが発生する(実質 RBAR = Row By Agonizing Row)。
2. **実行プランに現れない**。関数内部のコストがプランに表示されないため、
   「プランを見ても原因が分からない遅いクエリ」になる。
3. **クエリ全体の並列実行を阻害する**。スカラー UDF を含むクエリは
   **並列プランが選ばれなくなる**(シリアル実行に落ちる)ことがある。
4. **`WHERE` に書くと SARGable でなくなる**。
   `WHERE dbo.fn_Xxx(列) = 値` は **インデックスが使えず全件スキャン**になる。

> ⚠️ **SQL Server 2019 の「スカラー UDF インライン化」**
> 互換性レベル 150 以上では、条件を満たすスカラー UDF が
> **オプティマイザによって式に展開(インライン化)** され、上記の欠点の多くが解消されます。
> ただし **すべての UDF がインライン化されるわけではありません**
> (時刻依存の関数を使う、テーブル変数を使う、再帰する、など多数の除外条件がある)。
> インライン化されたかは `sys.sql_modules` の `is_inlineable` 列で確認でき、
> `WITH INLINE = OFF` で個別に無効化もできます。
> **2016/2017 で運用しているなら、依然としてスカラー UDF は避けるのが安全**です。

### 置き換えの定石

スカラー UDF は、多くの場合 **1列だけ返す iTVF + `CROSS APPLY`** に書き換えられます。

```sql
CREATE OR ALTER FUNCTION dbo.fn_LineAmountTVF
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

SELECT od.OrderId, od.ProductId, a.明細金額
FROM   dbo.OrderDetails AS od
CROSS  APPLY dbo.fn_LineAmountTVF(od.Quantity, od.UnitPrice, od.Discount) AS a;
```

こちらは **オプティマイザが式に展開する**ため、直接式を書いたのと同じプランになります。

## 12. インラインテーブル値関数 (iTVF) — 推奨形

**`RETURNS TABLE AS RETURN (SELECT ...)`** の形。本体は **`SELECT` 1文だけ**で、
`BEGIN ... END` も変数宣言も書けません。その制約こそが速さの理由です。

```sql
CREATE OR ALTER FUNCTION dbo.fn_TopOrderLines
(
    @OrderId INT,
    @TopN    INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (@TopN)
           od.ProductId,
           p.ProductName,
           od.Quantity,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 明細金額
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
    WHERE  od.OrderId = @OrderId
    ORDER  BY 明細金額 DESC
);
GO

-- ふつうのテーブルのように FROM に書ける
SELECT * FROM dbo.fn_TopOrderLines(1001, 3);
```

- **「パラメータ付きビュー」** と考えると分かりやすいです。
- 呼び出されると **本体がクエリ本体に展開(インライン展開)** され、
  オプティマイザは全体をまとめて1つのプランに最適化します。
  → **述語の押し下げ・結合順の入れ替え・並列化がすべて効きます**。
- 統計情報も元テーブルのものが使われるため、**行数見積もりが正確**です。

> ⚠️ iTVF の本体に `BEGIN`/`END`、`DECLARE`、複数の文は書けません。
> 書きたくなったら、まず **`CROSS APPLY` や CTE で1文に収まらないか**を考えてください。
> それでも無理なら MSTVF ですが、次節の代償を理解した上で選びます。

## 13. iTVF × CROSS APPLY — 14章の回収

iTVF が真価を発揮するのは **`CROSS APPLY` / `OUTER APPLY`** と組み合わせたときです
([14 APPLY](14_apply.md))。「行ごとにパラメータを変えて関数を適用する」ことができます。

```sql
-- 各注文について「金額が大きい上位2明細」を横に並べる
SELECT o.OrderId,
       o.OrderDate,
       c.CustomerName,
       t.ProductName,
       t.Quantity,
       t.明細金額
FROM   dbo.Orders    AS o
JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId
CROSS  APPLY dbo.fn_TopOrderLines(o.OrderId, 2) AS t   -- ← o.OrderId を1行ずつ渡す
ORDER  BY o.OrderId, t.明細金額 DESC;
```

- `CROSS APPLY` は **右辺が0行なら左の行も消えます**。
  明細が無い注文も残したいなら `OUTER APPLY` に変えます。

```sql
-- 明細が無い注文も残す(該当列は NULL になる)
SELECT o.OrderId, o.OrderDate, t.ProductName, t.明細金額
FROM   dbo.Orders AS o
OUTER  APPLY dbo.fn_TopOrderLines(o.OrderId, 1) AS t
ORDER  BY o.OrderId;
```

もうひとつ、**顧客ごとの直近注文**という頻出パターン:

```sql
CREATE OR ALTER FUNCTION dbo.fn_LatestOrders
(
    @CustomerId INT,
    @TopN       INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (@TopN)
           o.OrderId, o.OrderDate, o.ShipDate
    FROM   dbo.Orders AS o
    WHERE  o.CustomerId = @CustomerId
    ORDER  BY o.OrderDate DESC, o.OrderId DESC
);
GO

SELECT c.CustomerId, c.CustomerName, c.Region,
       l.OrderId, l.OrderDate, l.ShipDate
FROM   dbo.Customers AS c
OUTER  APPLY dbo.fn_LatestOrders(c.CustomerId, 2) AS l
ORDER  BY c.CustomerId, l.OrderDate DESC;
```

**同じロジックを何箇所からも使う**なら、CTE やサブクエリをコピーするより
iTVF に切り出すほうが保守しやすい、というのが実務上の勘所です。

## 14. 多ステートメントテーブル値関数 (MSTVF) の罠

`RETURNS @変数 TABLE (...)` の形。中で複数の文を書け、`INSERT` で結果を積み上げます。

```sql
CREATE OR ALTER FUNCTION dbo.fn_RegionSalesMS (@Region NVARCHAR(50))
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
    FROM   dbo.Customers         AS c
    JOIN   dbo.Orders            AS o  ON o.CustomerId = c.CustomerId
    JOIN   dbo.OrderDetails      AS od ON od.OrderId   = o.OrderId
    WHERE  c.Region = @Region
    GROUP  BY c.CustomerId, c.CustomerName;

    RETURN;         -- 引数なしの RETURN で @Result の中身を返す
END;
GO

SELECT * FROM dbo.fn_RegionSalesMS(N'関東');
```

書けることは多いのですが、**代償があります**。

- **本体がクエリに展開されない**(ブラックボックス)。
  オプティマイザは中身を見られず、述語の押し下げも結合順の最適化も効きません。
- **推定行数が固定される**。MSTVF の戻り値には統計情報が無いため、
  オプティマイザは **常に固定値(SQL Server 2014 以降の新 CE で 100 行、旧 CE では 1 行)**
  と見積もります。実際が 100 万行でも「100 行」として計画されるため、
  **Nested Loops を選んでしまい壊滅的に遅くなる**ことがあります。
- 戻り値のテーブル変数への `INSERT` そのものにもコストがかかります。

> ⚠️ **SQL Server 2017 の「インターリーブ実行 (Interleaved Execution)」**
> 互換性レベル 140 以上では、MSTVF を **いったん実行して実際の行数を得てから**
> 残りのプランを最適化する仕組みが入り、見積もり誤りはかなり緩和されました。
> それでも **本体が展開されないという本質は変わりません**。
> **iTVF で書けるなら必ず iTVF にする** という原則は今も有効です。

同じ集計は iTVF で1文にまとめられます(こちらが正解形):

```sql
CREATE OR ALTER FUNCTION dbo.fn_RegionSales (@Region NVARCHAR(50))
RETURNS TABLE
AS
RETURN
(
    SELECT c.CustomerId,
           c.CustomerName,
           COUNT(DISTINCT o.OrderId)                                AS 注文件数,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))       AS 売上合計
    FROM   dbo.Customers    AS c
    JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
    WHERE  c.Region = @Region
    GROUP  BY c.CustomerId, c.CustomerName
);
GO

SELECT * FROM dbo.fn_RegionSales(N'関東') ORDER BY 売上合計 DESC;
```

## 15. プロシージャと関数の使い分け

| 観点 | ストアドプロシージャ | ユーザー定義関数 |
|---|---|---|
| 呼び出し方 | `EXEC dbo.usp_X ...` | `SELECT ... FROM dbo.fn_X(...)` / 式の中 |
| **`SELECT` の中で使えるか** | ✗ 使えない | ○ 使える(これが最大の違い) |
| **`FROM` / `JOIN` に書けるか** | ✗ 書けない | ○ TVF なら書ける |
| 結果セットを返す | ○ 複数返せる | TVF が1つ返す |
| **データ変更 (INSERT/UPDATE/DELETE)** | ○ できる | ✗ **できない**(副作用は禁止) |
| トランザクション制御 | ○ `BEGIN TRAN`/`COMMIT` 可 | ✗ 不可 |
| `TRY...CATCH` | ○ 使える | ✗ 使えない(スカラー UDF も不可) |
| 一時テーブル `#T` | ○ 使える | ✗ 使えない(テーブル変数は可) |
| 動的SQL (`sp_executesql`) | ○ 使える | ✗ 使えない |
| `GETDATE()` など非決定的関数 | ○ 使える | スカラー/TVF ともに使えるが、決定性が失われる |
| 出力パラメータ | ○ `OUTPUT` | ✗(戻り値のみ) |

判断のフローチャート:

1. **データを変更する / トランザクションやエラー処理が要る** → **プロシージャ**。
2. **クエリの `FROM` に差し込んで使いたい、他のクエリと組み合わせたい** → **iTVF**。
3. **単一の値を式の中で使いたい** → まず「直接式を書けないか」を検討。
   どうしても共通化したいならスカラー UDF(2019 未満なら iTVF + `APPLY` を優先)。
4. **iTVF で書けない複雑な手続きが必要** → プロシージャ + 一時テーブルを検討。
   MSTVF は最後の手段。

## 16. 後片付け

この章で作ったオブジェクトは、必ず削除してから次に進みましょう。

```sql
DROP PROCEDURE IF EXISTS dbo.usp_GetAllProducts;
DROP PROCEDURE IF EXISTS dbo.usp_NoCountDemo;
DROP PROCEDURE IF EXISTS dbo.usp_GetProducts;
DROP PROCEDURE IF EXISTS dbo.usp_GetCustomerSummary;
DROP PROCEDURE IF EXISTS dbo.usp_TryGetCustomer;
DROP PROCEDURE IF EXISTS dbo.usp_UpdateShipDate;
DROP PROCEDURE IF EXISTS dbo.usp_BuildSalesReport;
DROP PROCEDURE IF EXISTS dbo.usp_GetCustomerOrders;
GO

DROP FUNCTION IF EXISTS dbo.fn_LineAmount;
DROP FUNCTION IF EXISTS dbo.fn_LineAmountTVF;
DROP FUNCTION IF EXISTS dbo.fn_TopOrderLines;
DROP FUNCTION IF EXISTS dbo.fn_LatestOrders;
DROP FUNCTION IF EXISTS dbo.fn_RegionSalesMS;
DROP FUNCTION IF EXISTS dbo.fn_RegionSales;
GO
```

作成済みのオブジェクトは次のクエリで確認できます。

```sql
SELECT o.name        AS オブジェクト名,
       o.type_desc   AS 種別,
       o.create_date AS 作成日時
FROM   sys.objects AS o
WHERE  o.type IN ('P', 'FN', 'IF', 'TF')       -- P=プロシージャ, FN=スカラー, IF=iTVF, TF=MSTVF
  AND  o.is_ms_shipped = 0
ORDER  BY o.type_desc, o.name;
```

## よくあるつまずき

- **`CREATE PROCEDURE` でエラー「バッチ内の最初のステートメントでなければなりません」**
  → 直前に `GO` を入れて別バッチにする。
- **`SET NOCOUNT ON` を書き忘れ、アプリ側で余計な結果を拾う** → 定型として1行目に必ず書く。
- **`OUTPUT` を `EXEC` 側で書き忘れて変数が `NULL`** → 定義側と呼び出し側の**両方**に `OUTPUT` が要る。
- **`RETURN` で金額や文字列を返そうとする** → `RETURN` は `int` の状態コード専用。
  データは結果セットか `OUTPUT` パラメータで返す。
- **`CATCH` で `ROLLBACK` し忘れてトランザクションが開きっぱなし**
  → `IF @@TRANCOUNT > 0 ROLLBACK;` を定型にする。
- **`THROW` の直前の文にセミコロンが無くて構文エラー** → `THROW` の前は必ず `;` で終える。
- **`WHERE dbo.fn_Xxx(列) = 値` が異常に遅い** → 関数で包むとインデックスが使えない(非 SARGable)。
- **関数の中で `INSERT`/`UPDATE` しようとしてエラー** → UDF は副作用を持てない。プロシージャにする。
- **iTVF に `BEGIN ... END` を書いてエラー** → iTVF は `RETURN (SELECT ...)` の1文だけ。
- **MSTVF を大量行に使って急に遅くなる** → 推定行数が固定。iTVF に書き換えられないか検討する。
- **演習後にオブジェクトが残ってDBが散らかる** → `DROP ... IF EXISTS` まで書く癖をつける。

## この章のまとめ

- プロシージャは `CREATE OR ALTER PROCEDURE`(2016 SP1+)で冪等に定義し、
  `DROP PROCEDURE IF EXISTS`(2016+)で片付ける。名前は `sp_` を避け `usp_` を使う。
- **1行目に `SET NOCOUNT ON;`**。件数メッセージを止めて、通信量とクライアント側の事故を減らす。
- パラメータは **名前付き呼び出し**が鉄則。既定値でオプション引数を表現できる。
- 値を返すのは **`OUTPUT` パラメータ**。**`RETURN` は `int` の状態コード専用**で結果を返す手段ではない。
- `TRY...CATCH` + `IF @@TRANCOUNT > 0 ROLLBACK;` + **`THROW;`(引数なしの再送出)** が定型。
- 複雑な集計は **一時テーブルで段階的に**組み立てるとデバッグしやすくプランも安定する。
- プロシージャはプランを再利用する。その裏返しが **パラメータスニッフィング**
  (→ [18 インデックスと実行プラン](18_indexes_execution_plans.md))。
- UDF は3種類。**iTVF (`RETURNS TABLE AS RETURN (SELECT ...)`) が推奨形**で、
  クエリに展開されるため速い。**`CROSS APPLY` との相性が抜群**。
- **スカラー UDF は行ごと実行・並列化阻害で遅い**(2019 のインライン化で改善、ただし条件付き)。
- **MSTVF は推定行数が固定(新CEで100行)** になりプランが崩れやすい。最後の手段。

➡ 演習: [exercises/16_stored_procedures.md](../exercises/16_stored_procedures.md)

**関連**: [14 APPLY](14_apply.md) / [15 一時テーブルとテーブル変数](15_temp_tables.md) /
[17 ユーザー定義型とテーブル値パラメータ (TVP)](17_user_defined_types.md) /
[18 インデックスと実行プラン](18_indexes_execution_plans.md)
