# 10 PIVOT / UNPIVOT

> **このトピックのゴール**: 縦持ち(1行1明細)のデータを **クロス集計表**(行×列のマトリクス)に
> 変換できるようになる。`PIVOT` 演算子と、より柔軟な `SUM(CASE WHEN ...)` の
> 両方でクロス集計を書け、`UNPIVOT`(または `CASE`)で列→行の変換もできるようになる。
>
> **前提**: [09 集合演算](09_set_operations.md) までを済ませ、
> `GROUP BY` と集約関数(`SUM`/`COUNT` など)を使えること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。
明細金額は一貫して `Quantity * UnitPrice * (1 - Discount)` で計算します。

## 1. クロス集計とは

「地域を行、年を列、売上をセル」のように、**あるキーの値そのものを列の見出しに展開した集計表**を
クロス集計(cross tab)と呼びます。元データはこういう縦持ちです。

| 地域 | 年 | 売上 |
|---|---|---|
| 関東 | 2023 | … |
| 関東 | 2024 | … |
| 関西 | 2023 | … |

これを次のような横持ちの表にするのがゴールです。

| 地域 | 2023 | 2024 |
|---|---|---|
| 関東 | … | … |
| 関西 | … | … |

SQL Server では、これを **`PIVOT` 演算子** か **`SUM(CASE WHEN ...)` の条件付き集計** の
どちらでも書けます。まず `PIVOT` から見ていきます。

> `PIVOT` / `UNPIVOT` は SQL Server 2005 以降で使えます。

## 2. PIVOT の基本構文(地域 × 年 の売上)

`PIVOT` は **ソース(元になる問い合わせ)** に対して
「集約関数」と「`FOR 列 IN (値の一覧)`」を指定します。

```sql
SELECT *
FROM (
    -- ① ソース: 必要な3種類の列だけに絞る(超重要。3章で詳述)
    SELECT c.Region                                        AS 地域,
           YEAR(o.OrderDate)                               AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount)  AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT (
    SUM(売上)                       -- ② 各セルの集約
    FOR 年 IN ([2023], [2024])      -- ③ この列の値を、列見出しへ展開
) AS pvt;
```

- **① ソース** … 展開したいデータを縦持ちで用意します。ここでは `地域 / 年 / 売上` の3列。
- **② 集約関数** … 各セルの値をどう集計するか(ここでは売上の `SUM`)。
- **③ `FOR 年 IN (...)`** … 「`年` 列の値」を列見出しに展開します。
  数値は識別子にできないので `[2023]` のように **角括弧で囲みます**。
- 結果の列は `地域 / [2023] / [2024]` になります。
  展開した値に該当する明細が無いセルは **NULL**(0 ではない)になります。

> ⚠️ `IN (...)` に書けるのは **リテラルの並び** だけです。「実際に存在する年を自動で列にする」
> といったことは静的な `PIVOT` ではできません。値が実行時まで分からない場合は
> [8章](#8-動的-pivot-が必要になる場面概要)の動的 PIVOT が必要になります。

## 3. PIVOT が要求すること — ソースは「3種類の列」だけにする

`PIVOT` でもっとも事故が多いのがここです。`PIVOT` は
**「集約関数で使う列」と「`FOR` で使う列」以外のすべての列」** を、
暗黙のうちに **グループ化キー** として扱います。

つまり上の例では、ソースに `地域 / 年 / 売上` しか無いので `地域` だけがグループ化キーになり、
「地域ごと」に集計されます。ここに余計な列が紛れ込むと、グループが細かくなりすぎて表が崩れます。

```sql
-- ✗ アンチパターン: ソースを SELECT * にすると、
--    OrderId や CustomerId までグループ化キーになり、地域ごとにまとまらない
SELECT *
FROM (
    SELECT *                              -- 余計な列がすべてグループ化キーになる
    FROM   dbo.Orders o
    JOIN   dbo.Customers c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
) AS src
PIVOT ( SUM(...) FOR ... ) AS pvt;        -- 期待どおりに集計されない
```

- 対策は単純で、**ソースの `SELECT` には「グループ化キー」「`FOR` 列」「集約対象」の3種類だけ**を
  書くことです。`SELECT *` や不要な列は絶対に持ち込まないこと。
- グループ化キーが複数欲しい場合(例: 地域と市の両方を行にしたい)は、
  その両方をソースに残せば、両方がグループ化キーになります。

> ⚠️ 「なぜか行が細切れになる/合計が合わない」ときは、まずソースに余計な列が
> 混ざっていないかを疑ってください。`PIVOT` の暗黙グループ化がほぼ原因です。

## 4. COUNT でのクロス集計(件数の集計)

集約関数は `SUM` に限りません。件数なら `COUNT` を使います。
次は「地域 × 年 の **注文件数**」です。金額は不要なので `OrderDetails` は結合しません
(結合すると1注文が明細数だけ重複して数えられてしまいます)。

```sql
SELECT *
FROM (
    SELECT c.Region            AS 地域,
           YEAR(o.OrderDate)   AS 年,
           o.OrderId
    FROM   dbo.Orders    AS o
    JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId
) AS src
PIVOT (
    COUNT(OrderId)
    FOR 年 IN ([2023], [2024])
) AS pvt;
```

- `COUNT(OrderId)` … その地域・その年の注文行数を数えます。
- 該当なしのセルは、`COUNT` の場合 **0** になります(`SUM` は NULL、`COUNT` は 0 という違いに注意)。

## 5. CASE 式 + 集約で同じことをする(実務ではこちらが主役)

`PIVOT` と **まったく同じ結果**を、`SUM(CASE WHEN ...)` の条件付き集計で書けます。
むしろ実務ではこちらのほうが **柔軟で読みやすく、よく使われます**。

```sql
-- 2章の PIVOT と同じ「地域 × 年 の売上」を CASE で
SELECT c.Region AS 地域,
       SUM(CASE WHEN YEAR(o.OrderDate) = 2023
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2023],
       SUM(CASE WHEN YEAR(o.OrderDate) = 2024
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) END) AS [2024]
FROM   dbo.Orders       AS o
JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
GROUP  BY c.Region;
```

仕組みはこうです。`CASE WHEN 年=2023 THEN 売上 END` は、**2023年の行だけ売上を返し、
それ以外は NULL** になります。`SUM` は NULL を無視するので、結果として
「2023年の売上だけの合計」が得られます。これを年ごとの列として並べれば横持ちの完成です。

### なぜ実務では CASE 集計が好まれるのか

- **複数の集計を同時に並べられる**。`PIVOT` は1回に集約関数を1つしか書けませんが、
  `CASE` なら「2023の売上」と「2023の件数」を同じ表に混在させられます。

  ```sql
  SELECT c.Region AS 地域,
         SUM(CASE WHEN YEAR(o.OrderDate)=2023
                  THEN od.Quantity*od.UnitPrice*(1-od.Discount) END)          AS 売上_2023,
         COUNT(DISTINCT CASE WHEN YEAR(o.OrderDate)=2023 THEN o.OrderId END)  AS 件数_2023
  FROM   dbo.Orders o
  JOIN   dbo.Customers c   ON c.CustomerId = o.CustomerId
  JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
  GROUP  BY c.Region;
  ```

- **条件が「一致」以外でもよい**。`WHEN UnitPrice >= 10000` のような範囲や、
  複数条件の組み合わせ(`WHEN Region=N'関東' AND ...`)を列にできます。
  `PIVOT` は「列の値がちょうど一致」しか扱えません。
- **空セルを 0 にしたい**ときも素直です。`COALESCE(SUM(CASE ... END), 0)` と包むだけ。
  `PIVOT` で 0 埋めするには外側にもう1段クエリが要ります。

```sql
-- 空セルを 0 で埋める(CASE 版は COALESCE を被せるだけ)
SELECT c.Region AS 地域,
       COALESCE(SUM(CASE WHEN YEAR(o.OrderDate)=2023
                THEN od.Quantity*od.UnitPrice*(1-od.Discount) END), 0) AS [2023],
       COALESCE(SUM(CASE WHEN YEAR(o.OrderDate)=2024
                THEN od.Quantity*od.UnitPrice*(1-od.Discount) END), 0) AS [2024]
FROM   dbo.Orders o
JOIN   dbo.Customers c    ON c.CustomerId = o.CustomerId
JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
GROUP  BY c.Region;
```

> ⚠️ 逆に、`PIVOT` の利点は「列数が多いときに構文が短くまとまる」ことです。
> 単純な1集約のクロス集計は `PIVOT`、複雑・複数集計・0埋め・範囲条件は `CASE`、と
> 使い分けるとよいでしょう。まず `CASE` で書けるようになるのが実務では有利です。

## 6. UNPIVOT で列 → 行に戻す

`UNPIVOT` は `PIVOT` の逆で、**横に並んだ複数の列を、1列の値と1列のラベルに畳み込みます**。
「四半期ごとの列(Q1,Q2,Q3,Q4)を持つ横持ち表」を、
「四半期という列と売上という列を持つ縦持ち」に直す、といった場面で使います。

ここでは、いったん `CASE` 集計で作った横持ち(2023年・カテゴリ×四半期)を CTE に入れ、
それを `UNPIVOT` で縦に戻してみます。

```sql
WITH 横持ち AS (
    SELECT cat.CategoryName AS カテゴリ,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=1
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q1,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=2
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q2,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=3
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q3,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=4
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q4
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Orders       AS o   ON o.OrderId    = od.OrderId
    JOIN   dbo.Products     AS p   ON p.ProductId  = od.ProductId
    JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
    WHERE  YEAR(o.OrderDate) = 2023
    GROUP  BY cat.CategoryName
)
SELECT カテゴリ, 四半期, 売上
FROM   横持ち
UNPIVOT (
    売上 FOR 四半期 IN (Q1, Q2, Q3, Q4)   -- 畳み込む列を並べる
) AS up
ORDER  BY カテゴリ, 四半期;
```

- `売上` … 畳み込んだ **値** が入る新しい列名。
- `FOR 四半期 IN (Q1, Q2, Q3, Q4)` … 畳み込む **元の列名**を並べ、
  その **列名の文字列**(`'Q1'` など)が `四半期` 列の値になります。
- `Q1〜Q4` は **型が揃っている**必要があります(ここではすべて売上の DECIMAL)。

> ⚠️ `UNPIVOT` は **NULL のセルを行ごと落とします**。上の CTE で、ある四半期に
> 売上が無いカテゴリはその四半期の行が現れません(全期間の行が欲しいなら注意)。
> 逆に「NULL も1行として残したい」ときは、後述の `CROSS APPLY (VALUES ...)` や
> `CASE` ベースの手動アンピボットを使います。

### CASE を使わない別解: CROSS APPLY + VALUES

`UNPIVOT` は「NULL を落とす」「型を厳密に揃える必要がある」といった癖があります。
より柔軟に列→行変換したいときは `CROSS APPLY (VALUES ...)` が定番です。

```sql
-- 横持ち CTE(上と同じ)を、VALUES で縦に展開。NULL も保持される
SELECT h.カテゴリ, v.四半期, v.売上
FROM   横持ち AS h
CROSS  APPLY (VALUES (N'Q1', h.Q1),
                     (N'Q2', h.Q2),
                     (N'Q3', h.Q3),
                     (N'Q4', h.Q4)) AS v(四半期, 売上)
ORDER  BY h.カテゴリ, v.四半期;
```

- 各行につき4行を生成します。`UNPIVOT` と違い **NULL の売上もそのまま残ります**。
- ラベル(`N'Q1'` 等)を自分で書けるので、表示名を自由に付けられるのも利点です。

## 7. 応用: PIVOT の結果を別集計に使う

`PIVOT` / `CASE` で作った横持ちは、そのまま列同士の計算に使えます。
たとえば「2023→2024 の増減」を出したいなら、横持ちにしてから引き算します。

```sql
SELECT 地域,
       [2023],
       [2024],
       [2024] - [2023] AS 前年差
FROM (
    SELECT c.Region AS 地域,
           YEAR(o.OrderDate) AS 年,
           od.Quantity*od.UnitPrice*(1-od.Discount) AS 売上
    FROM   dbo.Orders o
    JOIN   dbo.Customers c    ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN ([2023], [2024]) ) AS pvt;
```

- 縦持ちのままだと年をまたいだ引き算がしづらいのが、横持ちにすると素直に書けます。
- `[2023]` / `[2024]` が NULL だと差も NULL になる点に注意(必要なら `COALESCE([2023],0)`)。

## 8. 動的 PIVOT が必要になる場面(概要)

`PIVOT` の `IN (...)` は **リテラルの並び**です。列にしたい値が
「実行時まで確定しない」「年が増えるたびに手で足したくない」ような場合、
列見出しの一覧を **文字列として組み立ててから `PIVOT` 文を実行**する
「動的 PIVOT」が必要になります。実装の骨子だけ示します(詳細は本コースの範囲外)。

```sql
DECLARE @cols NVARCHAR(MAX);
DECLARE @sql  NVARCHAR(MAX);

-- ① 実データから列見出しの一覧を組み立てる(STRING_AGG は SQL Server 2017 以降)
--    QUOTENAME で [ ] を付け、SQLインジェクション対策も兼ねる
SELECT @cols = STRING_AGG(QUOTENAME(年), N', ')
FROM (SELECT DISTINCT YEAR(OrderDate) AS 年 FROM dbo.Orders) AS y;

-- ② PIVOT 文を文字列として組み立てる
SET @sql = N'
SELECT *
FROM (
    SELECT c.Region AS 地域,
           YEAR(o.OrderDate) AS 年,
           od.Quantity*od.UnitPrice*(1-od.Discount) AS 売上
    FROM   dbo.Orders o
    JOIN   dbo.Customers c    ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt;';

-- ③ 実行
EXEC sys.sp_executesql @sql;
```

- ポイントは「①列一覧を作る → ②文字列で PIVOT 文を組む → ③`sp_executesql` で実行」の3段構え。
- `STRING_AGG` は **2017 以降**。それ以前は `FOR XML PATH` で連結する古い書き方になります。
- 動的 SQL は **必ず `QUOTENAME`** を通し、外部入力を直接連結しないこと(インジェクション対策)。
- 動的 PIVOT は強力ですが可読性・保守性が下がります。**列が固定なら静的な `PIVOT`/`CASE` を優先**し、
  「列が動的に増える」ことが本当に要件のときだけ使いましょう。

## よくあるつまずき

- **PIVOT の行が細切れ・合計が合わない** → ソースに余計な列がある。
  `SELECT *` をやめ、「グループ化キー・`FOR` 列・集約対象」の3種類だけに絞る(3章)。
- **`IN ([2023])` が構文エラー** → 数値見出しは角括弧で囲む。文字列見出しは `IN ([関東], [関西])`。
- **該当なしのセルが NULL** → `SUM` 系は NULL、`COUNT` は 0。0 にしたいなら `COALESCE(..., 0)`。
- **UNPIVOT したら行が減った** → `UNPIVOT` は NULL 行を落とす仕様。残したいなら `CROSS APPLY (VALUES ...)`。
- **UNPIVOT で型エラー** → 畳み込む列の型がバラバラ。`CAST` で揃えてから `UNPIVOT` する。
- **列を動的にしたい** → 静的 `PIVOT` では不可。動的 SQL(8章)が必要。まず本当に必要か再考する。

## この章のまとめ

- クロス集計は **`PIVOT` 演算子** か **`SUM(CASE WHEN ...)`** で作れる。
- `PIVOT` は「ソース → 集約 → `FOR 列 IN (値)`」。**ソースは3種類の列だけ**に絞るのが鉄則。
- 実務では **`CASE` 集計のほうが柔軟**(複数集計の混在・範囲条件・0埋めが簡単)。
  まず `CASE` で書けるようにしておくと応用が利く。
- `SUM` 系の空セルは NULL、`COUNT` は 0。0 埋めは `COALESCE`。
- 列→行は **`UNPIVOT`**(NULL は落ちる)か **`CROSS APPLY (VALUES ...)`**(NULL も残る)。
- 列が実行時まで決まらないときだけ **動的 PIVOT**。可読性を犠牲にするので乱用しない。

➡ 演習: [exercises/10_pivot_unpivot.md](../exercises/10_pivot_unpivot.md)
