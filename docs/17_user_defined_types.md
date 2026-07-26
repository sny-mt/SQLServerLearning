# 17 ユーザー定義型とテーブル値パラメータ (TVP)

> **このトピックのゴール**: **ユーザー定義テーブル型**を定義し、それを
> **テーブル値パラメータ (TVP)** としてストアドプロシージャに渡して、
> **複数行を1回の呼び出しでまとめて処理**できるようになる。
> あわせて別名データ型 (Alias Data Type) と、TVP を使うときの
> 性能上・運用上の落とし穴を理解する。
>
> **前提**: [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) を済ませ、
> プロシージャの作成・実行とパラメータの渡し方が分かっていること。
> [13 データ操作 (DML)](13_dml.md) の `INSERT` / `MERGE`、
> [15 一時テーブルとテーブル変数](15_temp_tables.md) のテーブル変数も前提にします。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **本章はデータベースにオブジェクトを作ります**
> 型 (`TYPE`) とプロシージャ (`PROCEDURE`) を作成するため、**最後に必ず後片付け**してください。
> しかも **削除には順序があります**(`DROP PROCEDURE` → `DROP TYPE`)。
> 理由は「[8. 型は後から変更できない — DROP の順序](#8-型は後から変更できない--drop-の順序)」で説明します。
> データを書き換える例は 13章と同じく `BEGIN TRAN ... ROLLBACK` で囲みます。

---

## 1. ユーザー定義型には3種類ある

SQL Server の「ユーザー定義型」は、名前は似ていても中身がまったく違う3種類があります。

| 種類 | 作り方 | 実体 | 実務での重要度 |
|---|---|---|---|
| **別名データ型** (Alias Data Type) | `CREATE TYPE 名前 FROM 組み込み型` | 組み込み型に別名を付けただけ | 中(あれば便利) |
| **ユーザー定義テーブル型** | `CREATE TYPE 名前 AS TABLE (...)` | **表**の型。TVP の土台 | ★**最重要** |
| **CLR ユーザー定義型** | .NET アセンブリを登録 | .NET のクラス | 低(ほぼ使わない) |

本章の主役は **2番目のユーザー定義テーブル型 = テーブル値パラメータ (TVP)** です。
「アプリから複数行をまとめてストアドプロシージャに渡す」ための、実務の定番手法です。

---

## 2. 別名データ型 (Alias Data Type)

`NVARCHAR(20)` のような組み込み型に、業務上の意味を持つ **名前を付ける** 機能です。

```sql
-- 電話番号は「NVARCHAR(20) の NOT NULL」と決める
CREATE TYPE dbo.PhoneNumber FROM NVARCHAR(20) NOT NULL;
```

作った型は、**テーブルの列・変数・パラメータ** の型として使えます。

```sql
-- 変数として使う
DECLARE @tel dbo.PhoneNumber = N'03-1234-5678';
SELECT @tel AS 電話番号, DATALENGTH(@tel) AS バイト数;
```

```sql
-- テーブルの列として使う
CREATE TABLE dbo.CustomerPhones
(
    CustomerId INT             NOT NULL PRIMARY KEY,
    Tel        dbo.PhoneNumber          -- NOT NULL は型の定義に含まれている
);
```

### メリット: 定義の一元化

- 「電話番号は必ず `NVARCHAR(20)`」というルールを **1か所に書ける**。
  テーブルごとに `NVARCHAR(15)` / `NVARCHAR(20)` / `VARCHAR(20)` とバラつく事故を防げます。
- 型名そのものがドキュメントになります(`Tel NVARCHAR(20)` より `Tel dbo.PhoneNumber` のほうが意図が伝わる)。

### 実務での注意

> ⚠️ **別名データ型は「後から変えられない」**
> `ALTER TYPE` は存在しません。桁数を `NVARCHAR(20)` → `NVARCHAR(30)` に広げたくなったら、
> **依存しているオブジェクトを全部外してから作り直す** しかありません。
> 「一元化できて便利」の裏返しで、**変更のコストは高い** のです。

依存があると `DROP TYPE` は失敗します。実際に試してみましょう。

```sql
-- ✗ エラー: 型 'PhoneNumber' は オブジェクト 'CustomerPhones' で参照されているため削除できません
DROP TYPE dbo.PhoneNumber;
```

正しい順序は「**使っている側を先に消す**」です。

```sql
DROP TABLE IF EXISTS dbo.CustomerPhones;   -- 使っている側が先
DROP TYPE  IF EXISTS dbo.PhoneNumber;      -- 型は後
```

- `DROP TYPE IF EXISTS` / `DROP TABLE IF EXISTS` は **SQL Server 2016 以降** で使えます。

どのオブジェクトがその型を使っているかは、カタログビューで調べられます。

```sql
SELECT OBJECT_SCHEMA_NAME(c.object_id) AS スキーマ,
       OBJECT_NAME(c.object_id)        AS テーブル名,
       c.name                          AS 列名
FROM   sys.columns AS c
JOIN   sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE  t.name = N'PhoneNumber';
```

別名データ型はこのくらいで十分です。ここからが本題です。

---

## 3. ユーザー定義テーブル型を作る

`CREATE TYPE ... AS TABLE (...)` で、**表の形そのもの** を型として定義できます。

```sql
CREATE TYPE dbo.OrderDetailType AS TABLE
(
    ProductId INT            NOT NULL,
    Quantity  INT            NOT NULL,
    UnitPrice DECIMAL(10, 0) NULL,                    -- NULL なら現在の商品単価を採用する約束
    Discount  DECIMAL(4, 2)  NOT NULL DEFAULT (0),    -- 0.00〜1.00
    PRIMARY KEY (ProductId),                          -- 同じ商品が2回来たら弾く
    CHECK (Quantity > 0),
    CHECK (Discount >= 0 AND Discount <= 1)
);
```

ポイント:

- **主キー・UNIQUE・CHECK・DEFAULT・NOT NULL を型定義に書ける**。
  つまり「渡ってくるデータの検品ルール」を型そのものに埋め込めます。
  上の例では、同じ `ProductId` を2行送ってきたアプリはその場でエラーになります。
- `PRIMARY KEY` / `UNIQUE` を付けると内部的にインデックスが作られ、結合が速くなります。
- **SQL Server 2014 以降** は、インラインで非クラスター化インデックスも定義できます。

  ```sql
  CREATE TYPE dbo.OrderDetailType2 AS TABLE
  (
      ProductId INT NOT NULL PRIMARY KEY,
      Quantity  INT NOT NULL,
      INDEX IX_Qty NONCLUSTERED (Quantity)      -- 2014 以降
  );
  ```

> ⚠️ **テーブル型に書けないもの**
> - **外部キー (FOREIGN KEY)** は定義できません。参照整合性はプロシージャ側で確認します。
> - 計算列・`ALTER TABLE` 相当の変更・統計情報の作成もできません。
> - 制約に名前を付けるのは避けましょう(同じ型を同時に複数使うと名前が衝突します)。

---

## 4. テーブル型変数として使う

作った型は、まず **変数** の型として使えます。書き方は普通のテーブル変数と同じです。

```sql
DECLARE @Details AS dbo.OrderDetailType;

INSERT INTO @Details (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 2, 128000, 0.10),      -- ノートPC
       (2, 5,   2800, 0.00),      -- ワイヤレスマウス
       (3, 1,   NULL, 0.05);      -- メカニカルキーボード(単価はサーバー側に任せる)

SELECT p.ProductName                                          AS 商品名,
       d.Quantity                                             AS 数量,
       COALESCE(d.UnitPrice, p.UnitPrice)                     AS 単価,
       d.Discount                                             AS 割引率,
       d.Quantity * COALESCE(d.UnitPrice, p.UnitPrice)
                  * (1 - d.Discount)                          AS 明細金額
FROM   @Details     AS d
JOIN   dbo.Products AS p ON p.ProductId = d.ProductId
ORDER  BY p.ProductName;
```

- `DECLARE @変数名 AS 型名` の形。`AS` は省略できます(`DECLARE @Details dbo.OrderDetailType;`)。
- 変数なので **バッチ(`GO` の区切り)をまたげません**。宣言と使用は同じバッチに書きます。
- `DEFAULT (0)` を定義してあるので、`Discount` を列リストから外せば自動で 0 が入ります。

ここまでは「毎回 `DECLARE @t TABLE (...)` と書くのを型にまとめた」だけの話です。
**本当の価値は次のパラメータ渡しにあります。**

---

## 5. TVP — プロシージャのパラメータとして渡す

ユーザー定義テーブル型をプロシージャ(や関数)のパラメータにしたものが
**テーブル値パラメータ (Table-Valued Parameter, TVP)** です。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_ShowOrderDetails
    @Details dbo.OrderDetailType READONLY      -- ★ READONLY は必須
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProductName AS 商品名,
           d.Quantity    AS 数量
    FROM   @Details     AS d
    JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;
END
GO
```

呼び出し側は、型の変数を作って渡すだけです。

```sql
DECLARE @D AS dbo.OrderDetailType;
INSERT INTO @D (ProductId, Quantity) VALUES (1, 2), (9, 100);

EXEC dbo.usp_ShowOrderDetails @Details = @D;
```

### `READONLY` は必ず付ける

> ⚠️ **TVP のパラメータには `READONLY` が必須です。付け忘れは初学者が必ず1度は踏むエラーです。**
>
> ```sql
> -- ✗ エラー 352: テーブル値パラメーター "@Details" は READONLY と宣言する必要があります。
> CREATE PROCEDURE dbo.usp_Bad (@Details dbo.OrderDetailType) AS ...
> ```

`READONLY` が意味するとおり、**プロシージャの中で TVP を書き換えることはできません**。

```sql
-- ✗ エラー: 読み取り専用のテーブル値パラメーターは変更できません
UPDATE @Details SET Quantity = 0;
INSERT INTO @Details ...;
DELETE FROM @Details ...;
```

読み取り専用なので、次の制約も付いてきます。

- **`OUTPUT` にできません**。TVP で結果を返すことはできず、**入力専用** です。
- プロシージャ内で加工したいときは、**別のテーブル変数か一時テーブルに `SELECT` で写してから** 操作します
  (この「写す」テクニックは 9節の性能対策にもつながります)。

### 呼び出し側での制約

- 渡せるのは **その型の変数だけ** です。テーブル名や `SELECT` の結果を直接は渡せません。
- **`NULL` は渡せません**。引数を省略した場合は「0行のテーブル」として扱われます。
  つまり `IF NOT EXISTS (SELECT 1 FROM @Details)` で「空かどうか」を判定します。
- TVP はユーザー定義**関数**の引数にもできます(こちらも `READONLY`)。
- 動的SQL に渡すときは `sp_executesql` のパラメータとして `READONLY` 付きで宣言します
  ([20 動的SQL](20_dynamic_sql.md))。

---

## 6. 実務パターン — 注文明細を一括登録する

ここが本章の核心です。「アプリの注文画面で入力された **明細 N 行** を、
ヘッダ1行と一緒に **1回の呼び出しで** 登録する」プロシージャを完成させます。

```sql
CREATE OR ALTER PROCEDURE dbo.usp_RegisterOrder
    @CustomerId INT,
    @EmployeeId INT,
    @OrderDate  DATE,
    @Details    dbo.OrderDetailType READONLY,
    @NewOrderId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;          -- エラー時は自動でロールバック

    -- (1) 入力の検証 ------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM @Details)
        THROW 50001, N'注文明細が1行もありません。', 1;

    IF EXISTS (SELECT 1
               FROM   @Details AS d
               WHERE  NOT EXISTS (SELECT 1 FROM dbo.Products AS p
                                  WHERE  p.ProductId = d.ProductId))
        THROW 50002, N'存在しない ProductId が含まれています。', 1;

    IF EXISTS (SELECT 1
               FROM   @Details     AS d
               JOIN   dbo.Products AS p ON p.ProductId = d.ProductId
               WHERE  p.Discontinued = 1)
        THROW 50003, N'廃番商品は注文できません。', 1;

    -- (2) 登録 -------------------------------------------------------
    BEGIN TRAN;

        -- 採番(このサンプルDBの OrderId は IDENTITY ではないので自前で採番する)
        SELECT @NewOrderId = ISNULL(MAX(OrderId), 1000) + 1
        FROM   dbo.Orders WITH (UPDLOCK, HOLDLOCK);

        INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
        VALUES (@NewOrderId, @CustomerId, @EmployeeId, @OrderDate, NULL);

        -- ★ TVP を INSERT ... SELECT で一括投入(ここがループの代わり)
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
```

実行してみましょう。**サンプルDBを壊さないよう `BEGIN TRAN ... ROLLBACK` で囲みます**。

```sql
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

SELECT @Id AS 採番されたOrderId;

SELECT o.OrderId, c.CustomerName, p.ProductName, od.Quantity, od.UnitPrice, od.Discount,
       od.Quantity * od.UnitPrice * (1 - od.Discount) AS 明細金額
FROM   dbo.Orders       AS o
JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
JOIN   dbo.Products     AS p  ON p.ProductId  = od.ProductId
WHERE  o.OrderId = @Id;

ROLLBACK;   -- 追加した注文をなかったことにする
```

> ⚠️ **プロシージャ内の `BEGIN TRAN` と、外側の `BEGIN TRAN` の関係**
> 上のようにトランザクションの中からプロシージャを呼ぶと、内側の `BEGIN TRAN` は
> **入れ子** になります(`@@TRANCOUNT` が 2 になるだけ)。内側の `COMMIT` は
> カウンタを 1 に戻すだけで確定はせず、**外側の `ROLLBACK` ですべてが取り消されます**。
> だから学習中も安全に試せます。詳しくは [19 トランザクションと分離レベル](19_transactions_isolation.md)。

### MERGE と組み合わせる(明細の一括 UPSERT)

「送られてきた明細の内容に注文をそろえる」= **あるものは更新・ないものは追加・
送られてこなかったものは削除**、という処理は `MERGE` と TVP の黄金コンビです。

```sql
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

    WHEN NOT MATCHED BY SOURCE AND tgt.OrderId = @OrderId      -- ★ この絞り込みが命綱
        THEN DELETE

    OUTPUT $action AS 操作, ISNULL(INSERTED.ProductId, DELETED.ProductId) AS 商品Id;
END
GO
```

> ⚠️ **`WHEN NOT MATCHED BY SOURCE` の絞り込みを絶対に忘れないこと**
> `MERGE` のターゲットは `dbo.OrderDetails` **全体** です。
> `AND tgt.OrderId = @OrderId` を書き忘れると、**他の注文の明細まで全部 DELETE されます**。
> 不安なら、ターゲット自体を CTE で絞る書き方のほうが安全です。
>
> ```sql
> WITH tgt AS (SELECT * FROM dbo.OrderDetails WHERE OrderId = @OrderId)
> MERGE tgt USING (...) AS src ON tgt.ProductId = src.ProductId
> ...
> ```

```sql
BEGIN TRAN;

DECLARE @D AS dbo.OrderDetailType;
INSERT INTO @D (ProductId, Quantity, UnitPrice, Discount)
VALUES (1, 10, NULL, 0.20),     -- 既存なら更新 / 無ければ追加
       (9, 50, NULL, 0.00);     -- 追加

EXEC dbo.usp_MergeOrderDetails @OrderId = 1001, @Details = @D;

SELECT * FROM dbo.OrderDetails WHERE OrderId = 1001;

ROLLBACK;
```

---

## 7. なぜ TVP なのか — 「N 回呼ぶ」vs「1 回呼ぶ」

TVP が無い世界では、明細 N 行を登録するのに **プロシージャを N 回呼ぶ** ことになります。

```sql
-- 【方式A】1行ずつ N 回呼ぶ(アプリ側が for ループで回すイメージ)
EXEC dbo.usp_AddOrderDetail @OrderId = 9001, @ProductId = 1,  @Quantity = 1;
EXEC dbo.usp_AddOrderDetail @OrderId = 9001, @ProductId = 2,  @Quantity = 3;
EXEC dbo.usp_AddOrderDetail @OrderId = 9001, @ProductId = 16, @Quantity = 2;
-- … 明細が 500 行なら 500 回
```

```sql
-- 【方式B】TVP に詰めて1回だけ呼ぶ
DECLARE @D AS dbo.OrderDetailType;
INSERT INTO @D (ProductId, Quantity) VALUES (1,1),(2,3),(16,2) /* …500行 */;
EXEC dbo.usp_RegisterOrder @CustomerId=1, @EmployeeId=2, @OrderDate='2024-02-01',
                           @Details=@D, @NewOrderId=@Id OUTPUT;
```

同じ結果になりますが、**アプリケーションから見たコストがまったく違います**。

| | 方式A: 1行ずつ N 回 | 方式B: TVP で1回 |
|---|---|---|
| ネットワーク**ラウンドトリップ** | **N 回** | **1 回** |
| プロシージャ呼び出しのオーバーヘッド | N 回分 | 1 回分 |
| トランザクションの一貫性 | 途中で落ちると中途半端(自分で制御が必要) | プロシージャ内で1トランザクションにできる |
| ログ出力・ロック保持 | 断続的に N 回 | まとめて1回(短時間) |
| 検証ロジック | 呼び出しごとに実行 | 集合として1回で検証できる |

**ラウンドトリップの削減が最大の価値** です。
1往復の通信に 1ms かかる環境なら、500 行の登録は方式Aで **0.5 秒がまるまる待ち時間** になります。
方式Bならそれが 1ms です。DBサーバーが物理的に離れているほど、この差は劇的に開きます。

TVP 以外の「複数行をまとめて渡す」手段と比べても、TVP は素直です。

| 手法 | 評価 |
|---|---|
| **TVP** | ★推奨。型で構造が保証され、SQLインジェクションの余地もない |
| カンマ区切り文字列を渡して `STRING_SPLIT` で分解 | 型が全部文字列になる。列が増えると破綻(`STRING_SPLIT` は 2016 以降) |
| XML / JSON を渡して `OPENXML` / `OPENJSON` で分解 | 柔軟だがパースのコストが高い([22 JSON操作](22_json.md)) |
| 動的SQL で巨大な `INSERT ... VALUES` を組み立てる | インジェクションの危険とプラン再利用の悪化 |
| 一時テーブルに `SqlBulkCopy` してから呼ぶ | 数万行以上の超大量ならこちらが速い |

> 💡 **目安**: 数行〜数千行なら TVP。数万行を超えるなら `SqlBulkCopy`(一括コピー)を検討。

### アプリケーション側の渡し方(参考)

C# (ADO.NET) から渡す場合は、`SqlParameter` の型を `SqlDbType.Structured` にして
`DataTable` を渡すだけです。SQL 文字列を組み立てないので安全です。

```csharp
var p = cmd.Parameters.AddWithValue("@Details", detailTable);  // detailTable は DataTable
p.SqlDbType = SqlDbType.Structured;
p.TypeName  = "dbo.OrderDetailType";        // ★ 型名を教える
```

---

## 8. 型は後から変更できない — DROP の順序

> ⚠️ **本章でいちばん実務を刺してくる話です。**

ユーザー定義テーブル型に **`ALTER TYPE` はありません**。
「`Discount` の精度を上げたい」「列を1つ増やしたい」——どれも作り直しです。
そして、**その型を使っているプロシージャがあると `DROP TYPE` は失敗します**。

```sql
-- ✗ エラー 3732: 型 'OrderDetailType' は オブジェクト 'usp_RegisterOrder' で
--    参照されているため削除できません。
DROP TYPE dbo.OrderDetailType;
```

正しい手順は **「使っている側を先に落とす」** です。

```sql
-- (1) 誰が使っているか調べる
SELECT OBJECT_SCHEMA_NAME(p.object_id) AS スキーマ,
       OBJECT_NAME(p.object_id)        AS オブジェクト名,
       o.type_desc                     AS 種類,
       p.name                          AS パラメーター名
FROM   sys.parameters AS p
JOIN   sys.types      AS t ON t.user_type_id = p.user_type_id
JOIN   sys.objects    AS o ON o.object_id    = p.object_id
WHERE  t.name = N'OrderDetailType';

-- (2) 依存するプロシージャ/関数を先に削除
DROP PROCEDURE IF EXISTS dbo.usp_MergeOrderDetails;
DROP PROCEDURE IF EXISTS dbo.usp_RegisterOrder;
DROP PROCEDURE IF EXISTS dbo.usp_ShowOrderDetails;

-- (3) 型を削除
DROP TYPE IF EXISTS dbo.OrderDetailType;

-- (4) 新しい定義で作り直す
CREATE TYPE dbo.OrderDetailType AS TABLE ( ... 新しい定義 ... );

-- (5) プロシージャを作り直す
```

**`DROP PROCEDURE` → `DROP TYPE` の順序は必ず守ってください**(逆順では失敗します)。
本章の演習・解答も、この順序で後片付けするように書いてあります。

> 💡 **本番環境で無停止に変えたいとき**
> 上の手順は、一瞬とはいえプロシージャが存在しない時間ができます。
> それが許されない場合は、**新しい名前の型 (`OrderDetailType_v2`) を作り、
> 新しいプロシージャを追加 → アプリを切り替え → 旧型と旧プロシージャを削除**、
> という「並走させてから捨てる」進め方をします。
> 型名にバージョンを付けるのは、実務でよく見る割り切りです。

---

## 9. TVP は統計情報を持たない(性能上の最重要注意)

> ⚠️ **TVP の実体は「テーブル変数」です。だから統計情報を持ちません。**

[15 一時テーブルとテーブル変数](15_temp_tables.md) で学んだとおり、
テーブル変数には **統計情報が作られません**。TVP もまったく同じです。その結果:

- オプティマイザーは TVP の行数を **1行と見積もります**(実際に 5 万行入っていても)。
- そのため「1行なら最適」なプラン、つまり **ネステッドループ結合** を選びがちです。
- 実際には大量行が流れてきて、内側テーブルへのアクセスが何万回も繰り返され、**極端に遅くなります**。

実行プランで「推定行数 1 / 実際の行数 50000」という乖離を見たら、これが原因です。

### 対策1: `OPTION (RECOMPILE)`

TVP を参照するクエリに付けると、**実行時の実際の行数** を見てプランを立て直します。

```sql
SELECT ...
FROM   @Details AS d
JOIN   dbo.Products AS p ON p.ProductId = d.ProductId
OPTION (RECOMPILE);       -- 毎回コンパイルするので、そのぶんCPUは使う
```

- 毎回コンパイルするコストと引き換えなので、**高頻度で呼ばれる軽いクエリには使わない**。

### 対策2: 一時テーブルに受け直す(大量行のときの定石)

TVP をいったん `#一時テーブル` に写すと、**統計情報が作られ、インデックスも張れます**。

```sql
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

    -- これ以降は #Details を使う。統計情報があるので適切なプランが選ばれる
    BEGIN TRAN;

        SELECT @NewOrderId = ISNULL(MAX(OrderId), 1000) + 1
        FROM   dbo.Orders WITH (UPDLOCK, HOLDLOCK);

        INSERT INTO dbo.Orders (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate)
        VALUES (@NewOrderId, @CustomerId, @EmployeeId, @OrderDate, NULL);

        INSERT INTO dbo.OrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
        SELECT @NewOrderId, d.ProductId, d.Quantity,
               COALESCE(d.UnitPrice, p.UnitPrice), d.Discount
        FROM   #Details     AS d
        JOIN   dbo.Products AS p ON p.ProductId = d.ProductId;

    COMMIT;

    DROP TABLE #Details;
END
GO
```

- コピーのコストはかかります。**数十〜数百行なら不要、数千行を超えるなら効いてくる**、が目安です。
- TVP は `READONLY` で加工できないので、**「中身を書き換えたい」ときにもこの受け直しが必要** です。

### 対策3: SQL Server 2019 以降のテーブル変数の遅延コンパイル

> 📌 **バージョン依存**: **SQL Server 2019 以降** かつ **データベース互換性レベル 150 以上** では、
> 「テーブル変数の遅延コンパイル (Table Variable Deferred Compilation)」により、
> テーブル変数・TVP の **実際の行数** を使ってプランが作られるようになりました。
> これで上記の問題はかなり緩和されます。
> ただし互換性レベルが 140 以下のままなら従来どおり「1行見積もり」です。
> 自分の環境を確認しておきましょう。
>
> ```sql
> SELECT name, compatibility_level FROM sys.databases WHERE name = DB_NAME();
> ```

---

## 10. カタログビューで確認する

作った型は `sys.types` と `sys.table_types` で確認できます。

```sql
-- ユーザー定義型の一覧(別名型もテーブル型も両方出る)
SELECT SCHEMA_NAME(schema_id) AS スキーマ,
       name                   AS 型名,
       is_table_type          AS テーブル型か,
       TYPE_NAME(system_type_id) AS 基になる型,
       max_length, precision, scale, is_nullable
FROM   sys.types
WHERE  is_user_defined = 1
ORDER  BY is_table_type, name;
```

```sql
-- テーブル型の「列構成」を見る
SELECT SCHEMA_NAME(tt.schema_id) AS スキーマ,
       tt.name                   AS 型名,
       c.column_id               AS 列順,
       c.name                    AS 列名,
       TYPE_NAME(c.user_type_id) AS データ型,
       c.max_length, c.precision, c.scale,
       c.is_nullable             AS NULL可
FROM   sys.table_types AS tt
JOIN   sys.columns     AS c ON c.object_id = tt.type_table_object_id   -- ★ ここが要
WHERE  tt.is_user_defined = 1
ORDER  BY tt.name, c.column_id;
```

- テーブル型の列は `tt.object_id` ではなく **`tt.type_table_object_id`** で結合します(引っかかりやすい点)。
- 型定義に含めた主キー・インデックスは `sys.indexes` を同じ `type_table_object_id` で引けば見えます。

```sql
-- 型に定義したインデックス(PRIMARY KEY など)
SELECT tt.name AS 型名, i.name AS インデックス名, i.type_desc, i.is_primary_key, i.is_unique
FROM   sys.table_types AS tt
JOIN   sys.indexes     AS i ON i.object_id = tt.type_table_object_id
WHERE  tt.is_user_defined = 1;
```

---

## 11. CLR ユーザー定義型(存在だけ知っておく)

.NET (C# / VB.NET) でクラスを書き、アセンブリを SQL Server に登録して
**独自のデータ型そのもの** を作る機能です。

```sql
-- おおまかな流れ(実際に実行する必要はありません)
sp_configure 'clr enabled', 1; RECONFIGURE;
CREATE ASSEMBLY MyTypes FROM 'C:\...\MyTypes.dll' WITH PERMISSION_SET = SAFE;
CREATE TYPE dbo.Point3D EXTERNAL NAME MyTypes.[MyNamespace.Point3D];
```

**実務ではほぼ使いません。** 理由は明快です。

- .NET のビルド・配置・バージョン管理が必要で、運用が一気に重くなる。
- SQL Server 2017 以降は「CLR 厳密なセキュリティ (CLR strict security)」により、
  アセンブリへの署名か信頼登録が必須になり、導入のハードルがさらに上がった。
- Azure SQL Database では CLR アセンブリを使えない。
- たいていの要件は、テーブル型・組み込み関数・JSON で足ります。

> 💡 一方で、**SQL Server が最初から持っている CLR 型** は普通に使います。
> `hierarchyid`(階層)、`geometry` / `geography`(空間データ)がそれで、
> これらは中身が CLR 型ですが、追加の設定なしにそのまま使えます。

「CLR ユーザー定義型という機能がある」「でも普通は作らない」——本章ではここまでで十分です。

---

## よくあるつまずき

- **エラー 352「テーブル値パラメーターは READONLY と宣言する必要があります」**
  → TVP パラメータに `READONLY` を付け忘れている。TVP では必須。
- **プロシージャ内で TVP を `UPDATE` / `INSERT` / `DELETE` できない**
  → `READONLY` の仕様。加工したいなら一時テーブルかテーブル変数に `SELECT` で写す。
- **TVP を `OUTPUT` にできない** → TVP は入力専用。結果を返すなら通常の `SELECT` で返す。
- **`DROP TYPE` が失敗する(エラー 3732)**
  → その型を使うプロシージャ/関数/テーブル列がある。**先に依存側を `DROP`** する。
  順序は必ず **`DROP PROCEDURE` → `DROP TYPE`**。
- **型の列を変えたいのに `ALTER TYPE` が無い** → 仕様。作り直すか、`_v2` を作って並走させる。
- **TVP に大量行を渡したら急に遅くなった**
  → 統計情報が無く「1行」と見積もられている。`OPTION (RECOMPILE)` か一時テーブルへの受け直しを検討。
- **`NULL` を渡してエラーになる** → TVP に `NULL` は渡せない。渡さなければ「0行」として扱われる。
- **`DECLARE @t dbo.型名;` が別のバッチで「宣言されていません」になる**
  → 変数はバッチ (`GO`) をまたげない。宣言と使用は同じバッチに書く。
- **`sys.table_types` の列が取れない** → `sys.columns` とは `type_table_object_id` で結合する。

## この章のまとめ

- ユーザー定義型は3種類。実務の主役は **ユーザー定義テーブル型 = TVP**。
- **別名データ型** は定義の一元化に便利だが、`ALTER TYPE` が無く後から変えにくい。
- `CREATE TYPE ... AS TABLE (...)` には **主キー・UNIQUE・CHECK・DEFAULT** を書ける。
  外部キーは書けない。
- プロシージャの TVP パラメータには **`READONLY` が必須**。中身は変更不可・`OUTPUT` 不可。
- **複数行をまとめて1回で渡せる**のが最大の価値。1行ずつ N 回呼ぶのに比べ、
  **ネットワークのラウンドトリップが N 回 → 1 回** になる。
- TVP の実体はテーブル変数なので **統計情報を持たない**。大量行では
  `OPTION (RECOMPILE)` または **一時テーブルへ受け直す**。
  SQL Server 2019 + 互換性レベル 150 以降は遅延コンパイルで緩和される。
- 型を変えたいときは **`DROP PROCEDURE` → `DROP TYPE` → 作り直し** の順序。逆順は失敗する。
- 確認は `sys.types` / `sys.table_types`(列は `type_table_object_id` で結合)。
- **CLR ユーザー定義型** は存在を知っておけば十分。通常は使わない。

➡ 演習: [exercises/17_user_defined_types.md](../exercises/17_user_defined_types.md)
