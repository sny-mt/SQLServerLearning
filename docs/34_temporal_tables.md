# 34 テンポラルテーブルと履歴設計

> **このトピックのゴール**: 「**この顧客の3か月前の与信枠は?**」「**誰がいつ単価を変えたか?**」という
> 業務要求を、アプリケーションのコードを一切書かずに SQL Server の
> **システムバージョン管理テンポラルテーブル**で満たせるようになる。
> `FOR SYSTEM_TIME` の5つの句を **境界の含む/含まないまで正確に**使い分け、
> 履歴表のインデックス設計・保持ポリシー・**運用上の制約(スキーマ変更と削除の手順)**まで
> 押さえて、「この要件にテンポラルテーブルを使うべきか」を自分で判断できるようになる。
>
> **前提**: [33 SQL Serverアーキテクチャ](33_architecture.md) までを済ませ、
> [13 データ操作 (DML)](13_dml.md) のトランザクション、
> [30 列ストアインデックスとバッチモード](30_columnstore.md) のインデックス知識があること。
> `SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **バージョン前提 — システムバージョン管理テンポラルテーブルは SQL Server 2016 (13.x) 以降**
> `PERIOD FOR SYSTEM_TIME` / `GENERATED ALWAYS AS ROW START` / `SYSTEM_VERSIONING = ON` /
> `FOR SYSTEM_TIME` は **すべて SQL Server 2016 以降**の機能です。2014 以前では一切使えません。
> **Enterprise 専用ではなく、Standard / Express でも使えます**(2016 以降のすべてのエディション)。
>
> 本章のうち **保持ポリシー(`HISTORY_RETENTION_PERIOD`)は SQL Server 2017 (14.x) 以降**です。
> それ以外にバージョン依存がある箇所はその都度明記します。
>
> ```sql
> -- 自分の環境を確認する
> SELECT @@VERSION                                        AS サーバーバージョン,
>        SERVERPROPERTY('ProductMajorVersion')            AS メジャーバージョン,  -- 13=2016, 14=2017, 15=2019, 16=2022
>        SERVERPROPERTY('Edition')                        AS エディション;
> ```

> ⚠️ **この章の安全方針 — 業務テーブルは絶対にテンポラル化しない**
> `dbo.Products` や `dbo.Employees` をそのままテンポラル化すると、
> **元に戻すのに `SYSTEM_VERSIONING = OFF` → `DROP PERIOD` → 列削除**という手順が必要になり、
> 学習用 DB が散らかります。本章の例・演習・解答は、すべて
> **専用のコピー表 `dbo.ProductsTemporal` / `dbo.CategoriesTemporal`** に対して行い、
> 最後に **`SYSTEM_VERSIONING = OFF` → `DROP PERIOD` → 両方の表を `DROP TABLE`** の順で
> 完全に片付けます(手順は第11節)。

---

## 1. 履歴管理という要件 — 従来はどう実装していたか

現場から来る要求は、たいてい次の2種類です。

- **時点再現**: 「**2024年3月末時点**の商品マスタで再集計したい」「この顧客の**3か月前の与信枠**は?」
- **変更追跡**: 「この商品の単価、**誰がいつ**いくらからいくらに変えた?」

現在の行しか持たないテーブルでは、どちらにも答えられません。`UPDATE` した瞬間に
前の値は消えてしまうからです。そこで従来は、次のような実装を手で書いていました。

### 従来案A: トリガーで履歴表に書く

```sql
-- ※これは「従来はこう書いていた」という例。実行しなくてよい
CREATE TABLE dbo.ProductsHistoryManual
(
    ProductId   INT            NOT NULL,
    ProductName NVARCHAR(100)  NOT NULL,
    UnitPrice   DECIMAL(10, 0) NOT NULL,
    変更日時     DATETIME2(7)   NOT NULL,
    変更者       NVARCHAR(128)  NOT NULL,
    操作種別     NVARCHAR(10)   NOT NULL
);
GO

CREATE TRIGGER dbo.trg_Products_History
ON dbo.Products
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.ProductsHistoryManual
        (ProductId, ProductName, UnitPrice, 変更日時, 変更者, 操作種別)
    SELECT d.ProductId, d.ProductName, d.UnitPrice,
           SYSUTCDATETIME(), SUSER_SNAME(),
           CASE WHEN EXISTS (SELECT 1 FROM inserted) THEN N'UPDATE' ELSE N'DELETE' END
    FROM   deleted AS d;                    -- 「変更前」の値を残す
END;
GO
```

### 従来案B: 更新の直前にアプリ側で別表へコピーする

`UPDATE` の前に `INSERT INTO 履歴表 SELECT * FROM 元表 WHERE ...` をアプリケーションが呼ぶ方式です。

### これらの問題点

| 問題 | 中身 |
|---|---|
| **実装漏れ** | 案Bは「その `UPDATE` を書いた人」が履歴 `INSERT` を忘れたら終わり。案Aでも `TRUNCATE TABLE` や `FIRE_TRIGGERS` を指定しない一括挿入(`bcp` / `BULK INSERT`)は **トリガーを起動しません**。 |
| **トランザクション整合性** | 案Bは履歴 `INSERT` と本体 `UPDATE` が別トランザクションになりがちで、片方だけ成功しうる。 |
| **時刻の不整合** | 各行が `SYSDATETIME()` を個別に呼ぶと、同じ更新なのに行ごとに数ミリ秒ずれる。**「その時点の全社の状態」が一意に決まらない**。 |
| **クエリが煩雑** | 「ある時点の状態」を得るには、現在表と履歴表を `UNION ALL` して行ごとに有効期間を計算し、`ROW_NUMBER()` で最新版を選ぶ…という長いクエリを毎回書く羽目になる。 |
| **スキーマのずれ** | 本体に列を足したとき履歴表への追加を忘れると、静かに記録されない列ができる。 |
| **性能** | トリガーは更新トランザクションの中で同期実行される。大量更新でトランザクションが長くなる([19 トランザクション](19_transactions_isolation.md))。 |

**テンポラルテーブルは、この5〜6個の問題をエンジン側でまとめて解決する機能**です。
逆に言えば、テンポラルテーブルが解決**しない**問題(誰が変更したか)は残ります(第12節)。

## 2. テンポラルテーブルの仕組み

システムバージョン管理テンポラルテーブルは、**必ず2つの表がペア**で動きます。

```
   dbo.ProductsTemporal          （現在表 / current table）
        ├─ 主キー必須。今の行だけが入っている
        └─ PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
                │  UPDATE / DELETE すると、変更前の行が自動で ↓ へ移動
                ▼
   dbo.ProductsTemporalHistory   （履歴表 / history table）
        ├─ 現在表と同じ列構成（列名・型・順序が一致していること）
        └─ 主キー・IDENTITY・制約・トリガーは持てない
```

- 現在表の行を `UPDATE` / `DELETE` すると、**変更前の行が履歴表へ自動的に挿入**されます。
  これは **同じトランザクションの中**で行われるため、片方だけ成功することはありません。
- アプリケーションのコード変更は不要です。`INSERT` / `UPDATE` / `DELETE` はそのままで動きます。

### ピリオド列(期間列)

```sql
ValidFrom DATETIME2(7) GENERATED ALWAYS AS ROW START NOT NULL,
ValidTo   DATETIME2(7) GENERATED ALWAYS AS ROW END   NOT NULL,
PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
```

- 型は **`datetime2`** でなければなりません(精度は `datetime2(0)`〜`datetime2(7)` を選べる)。
- **`NOT NULL` 必須**。値は SQL Server が入れるので、アプリからは書き込めません
  (書こうとすると「`GENERATED ALWAYS` 列は更新できない」というエラーになります)。
- 列名は自由です。`ValidFrom` / `ValidTo` が慣習ですが、`SysStartTime` / `SysEndTime` もよく使われます。

> ⚠️ **記録される時刻は UTC(協定世界時)です。ローカル時刻ではありません。**
> SQL Server は内部的に **`SYSUTCDATETIME()`** の値を書き込みます。日本(JST)は UTC+9 なので、
> 「17:00 に変更したのに `ValidFrom` が 08:00 になっている」のは**正常**です。
> `FOR SYSTEM_TIME` に渡す時刻も **UTC で渡す**必要があります(第6節)。

### 期間は半開区間 `[ValidFrom, ValidTo)` — 最大の落とし穴

行が有効なのは **`ValidFrom <= 時刻 < ValidTo`** の範囲です。
**開始は含み、終了は含みません**(半開区間)。

そのため、時刻 `T` に `UPDATE` が起きると次のようになります。

| 表 | ProductId | UnitPrice | ValidFrom | ValidTo |
|---|---|---|---|---|
| 履歴表 | 1 | 128000 | 2024-03-01 00:00 | **T** |
| 現在表 | 1 | 138000 | **T** | 9999-12-31 23:59:59.9999999 |

- 古い行の `ValidTo` と新しい行の `ValidFrom` が **同じ値 `T`** になります。**重複しません**。
- したがって **`AS OF T` はちょうど新しい行(138000)を返します**。
  「変更直前の状態」が欲しいなら `T` より前の時刻を指定しなければなりません。
  ここを間違えると「1件も出ない」「1つ後ろの世代が出た」という事故になります。
- 現在の行の `ValidTo` は **`datetime2` の最大値** `9999-12-31 23:59:59.9999999` です
  (精度が `datetime2(0)` なら `9999-12-31 23:59:59`)。「現在行か?」の判定はこの値と比較します。

### ピリオド列を隠す `HIDDEN`

ピリオド列は業務上ノイズになりがちなので、**`HIDDEN`** を付けると
`SELECT *` の結果に**出なくなります**(明示的に列名を書けば取得できます)。

```sql
ValidFrom DATETIME2(7) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
ValidTo   DATETIME2(7) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
```

- 既存アプリの `SELECT *` や `INSERT`(列リスト省略)を壊さずにテンポラル化できるのが利点です。
- **既存テーブルを後からテンポラル化するときは、原則 `HIDDEN` を付ける**と考えてよいでしょう。
- 隠れているかは `sys.columns.is_hidden` で確認できます。

## 3. 作り方(1) — 新規にテンポラルテーブルを作る

```sql
CREATE TABLE dbo.CategoriesTemporal
(
    CategoryId   INT           NOT NULL
        CONSTRAINT PK_CategoriesTemporal PRIMARY KEY CLUSTERED,
    CategoryName NVARCHAR(50)  NOT NULL,
    ValidFrom    DATETIME2(7)  GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo      DATETIME2(7)  GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.CategoriesTemporalHistory));
```

要件は次のとおりです。

- **現在表には主キーが必須**(履歴表には主キーを付けてはいけない、という非対称に注意)。
- ピリオド列2つと `PERIOD FOR SYSTEM_TIME` の宣言。
- `SYSTEM_VERSIONING = ON` に **`HISTORY_TABLE` を必ず書く**。

> ⚠️ **`HISTORY_TABLE` を省略しないこと。**
> 省略すると `dbo.MSSQL_TemporalHistoryFor_<object_id>` という
> **オブジェクトIDを含む自動生成名**の履歴表(匿名履歴表)が作られます。
> 環境ごとに名前が変わるので、デプロイスクリプト・権限設定・監視で扱いづらくなります。
> **必ず `<元表名>History` のような固定名を指定**しましょう。

履歴表を自分で作っておいてから紐付けることもできます。
**別ファイルグループに置きたい**、**最初から列ストアにしたい**、といった場合はこちらです(第8節)。

## 4. 作り方(2) — 既存テーブルを後からテンポラル化する

すでにデータが入っているテーブルに `NOT NULL` の列を追加するので、**既定値の指定が必須**です。
ここが新規作成との最大の違いです。

```sql
-- ① 実験用のコピー表を作る（業務テーブルは触らない）
DROP TABLE IF EXISTS dbo.ProductsTemporal;
CREATE TABLE dbo.ProductsTemporal
(
    ProductId    INT            NOT NULL
        CONSTRAINT PK_ProductsTemporal PRIMARY KEY CLUSTERED,
    ProductName  NVARCHAR(100)  NOT NULL,
    CategoryId   INT            NULL,
    UnitPrice    DECIMAL(10, 0) NOT NULL,
    Discontinued BIT            NOT NULL
);

INSERT INTO dbo.ProductsTemporal (ProductId, ProductName, CategoryId, UnitPrice, Discontinued)
SELECT ProductId, ProductName, CategoryId, UnitPrice, Discontinued
FROM   dbo.Products;                       -- 20 行

-- ② ピリオド列を追加する（既定値が必須）
ALTER TABLE dbo.ProductsTemporal
ADD ValidFrom DATETIME2(7) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
        CONSTRAINT DF_ProductsTemporal_ValidFrom
        DEFAULT CONVERT(DATETIME2(7), '2000-01-01 00:00:00.0000000'),
    ValidTo   DATETIME2(7) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL
        CONSTRAINT DF_ProductsTemporal_ValidTo
        DEFAULT CONVERT(DATETIME2(7), '9999-12-31 23:59:59.9999999'),
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo);

-- ③ システムバージョン管理を有効化する
ALTER TABLE dbo.ProductsTemporal
SET (SYSTEM_VERSIONING = ON
     (HISTORY_TABLE = dbo.ProductsTemporalHistory, DATA_CONSISTENCY_CHECK = ON));
```

- **`ValidTo` の既定値は `datetime2` の最大値でなければなりません。**
  精度がずれる(`datetime2(3)` の表に `.9999999` を入れる等)と有効化に失敗します。
- **`ValidFrom` の既定値は設計判断です。**
  - `SYSUTCDATETIME()` … 「テンポラル化した時点から履歴が始まる」。既存行の作成日時は分からない、という素直な表明。
  - 過去の固定日(上の例の `2000-01-01`)… 「その表の行は昔から存在していたことにする」。
    **過去の注文日で `AS OF` しても行が返る**ので、演習や検証はこちらが扱いやすい。
  - **未来の日付は絶対に使わない**(`ValidFrom > ValidTo` になったり、`AS OF 現在` で何も返らなくなる)。
- **`DATA_CONSISTENCY_CHECK = ON`**(履歴表を指定したときの既定)は、
  「履歴表に `ValidFrom >= ValidTo` の行がないか」「期間が重なっていないか」を検査します。
  自前の履歴表を流用するときは **必ず ON のままにする**こと。行数が多いと有効化に時間がかかりますが、
  ここで弾かれるデータは後で必ず問題を起こします。

### 有効化できたか確認する

```sql
SELECT s.name                              AS スキーマ,
       t.name                              AS テーブル,
       t.temporal_type_desc                AS 種別,
       OBJECT_NAME(t.history_table_id)     AS 履歴表
FROM   sys.tables   AS t
JOIN   sys.schemas  AS s ON s.schema_id = t.schema_id
WHERE  t.temporal_type <> 0                -- 0=非テンポラル
ORDER  BY t.name;

-- ピリオドの定義（どの列が開始/終了か）
SELECT OBJECT_NAME(p.object_id)                         AS テーブル,
       COL_NAME(p.object_id, p.start_column_id)         AS 開始列,
       COL_NAME(p.object_id, p.end_column_id)           AS 終了列
FROM   sys.periods AS p;
```

`temporal_type_desc` は **`SYSTEM_VERSIONED_TEMPORAL_TABLE`(=2)** と
**`HISTORY_TABLE`(=1)** の2種類が出ます。スクリプトから判定するときは
`OBJECTPROPERTY(OBJECT_ID(N'dbo.ProductsTemporal'), 'TableTemporalType')` も使えます
(0=非テンポラル / 1=履歴表 / 2=現在表)。

## 5. DML を実行すると履歴に何が起きるか

| 操作 | 現在表 | 履歴表 |
|---|---|---|
| `INSERT` | 行が入り、`ValidFrom` = トランザクション開始時刻、`ValidTo` = 9999-12-31… | 何も起きない |
| `UPDATE` | 行が新しい値になり、`ValidFrom` = トランザクション開始時刻 | **変更前の行**が入り、`ValidTo` = トランザクション開始時刻 |
| `DELETE` | 行が消える | **削除直前の行**が入り、`ValidTo` = トランザクション開始時刻 |
| `MERGE` | 内部で `INSERT`/`UPDATE`/`DELETE` として扱われ、上と同じ | 同左 |

```sql
-- 単価を1回だけ変えてみる
UPDATE dbo.ProductsTemporal SET UnitPrice = 138000 WHERE ProductId = 1;

-- 現在表と履歴表の両方を見る（HIDDEN 列は明示すれば取れる）
SELECT N'現在' AS 区分, ProductId, ProductName, UnitPrice, ValidFrom, ValidTo
FROM   dbo.ProductsTemporal        WHERE ProductId = 1
UNION ALL
SELECT N'履歴',        ProductId, ProductName, UnitPrice, ValidFrom, ValidTo
FROM   dbo.ProductsTemporalHistory WHERE ProductId = 1
ORDER  BY ValidFrom;
```

> ⚠️ **記録される時刻は「文の実行時刻」ではなく「トランザクションの開始時刻」です。**
> これは「1つのトランザクションで変更した行はすべて同じ時刻を持つ」ことを保証するための仕様で、
> **時点再現の一貫性の根拠**そのものです。ただし2つの副作用があります。
>
> 1. **同じトランザクションの中で同じ行を2回更新すると、`ValidFrom = ValidTo` の
>    「長さ0の履歴行」ができます。** この行は `FOR SYSTEM_TIME` の**どの句でも返りません**
>    (履歴表を直接 `SELECT` すれば見えます)。
>    同一トランザクション内で挿入して削除した行も同様です。
> 2. **トランザクションの中で `WAITFOR DELAY` を挟んでも時刻は進みません。**
>    時間差のある履歴を作る実験をしたいときは、**トランザクションを分けて**
>    (=自動コミットのまま1文ずつ)実行し、その**間**に `WAITFOR DELAY '00:00:03';` を入れます。
>
> ```sql
> -- ✗ これでは3行とも同じ ValidFrom になり、長さ0の履歴行が2本できるだけ
> BEGIN TRAN;
>     UPDATE dbo.ProductsTemporal SET UnitPrice = 130000 WHERE ProductId = 1;
>     WAITFOR DELAY '00:00:03';
>     UPDATE dbo.ProductsTemporal SET UnitPrice = 132000 WHERE ProductId = 1;
> COMMIT;
>
> -- ○ 1文ずつ確定させ、その間に待つ
> UPDATE dbo.ProductsTemporal SET UnitPrice = 130000 WHERE ProductId = 1;
> WAITFOR DELAY '00:00:03';
> UPDATE dbo.ProductsTemporal SET UnitPrice = 132000 WHERE ProductId = 1;
> ```

もう1つ、**値が変わらない `UPDATE` でも履歴行は作られます**。
`SET UnitPrice = UnitPrice` のような空更新でも「更新した」と記録されるため、
無意味な一括 `UPDATE` を回すバッチがあると履歴が膨らみます(第9節・第14節)。

## 6. `FOR SYSTEM_TIME` — この章の主役

`FROM` 句のテーブル参照の直後に書きます。**現在表と履歴表を自動的に UNION した上で**、
指定した期間条件で絞り込んだ結果が返ります。書き手は履歴表の存在を意識しません。

```sql
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.ProductsTemporal FOR SYSTEM_TIME AS OF '2024-03-31 15:00:00'
WHERE  CategoryId = 1;
```

### 5つの句と境界(最重要)

`F` = `ValidFrom`、`T` = `ValidTo` としたときの**同値な述語**です。**丸暗記より述語で覚える**のが確実です。

| 句 | 同値な述語 | 開始境界 `@a` | 終了境界 `@b` | 何を取り出す句か |
|---|---|---|---|---|
| `AS OF @t` | `F <= @t AND T > @t` | ― | ― | **その瞬間に有効だった行**(1キーにつき最大1行) |
| `FROM @a TO @b` | `F < @b AND T > @a` | **含まない** | **含まない** | 期間中に有効だった行。**両端ちょうどの行は落ちる** |
| `BETWEEN @a AND @b` | `F <= @b AND T > @a` | **含まない** | **含む** | `FROM…TO` に「`@b` ちょうどに開始した行」を足したもの |
| `CONTAINED IN (@a, @b)` | `F >= @a AND T <= @b` | **含む** | **含む** | **期間内に開始し、期間内に終了した行だけ** |
| `ALL` | (条件なし) | ― | ― | 現在表+履歴表の全行 |

覚え方:

- **`AS OF` は時点、それ以外は期間**。
- **`BETWEEN` は `FROM…TO` の終端だけを含む版**(「`@b` に開始した行を入れるか」だけの違い)。
- **`CONTAINED IN` だけが「まるごと期間内に収まった行」**。
  したがって **現在行(`ValidTo` = 9999-12-31…)は `CONTAINED IN` では絶対に返りません**。
  「返ってこない!」の相談で一番多いのがこれです。
- `CONTAINED IN` だけ**引数がカンマ区切りの括弧**で、他は `TO` / `AND` です。構文も間違えやすい。

> ⚠️ **`ValidFrom = ValidTo` の長さ0の行は、5つの句のどれでも返りません。**
> 「履歴表を直接見ると行があるのに `ALL` で出ない」ときは、これを疑ってください
> (=同一トランザクション内で2回変更された行)。

### 引数に書けるもの・書けないもの

- **定数・変数・ストアドプロシージャのパラメータは書けます**。
  ```sql
  DECLARE @asof DATETIME2(7) = '2024-03-31 15:00:00';
  SELECT * FROM dbo.ProductsTemporal FOR SYSTEM_TIME AS OF @asof;
  ```
- **他のテーブルの列は書けません。** 「注文ごとに、その注文日時点の単価を引く」のように
  **行ごとに違う時点**を参照したい場合、`AS OF` は使えません。
  → `FOR SYSTEM_TIME ALL` + 期間条件の結合で書きます(第7.4節)。
- テンポラルテーブルを参照する**ビューに対しても** `FOR SYSTEM_TIME` を書けます
  (ビュー定義側ではなく、**ビューを使う側**に書く)。複数表をまとめて時点再現する定番手法です。

### 時刻は UTC で渡す

`FOR SYSTEM_TIME` に渡す値は **UTC として解釈**されます。JST の感覚で `'2024-03-31 15:00'` と
書くと、実際には JST の 4/1 0:00 の状態が返ります。

```sql
-- JST のつもりの時刻を UTC に直してから渡す（AT TIME ZONE は SQL Server 2016 以降）
DECLARE @jst   DATETIME2(7) = '2024-03-31 15:00:00';          -- 日本時間で見た時刻
DECLARE @utc   DATETIME2(7) =
    CAST(@jst AT TIME ZONE 'Tokyo Standard Time' AT TIME ZONE 'UTC' AS DATETIME2(7));

SELECT @jst AS 指定したJST, @utc AS 実際に渡すUTC;
SELECT * FROM dbo.ProductsTemporal FOR SYSTEM_TIME AS OF @utc;
```

- 逆に、履歴の `ValidFrom` を画面に出すときは
  `ValidFrom AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'` で JST に直します。
- **`SYSDATETIME()`(ローカル)を `AS OF` に渡すのは典型的なバグ**です。`SYSUTCDATETIME()` を使ってください。

## 7. 実務クエリ4パターン

### 7.1 ある時点の「全社の状態」を再現する(`AS OF`)

決算の再計算・監査対応の定番です。**複数の表を結合するときは、各テーブル参照にそれぞれ
`FOR SYSTEM_TIME AS OF` を付けます**(1か所書けば全体に効く、ということはありません)。

```sql
DECLARE @asof DATETIME2(7) = '2024-03-31 15:00:00';   -- UTC

SELECT p.ProductId,
       p.ProductName,
       c.CategoryName,
       p.UnitPrice AS 当時の単価
FROM   dbo.ProductsTemporal   FOR SYSTEM_TIME AS OF @asof AS p
LEFT   JOIN dbo.CategoriesTemporal FOR SYSTEM_TIME AS OF @asof AS c
       ON c.CategoryId = p.CategoryId
ORDER  BY p.ProductId;
```

- **`AS OF` の値をすべて同じ変数にする**のが鉄則です。式を2回書くと(`SYSUTCDATETIME()` を
  2か所に書く等)、わずかにずれた時点を結合してしまいます。
- 「当時の単価で当時の注文を再集計する」なら、`dbo.OrderDetails` は**注文時点の単価を
  自分で保持している**ので、そもそも結合先の履歴を見る必要はありません。
  **どの値をスナップショットとして持ち、どの値を履歴から引くのか**は設計の判断です
  ([35 データモデリングと物理設計](35_data_modeling.md))。

### 7.2 ある行の変更履歴を追う(`ALL` + ウィンドウ関数)

```sql
SELECT ProductId,
       ProductName,
       UnitPrice,
       LAG(UnitPrice) OVER (PARTITION BY ProductId ORDER BY ValidFrom) AS 変更前単価,
       UnitPrice - LAG(UnitPrice) OVER (PARTITION BY ProductId ORDER BY ValidFrom) AS 差額,
       ValidFrom AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time' AS 開始JST,
       CASE WHEN ValidTo = CONVERT(DATETIME2(7), '9999-12-31 23:59:59.9999999')
            THEN N'（現在）'
            ELSE CONVERT(NVARCHAR(30), ValidTo AT TIME ZONE 'UTC'
                                                AT TIME ZONE 'Tokyo Standard Time', 120)
       END AS 終了JST,
       DATEDIFF(SECOND, ValidFrom, ValidTo)  AS 有効秒数
FROM   dbo.ProductsTemporal FOR SYSTEM_TIME ALL
WHERE  ProductId = 1
ORDER  BY ValidFrom;
```

- `ALL` + `ORDER BY ValidFrom` が「1行の一生」を出す基本形です。
- `LAG`([08 ウィンドウ関数](08_window_functions.md))で **前の世代との差分**を出せます。
- **`DATEDIFF(SECOND, …)` は現在行だと巨大な値**(9999年まで)になります。
  現在行を除くか、`CASE` で表示を分けましょう。

### 7.3 2時点間の差分を出す(`AS OF` × 2 の `FULL OUTER JOIN`)

「先月末から今月末までに、マスタの何がどう変わったか」を1画面で出すパターンです。

```sql
DECLARE @t1 DATETIME2(7) = '2024-03-01 00:00:00';   -- 旧
DECLARE @t2 DATETIME2(7) = '2024-04-01 00:00:00';   -- 新

WITH 旧 AS (
    SELECT ProductId, ProductName, UnitPrice, Discontinued
    FROM   dbo.ProductsTemporal FOR SYSTEM_TIME AS OF @t1
),
新 AS (
    SELECT ProductId, ProductName, UnitPrice, Discontinued
    FROM   dbo.ProductsTemporal FOR SYSTEM_TIME AS OF @t2
)
SELECT COALESCE(新.ProductId, 旧.ProductId) AS ProductId,
       CASE WHEN 旧.ProductId IS NULL THEN N'追加'
            WHEN 新.ProductId IS NULL THEN N'削除'
            ELSE N'変更' END                AS 区分,
       旧.ProductName AS 旧名称, 新.ProductName AS 新名称,
       旧.UnitPrice   AS 旧単価, 新.UnitPrice   AS 新単価
FROM   旧
FULL   OUTER JOIN 新 ON 新.ProductId = 旧.ProductId
WHERE  旧.ProductId IS NULL                    -- 追加された
   OR  新.ProductId IS NULL                    -- 削除された
   OR  旧.UnitPrice    <> 新.UnitPrice         -- 変わった
   OR  旧.ProductName  <> 新.ProductName
   OR  旧.Discontinued <> 新.Discontinued
ORDER  BY ProductId;
```

- **`FULL OUTER JOIN`**([04 JOIN](04_joins.md))で「片側にしか無い=追加/削除」を拾います。
- **NULL 可の列の比較に注意**。`旧.CategoryId <> 新.CategoryId` は片方が NULL だと成立しません。
  NULL 可の列を比べるなら
  `EXISTS (SELECT 旧.* INTERSECT SELECT 新.*)` が偽、という書き方
  ([11 条件式と NULL 処理](11_conditional_null.md))か、`ISNULL` で埋めてから比較します。
- 「その2時点の**間に**何回変更されたか」まで知りたいときは、差分ではなく
  `FROM @t1 TO @t2` で**途中の世代をすべて**取り出します(差分クエリでは中間の変更が見えません)。

### 7.4 行ごとに違う時点を参照する(`ALL` + 期間結合)

`AS OF` に列を書けないため、「各注文の**注文日時点**の単価」は結合で解きます。

```sql
SELECT o.OrderId,
       o.OrderDate,
       od.ProductId,
       h.ProductName,
       h.UnitPrice      AS 注文日時点のマスタ単価,
       od.UnitPrice     AS 注文明細に記録された単価
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
JOIN   dbo.ProductsTemporal FOR SYSTEM_TIME ALL AS h
       ON  h.ProductId = od.ProductId
       AND CAST(o.OrderDate AS DATETIME2(7)) >= h.ValidFrom     -- 半開区間の再現
       AND CAST(o.OrderDate AS DATETIME2(7)) <  h.ValidTo
WHERE  o.OrderId = 1001
ORDER  BY od.ProductId;
```

- 結合条件を **`>= ValidFrom AND < ValidTo`** と書くのがポイント。`BETWEEN` にすると
  境界の瞬間に**2世代がヒットして行が増えます**(半開区間を自分で再現する)。
- `OrderDate` は `DATE` 型かつ **JST の業務日**、`ValidFrom` は **UTC の日時**です。
  厳密にやるなら業務日を UTC に変換してから比較します。
  **「日付」と「UTC の瞬間」を無造作に比べない**こと。
- この結合は履歴表全体をなめるので、**履歴表側のインデックス**が効くかどうかで性能が大きく変わります(第8節)。

## 8. 履歴表の設計 — 放置すると必ず効いてくる

### 既定でどうなっているか

履歴表を自動生成させると、SQL Server は
**`(ValidTo, ValidFrom)` を先頭とするクラスター化インデックス**を作り、
**ページ圧縮**を掛けます。これは「時点再現(`AS OF`)」に最適化された形です。

```sql
-- 履歴表のインデックスと圧縮を確認する
SELECT i.name                AS インデックス,
       i.type_desc           AS 種類,
       STUFF((SELECT N', ' + COL_NAME(ic.object_id, ic.column_id)
              FROM   sys.index_columns AS ic
              WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id
              ORDER  BY ic.key_ordinal
              FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'') AS キー列,
       p.data_compression_desc AS 圧縮
FROM   sys.indexes    AS i
JOIN   sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
WHERE  i.object_id = OBJECT_ID(N'dbo.ProductsTemporalHistory');
```

### 検索パターンに合わせて足す

| よくあるクエリ | 効くインデックス |
|---|---|
| `AS OF`(ある時点の全体) | 既定の `(ValidTo, ValidFrom)` クラスター化 |
| **特定キーの履歴を追う**(`ALL WHERE ProductId = 1`) | `(ProductId, ValidTo, ValidFrom)` を先頭にした索引 |
| 期間結合(第7.4節) | 同上 |

```sql
-- 「1商品の履歴を追う」を速くする（SYSTEM_VERSIONING = ON のままで作成できる）
CREATE NONCLUSTERED INDEX IX_ProductsTemporalHistory_ProductId
    ON dbo.ProductsTemporalHistory (ProductId, ValidTo, ValidFrom);
```

**効果は必ず測ってから採用します**([18 インデックスと実行プラン](18_indexes_execution_plans.md))。

```sql
SET STATISTICS IO ON;
SELECT * FROM dbo.ProductsTemporal FOR SYSTEM_TIME ALL WHERE ProductId = 1;
SET STATISTICS IO OFF;
-- 論理読み取りが「履歴表のページ数ぶん」から数ページに減れば効いている
-- （具体的な数値は行数・環境により前後する目安）
```

### 大きな履歴表は列ストアにする

履歴表は **追記専用・更新されない・分析的に読まれる**という、
[30 列ストアインデックスとバッチモード](30_columnstore.md) の適用条件をそのまま満たします。
数千万行規模になったら **クラスター化列ストアインデックス(CCI)** を検討します。

```sql
-- クラスター化インデックスの張り替えを伴うので、いったん OFF にしてから行う
ALTER TABLE dbo.ProductsTemporal SET (SYSTEM_VERSIONING = OFF);

DROP INDEX IF EXISTS ix_ProductsTemporalHistory ON dbo.ProductsTemporalHistory;  -- 既定名は環境で異なる
CREATE CLUSTERED COLUMNSTORE INDEX CCI_ProductsTemporalHistory
    ON dbo.ProductsTemporalHistory;

-- 点検索も要るなら行ストアの非クラスター化インデックスを併用できる
CREATE NONCLUSTERED INDEX IX_ProductsTemporalHistory_ProductId
    ON dbo.ProductsTemporalHistory (ProductId, ValidTo, ValidFrom);

ALTER TABLE dbo.ProductsTemporal
SET (SYSTEM_VERSIONING = ON
     (HISTORY_TABLE = dbo.ProductsTemporalHistory, DATA_CONSISTENCY_CHECK = ON));
```

- **利点**: 圧縮率が高く(行ストアのページ圧縮より大幅に小さくなることが多い)、
  期間集計がバッチモードで速い。
- **注意**: 少数行の点検索は行ストアより不利。**行ストア索引を1本併用**するのが定石です。
- 効果の測り方(サイズ):

```sql
SELECT OBJECT_NAME(ps.object_id)                     AS テーブル,
       SUM(ps.row_count)                             AS 行数,
       SUM(ps.reserved_page_count) * 8 / 1024.0      AS 確保MB,
       SUM(ps.used_page_count)     * 8 / 1024.0      AS 使用MB
FROM   sys.dm_db_partition_stats AS ps
WHERE  ps.object_id IN (OBJECT_ID(N'dbo.ProductsTemporal'),
                        OBJECT_ID(N'dbo.ProductsTemporalHistory'))
GROUP  BY ps.object_id;
```

### 履歴表を別ファイルグループに置く

履歴は**参照頻度が低く、量が多い**ので、安価なストレージのファイルグループへ分離できます。
自動生成に任せると既定のファイルグループに作られるため、**履歴表を先に自分で作って**紐付けます。

```sql
-- ※ ファイルグループの追加は管理者権限が必要。学習環境では実行しなくてよい
-- ALTER DATABASE SalesLearning ADD FILEGROUP HistoryFG;
-- ALTER DATABASE SalesLearning ADD FILE (NAME = N'SalesLearning_Hist',
--     FILENAME = N'...\SalesLearning_Hist.ndf') TO FILEGROUP HistoryFG;

CREATE TABLE dbo.ProductsTemporalHistory
(
    ProductId    INT            NOT NULL,     -- ※主キーや制約は付けない
    ProductName  NVARCHAR(100)  NOT NULL,
    CategoryId   INT            NULL,
    UnitPrice    DECIMAL(10, 0) NOT NULL,
    Discontinued BIT            NOT NULL,
    ValidFrom    DATETIME2(7)   NOT NULL,     -- ※GENERATED ALWAYS は付けない
    ValidTo      DATETIME2(7)   NOT NULL
) ON HistoryFG                                -- ← 別ファイルグループ
WITH (DATA_COMPRESSION = PAGE);
```

- **履歴表は現在表と「列名・型・順序」が一致**していなければ紐付けに失敗します。
- 履歴表側には **`GENERATED ALWAYS` を書かない**(付けるとエラー)。
- さらに大規模なら、履歴表を **`ValidTo` でパーティション分割**して
  古いパーティションを切り離すアーカイブ運用もあります([31 パーティショニング](31_partitioning.md))。

## 9. 保持ポリシー — 履歴を自動で捨てる(SQL Server 2017 以降)

放置すると履歴表は**単調に増え続けます**。SQL Server 2017 以降は、
**表ごとに保持期間**を設定して古い行を自動削除できます。

```sql
-- ① データベースレベルで有効化されているか確認する（ここが OFF だと表側の設定は効かない）
SELECT name, is_temporal_history_retention_enabled
FROM   sys.databases
WHERE  name = N'SalesLearning';

ALTER DATABASE SalesLearning SET TEMPORAL_HISTORY_RETENTION ON;

-- ② 表ごとに保持期間を設定する
ALTER TABLE dbo.ProductsTemporal
SET (SYSTEM_VERSIONING = ON
     (HISTORY_TABLE = dbo.ProductsTemporalHistory,
      HISTORY_RETENTION_PERIOD = 6 MONTHS));      -- DAYS / WEEKS / MONTHS / YEARS

-- ③ 設定を確認する
SELECT t.name,
       t.history_retention_period,               -- -1 は INFINITE
       t.history_retention_period_unit_desc
FROM   sys.tables AS t
WHERE  t.object_id = OBJECT_ID(N'dbo.ProductsTemporal');

-- ④ 元に戻す（無期限）
ALTER TABLE dbo.ProductsTemporal
SET (SYSTEM_VERSIONING = ON
     (HISTORY_TABLE = dbo.ProductsTemporalHistory,
      HISTORY_RETENTION_PERIOD = INFINITE));
```

押さえるべき点:

- **2段階**である。**データベースレベルの `TEMPORAL_HISTORY_RETENTION` が ON** で、
  かつ**表に保持期間が設定**されているときだけ削除が走ります。
  新規 DB では既定で ON ですが、**復元・アタッチした DB では OFF になっていることがある**ので
  必ず `sys.databases` で確認してください。「設定したのに減らない」の典型原因です。
- 削除は **バックグラウンドタスクによる非同期**で、**即座には消えません**。
  「今すぐ消したい」なら第10節の手順で `SYSTEM_VERSIONING = OFF` にしてから
  履歴表を `DELETE` します(業務時間外に、バッチサイズを区切って)。
- 削除の単位は `ValidTo` を基準にします。そのため
  **履歴表には `ValidTo` を先頭列とするクラスター化インデックス(または列ストア)が必要**です。
  自前で `(ProductId, …)` 起点のクラスター化インデックスにしていると保持ポリシーが機能しません。
- 保持期間を過ぎた行は消えるので、**`AS OF` で保持期間より前を指定すると結果が欠けます**。
  監査要件の保存年限と矛盾しないか、必ず業務側と合わせること。

## 10. 運用上の制約 — これを知らないと本番で詰まる

`SYSTEM_VERSIONING = ON` の間、この2つの表は**普通のテーブルではありません**。

| やりたいこと | ON のまま | 備考 |
|---|---|---|
| 列の追加(NULL 許容) | ✅ できる | **両方の表に自動で伝播**する(2016 以降) |
| 列の削除・型の変更 | ✅ おおむねできる | 同上。制約付きの変更は失敗することがある |
| 履歴表へのインデックス追加 | ✅ できる | クラスター化の張り替え(列ストア化)は OFF にして行うのが確実 |
| 現在表への `AFTER` トリガー | ✅ できる | **`INSTEAD OF` トリガーは不可**。履歴表にはトリガー自体を作れない |
| **`TRUNCATE TABLE`** | ❌ **不可** | 現在表・履歴表とも。「サポートされない操作」というエラーになる |
| **履歴表への直接 `INSERT`/`UPDATE`/`DELETE`** | ❌ **不可** | 履歴の改竄を防ぐための仕様。**これが監査証跡としての価値の源**でもある |
| ピリオド列への直接の書き込み | ❌ 不可 | `GENERATED ALWAYS` 列のため |
| `DROP TABLE` | ❌ 不可 | 第11節の手順が必要 |
| `ON DELETE CASCADE` / `ON UPDATE CASCADE` の外部キー | ❌ 不可 | 現在表に対して定義できない |
| `IDENTITY` 列・計算列の追加 | ❌ 不可 | |
| ピリオド列の名前変更・`DROP PERIOD` | ❌ 不可 | OFF にしてから |

### 変更したいときの定型手順(必ずこの形で)

```sql
BEGIN TRY
    BEGIN TRAN;

    -- ① いったんバージョン管理を切る（2つの普通のテーブルに戻る）
    ALTER TABLE dbo.ProductsTemporal SET (SYSTEM_VERSIONING = OFF);

    -- ② 作業する。★現在表と履歴表の「両方」に同じ変更を加えること★
    --    例: 列の追加、インデックスの張り替え、古い履歴の削除 など
    ALTER TABLE dbo.ProductsTemporal        ADD 備考 NVARCHAR(200) NULL;
    ALTER TABLE dbo.ProductsTemporalHistory ADD 備考 NVARCHAR(200) NULL;

    -- ③ 戻す（整合性チェックは ON のまま）
    ALTER TABLE dbo.ProductsTemporal
    SET (SYSTEM_VERSIONING = ON
         (HISTORY_TABLE = dbo.ProductsTemporalHistory, DATA_CONSISTENCY_CHECK = ON));

    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;    -- ★ここが重要。OFF のまま放置しない
    THROW;
END CATCH;
```

> ⚠️ **`SYSTEM_VERSIONING = OFF` の間は履歴が記録されません。**
> その間に業務アプリが `UPDATE` すると、**その変更は永久に記録されないまま消えます**。
> さらに、履歴表が普通の表になるので**改竄も可能**です。だから:
>
> - **必ずメンテナンス時間帯に行う**(可能なら該当表への接続を止める)。
> - **上のように `BEGIN TRAN` で囲み、失敗したら必ず `ROLLBACK` して ON に戻す**。
> - 作業後に `sys.tables.temporal_type_desc` を再確認して、**ON に戻ったことを検証する**。
> - 手順を「切る→作業→戻す」の**1スクリプトにまとめる**(戻し忘れが最大の事故)。

## 11. 削除する — 順序を間違えると消せない

**正しい順序**は次の3ステップです。

```sql
-- ① バージョン管理を切る（この時点で2つの独立した普通のテーブルになる）
ALTER TABLE dbo.ProductsTemporal SET (SYSTEM_VERSIONING = OFF);

-- ② ピリオドの定義を外す
ALTER TABLE dbo.ProductsTemporal DROP PERIOD FOR SYSTEM_TIME;

-- ③ 2つの表を削除する（履歴表も忘れずに）
DROP TABLE IF EXISTS dbo.ProductsTemporal;
DROP TABLE IF EXISTS dbo.ProductsTemporalHistory;
```

> ⚠️ **順序を間違えるとこうなります。**
> - **いきなり `DROP TABLE dbo.ProductsTemporal;`**
>   → 「システムバージョン管理テンポラルテーブルではサポートされない操作」というエラーで失敗します。
> - **`SYSTEM_VERSIONING = OFF` にしたあと現在表だけ `DROP`**
>   → 履歴表が**孤児**として残ります。中身は消えないので、
>     気付かないまま容量を食い続けます。**必ず2つセットで片付ける**こと。
> - **`DROP PERIOD` を忘れる**
>   → 表を残して使い続ける場合、ピリオド列は `GENERATED ALWAYS` のままなので
>     **`INSERT` で値を入れられず、列も削除できません**。表を消すだけなら省略してもかまいませんが、
>     **「切る→ピリオドを外す→消す」を定型として覚える**のが安全です。

**テンポラル化をやめて普通の表に戻したい**場合は、②のあとに列を削除します。

```sql
ALTER TABLE dbo.ProductsTemporal DROP CONSTRAINT DF_ProductsTemporal_ValidFrom;
ALTER TABLE dbo.ProductsTemporal DROP CONSTRAINT DF_ProductsTemporal_ValidTo;
ALTER TABLE dbo.ProductsTemporal DROP COLUMN ValidFrom, ValidTo;
```

## 12. 監査ログとの違い — 「誰が」は記録されない

テンポラルテーブルが記録するのは **「いつ」「どの行が」「どんな値だったか」** だけです。
**「誰が」「どのアプリから」「なぜ」は一切記録されません。**
監査要件がある場合は、次のいずれかで補います。

### 補い方A: 変更者の列を自分で持つ

```sql
ALTER TABLE dbo.ProductsTemporal
ADD 変更者 NVARCHAR(128) NOT NULL
    CONSTRAINT DF_ProductsTemporal_変更者 DEFAULT SUSER_SNAME();
```

- `UPDATE` 文で `SET 変更者 = SUSER_SNAME()` を必ず書く運用にすれば、
  **変更後の行に「誰が変えたか」が入り、その行が次の変更で履歴に落ちます**。
- **`DELETE` は苦手**です。削除された行はそのまま履歴に移るので、
  残るのは「**最後に更新した人**」であって「削除した人」ではありません。
  どうしても必要なら、**別トランザクションで**「変更者を自分に書き換える `UPDATE`」→「`DELETE`」の
  2段構えにします(同一トランザクションだと `ValidFrom = ValidTo` の長さ0の行になり、
  `FOR SYSTEM_TIME` から見えなくなる点に注意 — 第5節)。
- 現実的には **論理削除(`Discontinued` のようなフラグ)に寄せる**ほうが素直です。

### 補い方B: SQL Server Audit / 拡張イベントを併用する

- **SQL Server Audit** は「誰がどの文を実行したか」をサーバー/DB レベルで記録します。
  一方、**行の値の遷移は追えません**。
- **役割分担**: 「値の遷移 = テンポラルテーブル」「実行主体と操作 = 監査機能」
  ([25 拡張イベント](25_extended_events.md) / [36 セキュリティ機能](36_security.md))。
- テンポラルテーブルは**履歴表を直接書き換えられない**ため、
  「後から改竄されていない」という点では監査証跡として強い性質を持ちます
  (ただし `SYSTEM_VERSIONING = OFF` にできる権限者は改竄できます。
  `ALTER` 権限の管理が前提です)。

## 13. 履歴設計の選択肢を比較する

| 方式 | 記録される内容 | 「誰が」 | クエリのしやすさ | 保持管理 | 主な用途 / 向かない用途 |
|---|---|---|---|---|---|
| **トリガー方式** | 自分で決めた列(何でも入れられる) | ○ 入れられる | △ 自前 UNION と期間計算が必要 | 自前 | 監査項目を細かく持ちたい。**実装漏れ・一括処理でのすり抜け**に弱い |
| **論理削除 + バージョン列** | 同一表に世代を積む | ○ 入れられる | ✗ 全クエリに「最新のみ」条件が要る | 自前 | 世代管理が業務要件そのもの(契約の版など)。汎用の履歴には不向き |
| **変更追跡 (Change Tracking)** | **変更があった事実のみ**(主キーと変更列) | ✗ | ○ 専用関数 | 自動(保持期間設定) | **同期・差分連携**。値の履歴は残らないので時点再現は不可 |
| **CDC (変更データキャプチャ)** | 変更前後の**全列の値**をログから非同期取得 | ✗ | △ 専用関数と LSN の理解が要る | 自動(既定3日) | **ETL・データ連携**。SQL Server Agent が必要。長期保存の監査用ではない |
| **テンポラルテーブル** | **全列の値の遷移**(自動・トランザクション整合) | ✗(列を足せば可) | ◎ **標準 SQL の `FOR SYSTEM_TIME`** | **保持ポリシー(2017+)** | **時点再現・値の変遷追跡**。高頻度更新の巨大表には要注意 |

判断の目安:

- **「あの日の状態を丸ごと見たい」** → テンポラルテーブル。一択に近い。
- **「差分を他システムへ流したい」** → CDC / 変更追跡。テンポラルは連携用ではない。
- **「誰が・どの端末から・なぜ を残す規程がある」** → テンポラル + 変更者列、または監査機能の併用。
- **「更新が秒間数千行あるトランザクション表」** → テンポラルにすると**履歴が爆発**する。
  必要な列だけを持つ別表に絞る、更新頻度の低いマスタだけを対象にする、
  保持ポリシーで短く切る、などの設計が要ります。

### 何をテンポラルにするか(設計の勘所)

- **向いている**: 商品マスタの単価、顧客の与信枠・住所、社員の所属・給与、料金表、
  設定値 — つまり**更新頻度が低く、値の変遷に業務的な意味があるマスタ**。
- **向いていない**: 注文明細のような**追記中心のトランザクション表**
  (そもそも更新されないので履歴が生まれない)、
  ログ表、**巨大な列(`NVARCHAR(MAX)` や画像)を含む表**(1回の更新で行全体が複製されるため)。
- **列の切り出し**: 頻繁に変わる列とめったに変わらない列が混在するなら、
  **変わる列だけを別表に切り出してテンポラル化**すると履歴量を劇的に減らせます
  ([35 データモデリングと物理設計](35_data_modeling.md))。

## 14. 調査に使うカタログビュー・DMV まとめ

| 目的 | 使うもの | 見るポイント |
|---|---|---|
| テンポラル表の一覧 | `sys.tables` | `temporal_type` / `temporal_type_desc` / `history_table_id` |
| ピリオドの定義 | `sys.periods` | `start_column_id` / `end_column_id` |
| ピリオド列・隠し列 | `sys.columns` | `generated_always_type_desc` / `is_hidden` |
| 保持ポリシー | `sys.tables` / `sys.databases` | `history_retention_period` / `is_temporal_history_retention_enabled` |
| 履歴表のサイズ | `sys.dm_db_partition_stats` | `row_count` / `used_page_count` |
| 履歴表のインデックス | `sys.indexes` / `sys.index_columns` / `sys.partitions` | `type_desc` / キー列の順序 / `data_compression_desc` |
| クエリの実測 | `SET STATISTICS IO/TIME`、実行プラン | 履歴表をスキャンしていないか |

## よくあるつまずき

- **`AS OF` に JST の時刻を渡して9時間ずれる** → ピリオド列は **UTC**。
  `SYSUTCDATETIME()` か `AT TIME ZONE` で変換してから渡す。
- **変更の瞬間ちょうどを `AS OF` して「新しい行」が返る** → 期間は **`[From, To)` の半開区間**。
  変更直前が欲しいなら、その時刻より前を指定する。
- **`CONTAINED IN` で現在の行が返らない** → 現在行の `ValidTo` は 9999-12-31 なので、
  期間内に「終了」していない。仕様どおりの動作。
- **`FROM … TO` で境界ちょうどの行が落ちる** → 両端とも含まない。終端を含めたいなら `BETWEEN … AND`。
- **同一トランザクションで2回更新したら履歴が出ない** → `ValidFrom = ValidTo` の長さ0の行になり、
  `FOR SYSTEM_TIME` からは見えない。実験は**トランザクションを分けて** `WAITFOR DELAY` を挟む。
- **`AS OF` に列を書こうとしてエラー** → 定数・変数・パラメータのみ。
  行ごとに時点が違うなら **`ALL` + `>= ValidFrom AND < ValidTo`** の結合で書く。
- **`TRUNCATE` / `DROP TABLE` ができない** → `SYSTEM_VERSIONING = OFF` にしてから。
- **`SYSTEM_VERSIONING = OFF` のまま戻し忘れる** → その間の変更は**永久に記録されない**。
  `BEGIN TRAN` + `TRY…CATCH` で囲み、作業後に `sys.tables` で ON を検証する。
- **現在表だけ `DROP` して履歴表が孤児になる** → 2つセットで片付ける。
- **保持ポリシーを設定したのに履歴が減らない** → データベースレベルの
  `TEMPORAL_HISTORY_RETENTION` が OFF、または履歴表のクラスター化インデックスが
  `ValidTo` 起点でない。削除は**非同期**で即時ではない点も忘れずに。
- **「誰が変えたか」を探して見つからない** → テンポラルは記録しない。列を足すか監査機能を併用。
- **履歴表が業務表より何倍も大きくなる** → 空更新を繰り返すバッチ、巨大列の同梱、
  高頻度更新表の選定ミスを疑う。列ストア化・列の切り出し・保持ポリシーで対処。

## この章のまとめ

- テンポラルテーブルは **現在表 + 履歴表のペア**。`UPDATE`/`DELETE` の直前の行が
  **同一トランザクションで**履歴表に移る。アプリの改修は不要(**SQL Server 2016 以降**)。
- ピリオド列は **`datetime2` / `NOT NULL` / `GENERATED ALWAYS`**、値は **UTC**、
  期間は **`[ValidFrom, ValidTo)` の半開区間**。`HIDDEN` で `SELECT *` から隠せる。
- 既存表への後付けは **既定値の指定が必須**。`ValidTo` は `datetime2` の最大値、
  `ValidFrom` は「いつから存在したことにするか」という設計判断。
- **`FOR SYSTEM_TIME` は5つ**。`AS OF`(時点)/`FROM…TO`(両端含まない)/
  `BETWEEN…AND`(終端だけ含む)/`CONTAINED IN`(両端含む・完全に収まった行だけ)/`ALL`。
  **述語で覚える**のが確実。時点再現・変更履歴・2時点差分・行ごとの期間結合が実務の4パターン。
- 履歴表は既定で **`(ValidTo, ValidFrom)` クラスター化 + ページ圧縮**。
  キー別の履歴検索には `(キー, ValidTo, ValidFrom)` を足し、
  巨大化したら **列ストア**、さらに **別ファイルグループ / パーティション**へ。
- **保持ポリシー(2017+)** は「DB レベルの `TEMPORAL_HISTORY_RETENTION`」+
  「表の `HISTORY_RETENTION_PERIOD`」の**2段階**。削除は非同期。
- 運用の要は **`SYSTEM_VERSIONING = OFF` → 作業(両方の表に) → ON** の定型と、
  削除の **`OFF` → `DROP PERIOD` → 両表 `DROP`** という**順序**。
  OFF の間は履歴が記録されないので、必ずトランザクションで囲んで戻す。
- **「誰が」は記録されない**。変更者列を足すか、監査機能と役割分担する。
- 用途で選ぶ: **時点再現=テンポラル / 差分連携=CDC・変更追跡 / 実行主体の記録=監査**。

➡ 演習: [exercises/34_temporal_tables.md](../exercises/34_temporal_tables.md)
