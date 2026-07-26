# 14 APPLY (CROSS APPLY / OUTER APPLY)

> **このトピックのゴール**: `JOIN` では書けない「**右辺が左辺の各行の値を参照する**」結合を
> `CROSS APPLY` / `OUTER APPLY` で書けるようになる。実務で最頻出の
> **グループごとの上位 N 件(Top-N per group)** を APPLY で書け、
> ウィンドウ関数版・相関サブクエリ版と使い分けられるようになる。
> さらに `CROSS APPLY (VALUES ...)` による行展開・式の名前付け、
> テーブル値関数や `STRING_SPLIT` との組み合わせまで扱える。
>
> **前提**: [13 データ操作 (INSERT/UPDATE/DELETE/MERGE)](13_dml.md) までを済ませ、
> `JOIN`([04](04_joins.md))・サブクエリ([06](06_subqueries.md))・
> ウィンドウ関数([08](08_window_functions.md))を書けること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。
明細金額は一貫して `Quantity * UnitPrice * (1 - Discount)` で計算します。

> `APPLY` は SQL Server 2005 以降で使えます。

## 1. APPLY とは — JOIN の「できないこと」を埋める演算子

`APPLY` は `FROM` 句に書く **結合演算子** です。`JOIN` と見た目は似ていますが、
決定的に違う一点があります。

> **APPLY の右辺は、左辺の「その行」の列値を参照できる。**

`JOIN` にはこれができません。`JOIN` の右辺(テーブルや派生テーブル)は
**左辺とは独立に評価される**ものとして扱われ、そのあとに `ON` 条件で突き合わせるだけだからです。
`ON` は「できあがった2つの表をどう対応づけるか」を書く場所であって、
「右辺の中身を左辺ごとに変える」ための仕組みではありません。

### 実際に困る場面

「**顧客ごとに、最新の注文を3件だけ**」を取りたいとします。素直に書くとこうなりますが、
これは **実行できません**。

```sql
-- ✗ エラー: 派生テーブルの中から外側の c.CustomerId は参照できない
--    Msg 4104 "The multi-part identifier "c.CustomerId" could not be bound."
SELECT c.CustomerName, x.OrderId, x.OrderDate
FROM   dbo.Customers AS c
JOIN   (SELECT TOP (3) o.OrderId, o.OrderDate
        FROM   dbo.Orders AS o
        WHERE  o.CustomerId = c.CustomerId       -- ← ここで c が見えない
        ORDER  BY o.OrderDate DESC) AS x
       ON 1 = 1;
```

- 派生テーブル `x` は「単独で成立する1つの問い合わせ」でなければならず、
  **同じ階層にいる `c` の列を参照できません**。
- かといって `TOP (3)` を外に出しても「全体で3件」になってしまい、「顧客ごとに3件」にはなりません。

`JOIN` を `CROSS APPLY` に変えるだけで、この制約が外れます。

```sql
-- ○ CROSS APPLY なら右辺から左辺の c.CustomerId を参照できる
SELECT c.CustomerName, x.OrderId, x.OrderDate
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId          -- ← 参照できる
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerName, x.OrderDate DESC;
```

### 動作イメージ

`APPLY` は概念的に、次のように動きます。

1. 左辺(`dbo.Customers`)から **1行取り出す**。
2. その行の値を右辺の式に **当てはめて(apply して)** 右辺を評価する。
3. 右辺が返した行それぞれと、左辺の1行を **横につないで** 出力する。
4. 左辺の次の行へ。これを全行分くり返す。

つまり `APPLY` は「**行ごとに評価される表**」を作る仕組みです。
`JOIN` が「表 × 表」なのに対し、`APPLY` は「行 → 表」という関係だと覚えてください。

> ⚠️ 方向は **左 → 右の一方向** です。右辺から左辺は参照できますが、
> 左辺から右辺の列を参照することはできません(`FROM` に書いた順序が意味を持ちます)。

## 2. CROSS APPLY — 右辺が0行なら左行も消える

`CROSS APPLY` は、右辺が **1行以上返した左行だけ** を出力します。
右辺が0行なら、その左行は結果から消えます。**`INNER JOIN` 的**なふるまいです。

```sql
-- 各顧客の「最新の注文1件」
SELECT c.CustomerId,
       c.CustomerName,
       x.OrderId    AS 最新注文Id,
       x.OrderDate  AS 最新注文日
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (1) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerId;
```

- 右辺には **必ず別名(`AS x`)が必要** です。省略すると構文エラーになります。
- 右辺の列は `x.OrderId` のように、その別名で参照します。
- **注文が1件も無い顧客11(ラムダソフト)は結果に出てきません**。
  右辺が0行を返すため、`CROSS APPLY` では左行ごと落ちるからです。

> ⚠️ `TOP` を使うときは **必ず `ORDER BY` を書く** こと。
> `ORDER BY` の無い `TOP (1)` は「どの行が返るか不定」で、実行のたびに結果が変わり得ます。
> さらに、並べ替えキーが同値になり得る場合(同じ日に複数注文など)は、
> `ORDER BY o.OrderDate DESC, o.OrderId DESC` のように **一意になるまでキーを足す** のが定石です。

## 3. OUTER APPLY — 右辺が0行でも左行を残す

`OUTER APPLY` は、右辺が0行でも **左行を残し、右辺の列をすべて NULL** にします。
**`LEFT JOIN` 的**なふるまいです。

```sql
-- 注文が無い顧客も残す
SELECT c.CustomerId,
       c.CustomerName,
       x.OrderId    AS 最新注文Id,
       x.OrderDate  AS 最新注文日
FROM   dbo.Customers AS c
OUTER  APPLY (SELECT TOP (1) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerId;
```

- **顧客11(ラムダソフト)が `最新注文Id = NULL` / `最新注文日 = NULL` で出てきます**。
- 「マスタの全行を必ず残したい」場面ではこちらを使います。実務では
  一覧画面のように「対象が無くても行は出す」要件が多く、`OUTER APPLY` の出番はかなり多いです。

対応関係を整理しておきます。

| 目的 | 相関なし(普通の結合) | 相関あり(右辺が左辺を参照) |
|---|---|---|
| 一致した行だけ残す | `INNER JOIN` | **`CROSS APPLY`** |
| 左辺の全行を残す | `LEFT JOIN` | **`OUTER APPLY`** |

> 右辺が左辺をまったく参照しない場合、`CROSS APPLY` は `CROSS JOIN` と同じ結果になります。
> つまり `APPLY` は「相関できる `CROSS JOIN`」だと考えると腑に落ちます。

## 4. 最頻出パターン — グループごとの上位 N 件 (Top-N per group)

APPLY の使いどころとして **圧倒的に多い** のがこれです。
「顧客ごとの最新注文3件」「カテゴリごとの高額商品2件」「部門ごとの給与トップ3」など、
実務要件として頻出します。

### 顧客ごとの最新注文3件

```sql
SELECT c.CustomerId,
       c.CustomerName,
       x.OrderId,
       x.OrderDate
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerId, x.OrderDate DESC;
```

- 顧客1(アルファ商事)は注文が4件(1001/1004/1011/1020)ありますが、**新しい3件だけ**が出ます。
- 注文が2件しかない顧客はそのまま2行、1件なら1行になります。
  `TOP (3)` は「3件未満でもエラーにならない」ので、そのまま書けます。

### カテゴリごとの高額商品2件

```sql
SELECT cat.CategoryName,
       x.ProductName,
       x.UnitPrice
FROM   dbo.Categories AS cat
CROSS  APPLY (SELECT TOP (2) p.ProductName, p.UnitPrice
              FROM   dbo.Products AS p
              WHERE  p.CategoryId = cat.CategoryId
              ORDER  BY p.UnitPrice DESC, p.ProductId) AS x
ORDER  BY cat.CategoryName, x.UnitPrice DESC;
```

- 電化製品なら ノートPC(128000)・4Kモニター(42000) が返ります。
- `CategoryId` が NULL の商品(高級万年筆・ノベルティグッズ)は、
  どのカテゴリの右辺条件にも一致しないので自然に除外されます。

### 同順位も含めたい場合 — TOP (n) WITH TIES

「2位が同額で2つある」ようなときに両方欲しいなら `WITH TIES` を付けます。

```sql
SELECT cat.CategoryName, x.ProductName, x.UnitPrice
FROM   dbo.Categories AS cat
CROSS  APPLY (SELECT TOP (2) WITH TIES p.ProductName, p.UnitPrice
              FROM   dbo.Products AS p
              WHERE  p.CategoryId = cat.CategoryId
              ORDER  BY p.UnitPrice DESC) AS x         -- ORDER BY のキーで同値判定
ORDER  BY cat.CategoryName, x.UnitPrice DESC;
```

- `WITH TIES` は **`ORDER BY` が必須** で、その `ORDER BY` のキーが同値の行を追加で返します。
- ウィンドウ関数でいう `RANK()` に相当する挙動です。

## 5. ROW_NUMBER 版(8章)との比較と使い分け

同じ Top-N per group は、[08 ウィンドウ関数](08_window_functions.md) の
`ROW_NUMBER()` でも書けます。両方書けるようにしておき、**場面で選べる**のが理想です。

```sql
-- ROW_NUMBER 版: カテゴリごとの高額商品2件
WITH 順位付き AS (
    SELECT p.CategoryId,
           p.ProductName,
           p.UnitPrice,
           ROW_NUMBER() OVER (PARTITION BY p.CategoryId
                              ORDER BY p.UnitPrice DESC, p.ProductId) AS 順位
    FROM   dbo.Products AS p
    WHERE  p.CategoryId IS NOT NULL
)
SELECT cat.CategoryName, r.ProductName, r.UnitPrice
FROM   順位付き AS r
JOIN   dbo.Categories AS cat ON cat.CategoryId = r.CategoryId
WHERE  r.順位 <= 2
ORDER  BY cat.CategoryName, r.順位;
```

```sql
-- APPLY 版(4章の再掲): 同じ結果
SELECT cat.CategoryName, x.ProductName, x.UnitPrice
FROM   dbo.Categories AS cat
CROSS  APPLY (SELECT TOP (2) p.ProductName, p.UnitPrice
              FROM   dbo.Products AS p
              WHERE  p.CategoryId = cat.CategoryId
              ORDER  BY p.UnitPrice DESC, p.ProductId) AS x
ORDER  BY cat.CategoryName, x.UnitPrice DESC;
```

### 書き方の違い

| 観点 | `APPLY` 版 | `ROW_NUMBER` 版 |
|---|---|---|
| 構造 | 親テーブルを起点に、子を行ごとに取りに行く | 子テーブル全体に番号を振り、あとから絞る |
| CTE / サブクエリ | **不要**(そのまま `FROM` に書ける) | **必要**(`WHERE` でウィンドウ関数は使えない) |
| 親の全行を残す | `OUTER APPLY` にするだけ | 親と `LEFT JOIN` する1段が別途必要 |
| N を変数にする | `TOP (@N)` と書ける | `順位 <= @N` と書ける(どちらも可) |
| 同順位を含める | `TOP (n) WITH TIES` | `RANK()` / `DENSE_RANK()` に変える |
| 右辺の自由度 | 集計・別の結合・関数呼び出しなど何でも書ける | ランキング対象の1つの問い合わせに限られる |

### 使い分けの目安

- **親(グループ)テーブルが独立して存在し、その全行を残したい** → `OUTER APPLY` が素直。
  「注文が無い顧客も一覧に出す」のような要件は APPLY のほうが圧倒的に書きやすいです。
- **子テーブルだけで完結する**(親テーブルを結合する必要がない) → `ROW_NUMBER` が素直。
- **性能面**: ざっくり言うと、
  - 親が少なく、N が小さく、子側に `(親キー, 並べ替えキー)` のインデックスがある
    → **APPLY が有利**なことが多い(親の行数だけ index seek で数行取って終わる)。
  - 親が非常に多い、または N が大きい → **`ROW_NUMBER` が有利**なことが多い
    (子を1回スキャンして番号を振るほうが総コストが低い)。
  - ただしこれは目安で、**必ず実行プランで確認**してください([18 インデックスと実行プラン](18_indexes_execution_plans.md))。

## 6. 相関サブクエリ(6章)との比較 — 複数列を返せるのが APPLY の強み

[06 サブクエリ](06_subqueries.md) の **相関サブクエリ** も「外側の行を参照する」点では APPLY と同じです。
違いは **返せる列数**。スカラー相関サブクエリは **1行1列** しか返せません。

```sql
-- 相関サブクエリ版: 欲しい列の数だけサブクエリを書くはめになる
SELECT c.CustomerName,
       (SELECT MAX(o.OrderDate) FROM dbo.Orders AS o WHERE o.CustomerId = c.CustomerId) AS 最終注文日,
       (SELECT MIN(o.OrderDate) FROM dbo.Orders AS o WHERE o.CustomerId = c.CustomerId) AS 初回注文日,
       (SELECT COUNT(*)         FROM dbo.Orders AS o WHERE o.CustomerId = c.CustomerId) AS 注文件数
FROM   dbo.Customers AS c
ORDER  BY c.CustomerId;
```

```sql
-- APPLY 版: 右辺1つで複数列をまとめて返せる
SELECT c.CustomerName,
       s.最終注文日,
       s.初回注文日,
       s.注文件数
FROM   dbo.Customers AS c
OUTER  APPLY (SELECT MAX(o.OrderDate) AS 最終注文日,
                     MIN(o.OrderDate) AS 初回注文日,
                     COUNT(*)         AS 注文件数
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId) AS s
ORDER  BY c.CustomerId;
```

- 同じ条件(`o.CustomerId = c.CustomerId`)を **3回書かなくてよい**。
  条件を直すときに1か所だけ直せばよく、書き間違いも減ります。
- **論理が1か所にまとまる**ので読みやすい。集計を1つ足したいときも右辺に1行足すだけです。

> ⚠️ この例のように右辺が **`GROUP BY` の無い集約だけ** の場合、右辺は必ず1行を返します
> (該当データが無くても `MAX` は NULL、`COUNT(*)` は 0 の1行)。
> したがって `CROSS APPLY` と `OUTER APPLY` の結果は同じになり、
> 注文が無い顧客11も `注文件数 = 0`(NULL ではない)で出てきます。
> 逆に右辺が `TOP` や `WHERE` で0行になり得るときだけ、両者の差が現れます。

## 7. CROSS APPLY (VALUES ...) — 行展開と UNPIVOT の代替

[10 PIVOT / UNPIVOT](10_pivot_unpivot.md) の末尾で、`UNPIVOT` の別解として
`CROSS APPLY (VALUES ...)` を紹介しました。**なぜあれが動くのか** を、ここで回収します。

`VALUES (...), (...)` は **テーブル値コンストラクタ**、つまり「その場で作る小さな表」です。
これを `APPLY` の右辺に置くと、**左辺の各行の列値を使って表を組み立てられます**。
「1行を複数行に展開する」処理が、これだけで書けるわけです。

```sql
-- 注文1001の各明細を「単価 / 数量 / 金額」の3行に展開する
SELECT od.OrderId,
       od.ProductId,
       v.項目,
       v.値
FROM   dbo.OrderDetails AS od
CROSS  APPLY (VALUES (N'単価', CAST(od.UnitPrice AS DECIMAL(12, 2))),
                     (N'数量', CAST(od.Quantity  AS DECIMAL(12, 2))),
                     (N'金額', CAST(od.Quantity * od.UnitPrice * (1 - od.Discount) AS DECIMAL(12, 2)))
             ) AS v(項目, 値)
WHERE  od.OrderId = 1001
ORDER  BY od.ProductId, v.項目;
```

- 右辺の別名は `AS v(項目, 値)` のように **表名と列名をまとめて** 付けます。
  `VALUES` は列名を持たないので、この形が必須です。
- 左辺の1行につき3行が生成されるので、結果は「明細数 × 3」行になります。
- `VALUES` の同じ列に入る値は **型が互換である必要** があります
  (混在すると型の優先順位で暗黙変換されます)。ここでは意図を明確にするため `CAST` で揃えています。

### なぜ UNPIVOT より柔軟なのか

10章で挙げた `UNPIVOT` の弱点が、そのまま `CROSS APPLY (VALUES ...)` の利点になります。

- **NULL の行が落ちない**。`UNPIVOT` は NULL 値の行を仕様として除去しますが、
  `VALUES` は書いた値をそのまま行にするだけなので、NULL もそのまま1行として残ります。
- **ラベルを自由に付けられる**。`UNPIVOT` のラベルは「元の列名」に固定されますが、
  `VALUES` では `N'単価'` のように **表示用の日本語**を直接書けます。
- **値に式を書ける**。`UNPIVOT` は既存の列しか畳み込めませんが、
  `VALUES` には `od.Quantity * od.UnitPrice * (1 - od.Discount)` のような **計算式**を置けます。
- **列ごとに違う変換ができる**。上の例のように、列ごとに別々の `CAST` を掛けられます。

つまり 10章の「別解」は思いつきではなく、**APPLY が右辺で左辺の列を使えるから成り立つ**書き方でした。

### もう1つの定番 — 式に名前を付けて使い回す

[01 SELECT の基礎](01_select_basics.md) で見たとおり、`SELECT` で付けた別名は
同じ `SELECT` の中の他の式からは参照できません。そのため、こういう重複が起きがちです。

```sql
-- ✗ 冗長: 同じ式を3回書いている(直すときに直し漏れが起きる)
SELECT od.OrderId,
       od.ProductId,
       od.Quantity * od.UnitPrice * (1 - od.Discount)         AS 金額,
       od.Quantity * od.UnitPrice * (1 - od.Discount) * 0.1   AS 消費税,
       od.Quantity * od.UnitPrice * (1 - od.Discount) * 1.1   AS 税込金額
FROM   dbo.OrderDetails AS od;
```

`CROSS APPLY (VALUES ...)` で **1行1列の表**を作れば、その式に名前を付けて使い回せます。

```sql
-- ○ 式は1か所。以降は m.金額 として参照できる
SELECT od.OrderId,
       od.ProductId,
       m.金額,
       m.金額 * 0.1 AS 消費税,
       m.金額 * 1.1 AS 税込金額
FROM   dbo.OrderDetails AS od
CROSS  APPLY (VALUES (od.Quantity * od.UnitPrice * (1 - od.Discount))) AS m(金額)
ORDER  BY od.OrderId, od.ProductId;
```

- 計算ロジックが1か所に集約され、修正漏れが起きません。
- `CROSS APPLY (VALUES (...))` は必ず1行を返すので、行数は変わりません。
- CTE で包むより短く、`SELECT` の途中に差し込めるのが利点です。

## 8. APPLY は数珠つなぎにできる

`APPLY` は左から順に評価されるため、**前の `APPLY` の結果を次の `APPLY` から参照できます**。
段階的にデータを掘っていく処理が素直に書けます。

```sql
-- 顧客ごとの最新注文3件と、その注文の明細合計金額
SELECT c.CustomerName,
       x.OrderId,
       x.OrderDate,
       t.合計金額
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
CROSS  APPLY (SELECT SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 合計金額
              FROM   dbo.OrderDetails AS od
              WHERE  od.OrderId = x.OrderId) AS t          -- ← 前の APPLY の x を参照
ORDER  BY c.CustomerName, x.OrderDate DESC;
```

- 2つ目の `APPLY` は `c` も `x` も参照できます。**書いた順序より前のものは全部見える**、と覚えてください。
- 逆に、1つ目の `APPLY` から `t` を参照することは **できません**。

## 9. テーブル値関数 (TVF) との組み合わせ

`APPLY` のもう1つの主役が **テーブル値関数(Table-Valued Function, TVF)** です。
TVF は「表を返す関数」で、引数に **左辺の列を渡して行ごとに呼び出す** には `APPLY` が必要です
(`FROM A, dbo.fn(A.col)` のようなカンマ結合では `A.col` を渡せません)。

関数の作り方の詳細は [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) で扱うので、
ここでは「APPLY と組み合わせるとこう書ける」という感触だけつかんでください。

```sql
-- 指定顧客の直近 N 件の注文を返すインライン TVF
CREATE FUNCTION dbo.fn_顧客直近注文 (@CustomerId INT, @N INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (@N) o.OrderId, o.OrderDate, o.ShipDate
    FROM   dbo.Orders AS o
    WHERE  o.CustomerId = @CustomerId
    ORDER  BY o.OrderDate DESC, o.OrderId DESC;
GO

-- 全顧客に対して行ごとに適用する
SELECT c.CustomerId,
       c.CustomerName,
       f.OrderId,
       f.OrderDate
FROM   dbo.Customers AS c
CROSS  APPLY dbo.fn_顧客直近注文(c.CustomerId, 2) AS f    -- ← 左辺の列を引数に渡せる
ORDER  BY c.CustomerId, f.OrderDate DESC;
GO

-- 後片付け(サンプルDBを散らかさない)
DROP FUNCTION dbo.fn_顧客直近注文;
GO
```

- 名前を付けた TVF にすることで、**同じ「直近N件」ロジックを複数のクエリで再利用**できます。
- 上のような `RETURNS TABLE ... RETURN (SELECT ...)` の形を **インライン TVF** と呼びます。
  クエリに展開されて最適化されるため性能が良く、`APPLY` と組むならこちらを使ってください。
- 逆に `RETURNS @t TABLE (...) BEGIN ... END` の **複数ステートメント TVF** は
  ブラックボックスとして扱われ、行数見積りが外れて非常に遅くなることがあります。
  `APPLY` の右辺に置くのは避けるのが無難です(詳細は [16章](16_stored_procedures.md))。

## 10. STRING_SPLIT との組み合わせ — カンマ区切りを行に展開する

`STRING_SPLIT` は **区切り文字で文字列を分割して行を返す** 組み込み TVF です。
これも「行ごとに違う文字列を渡す」ので `APPLY` の出番になります。

> `STRING_SPLIT` は **SQL Server 2016 以降**(データベース互換性レベル 130 以上)で使えます。
> 返る列は `value` の1列です。順序を表す `ordinal` 列は **SQL Server 2022 以降**の追加引数が必要です。

まず、値が固定なら普通の `JOIN` で足ります(相関していないので `APPLY` は不要)。

```sql
-- 変数で渡した「東京,大阪,福岡」に該当する顧客を抽出
DECLARE @都市リスト NVARCHAR(200) = N'東京,大阪,福岡';

SELECT c.CustomerId, c.CustomerName, c.City
FROM   dbo.Customers AS c
JOIN   STRING_SPLIT(@都市リスト, N',') AS s ON s.value = c.City
ORDER  BY c.City, c.CustomerId;
```

`APPLY` が要るのは、**分割したい文字列が行ごとに違う**ときです。

```sql
-- ① まず注文ごとに商品IDをカンマ区切りにまとめる(STRING_AGG は SQL Server 2017 以降)
-- ② それを CROSS APPLY STRING_SPLIT で行に戻す(往復させて挙動を確認する)
WITH 注文商品 AS (
    SELECT od.OrderId,
           STRING_AGG(CAST(od.ProductId AS NVARCHAR(10)), N',') AS 商品IDリスト
    FROM   dbo.OrderDetails AS od
    GROUP  BY od.OrderId
)
SELECT t.OrderId,
       t.商品IDリスト,
       CAST(s.value AS INT) AS 商品Id
FROM   注文商品 AS t
CROSS  APPLY STRING_SPLIT(t.商品IDリスト, N',') AS s     -- ← 行ごとに違う文字列を渡す
ORDER  BY t.OrderId, CAST(s.value AS INT);
```

- `STRING_SPLIT(t.商品IDリスト, N',')` の第1引数が **左辺の列** なので、`APPLY` が必須です。
  これを `JOIN` で書こうとすると、1章と同じ「`t` が見えない」エラーになります。
- `value` は `NVARCHAR` なので、数値として使うなら `CAST` してください。
- 分割結果は **順序が保証されません**(2022 の `ordinal` を使わない限り)。
  「3番目の要素」を取りたいような用途には使わないこと。

> ⚠️ そもそも「カンマ区切りで複数値を1列に詰める」のは、正規化されていない設計です。
> 外部システムから渡ってきた文字列をほどく、といった場面で使う道具であって、
> 自分の設計で積極的に採用するものではありません。

## 11. 落とし穴 — APPLY は「行ごとに実行される」

`APPLY` は強力ですが、その正体は **相関ネステッドループ** です。
**左辺の行数だけ右辺が評価される**ため、左辺が大きいとコストがそのまま行数倍になります。

```sql
-- 左辺が大きいほど右辺の実行回数が増える
SELECT c.CustomerId, x.OrderId
FROM   dbo.Customers AS c            -- 左辺が12行なら右辺は12回
CROSS  APPLY (SELECT TOP (3) o.OrderId
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC) AS x;
```

実務で気をつけるポイントは次のとおりです。

- **左辺を先に絞る**。`WHERE` で左辺の行数を減らしてから `APPLY` する
  (あるいは絞り込み済みの CTE を左辺にする)だけで、実行回数が劇的に減ります。
- **右辺の相関列にインデックスを張る**。上の例なら `Orders(CustomerId, OrderDate DESC)` の
  ような複合インデックスがあると、右辺は毎回わずかな行の seek で済みます。
  逆にインデックスが無いと、**左辺の行数だけテーブルスキャンが走る**最悪のパターンになります。
- **右辺に重い処理を置かない**。複数ステートメント TVF やスカラー UDF を右辺で呼ぶと、
  行ごとの呼び出しコストが積み上がります。
- **単純な集計なら `GROUP BY` + `JOIN` のほうが速いこともある**。
  「全顧客の注文合計」のように全行を集計するなら、
  1回の `GROUP BY` で作った表と結合するほうが有利です。APPLY が輝くのは
  「**各グループから少数の行だけ**」を取り出すときです。

いずれにせよ、**推測ではなく実行プランで判断**してください。
実行プランの読み方とインデックス設計は [18 インデックスと実行プラン](18_indexes_execution_plans.md) で扱います。

## よくあるつまずき

- **`The multi-part identifier "c.CustomerId" could not be bound."`**
  → `JOIN` の派生テーブルから外側の列を参照している。`JOIN ... ON` を `CROSS APPLY` に変える。
- **右辺に別名を付け忘れて構文エラー** → `APPLY (SELECT ...) AS x` の `AS x` は必須。
  `VALUES` の場合は列名も要る: `AS v(項目, 値)`。
- **注文の無い顧客が消える** → `CROSS APPLY` は右辺0行で左行も落とす。`OUTER APPLY` にする。
- **`OUTER APPLY` にしたのに NULL 行が出ない** → 右辺が `GROUP BY` 無しの集約だけだと
  必ず1行返るため、`CROSS` / `OUTER` の差が出ない(`COUNT` は 0 が返る)。
- **結果が実行のたびに変わる** → 右辺の `TOP` に `ORDER BY` が無い、または並べ替えキーに
  同値がある。一意になるまでキーを足す(`..., o.OrderId DESC`)。
- **「顧客ごとに3件」のつもりが全体で3件** → `TOP` が外側に付いている。`TOP` は APPLY の**右辺**に置く。
- **`CROSS APPLY (VALUES ...)` で型エラー** → 同じ列に入る値の型が非互換。`CAST` で揃える。
- **`STRING_SPLIT` が「オブジェクトが見つかりません」** → 2016 未満、または
  データベース互換性レベルが 130 未満。
- **大量データで極端に遅い** → 右辺の相関列にインデックスが無い、または左辺を絞れていない。
  実行プランを見て確認する(18章)。

## この章のまとめ

- `APPLY` の本質は「**右辺が左辺の各行の値を参照できる**」こと。
  `JOIN` の派生テーブルは左辺を参照できないので、その制約を外すための演算子。
- **`CROSS APPLY` は `INNER JOIN` 的**(右辺0行なら左行も消える)、
  **`OUTER APPLY` は `LEFT JOIN` 的**(右辺0行でも左行を残し NULL 埋め)。
- 最頻出は **グループごとの上位 N 件**。右辺に `TOP (n) ... ORDER BY` を書くだけで書ける。
  `ORDER BY` は必須、キーは一意になるまで足す。同順位も欲しいなら `TOP (n) WITH TIES`。
- **`ROW_NUMBER` 版との使い分け**: 親テーブルの全行を残したいなら `OUTER APPLY`、
  子テーブルだけで完結するなら `ROW_NUMBER`。性能は実行プランで判断する。
- **相関サブクエリとの違いは列数**。APPLY は右辺1つで **複数列** を返せるので、
  同じ相関条件を何度も書かずに済む。
- **`CROSS APPLY (VALUES ...)`** は 1行 → 複数行の展開(柔軟な `UNPIVOT` 代替)にも、
  1行 → 1行の「式に名前を付ける」用途にも使える万能パターン。
- **TVF / `STRING_SPLIT`** のように「左辺の値を引数に取る表」を呼ぶには `APPLY` が必須。
- 実体は **相関ネステッドループ**。左辺を絞り、右辺の相関列にインデックスを張ること。

➡ 演習: [exercises/14_apply.md](../exercises/14_apply.md)
