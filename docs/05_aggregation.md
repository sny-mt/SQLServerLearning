# 05 集計とグループ化

> **このトピックのゴール**: `COUNT`/`SUM`/`AVG`/`MIN`/`MAX` などの集約関数を使い、
> `GROUP BY` で「グループごとの集計」を求め、`HAVING` でグループを絞り込めるようになる。
> さらに `ROLLUP`/`CUBE`/`GROUPING SETS` で小計・総計を一度に出せるようになる。
>
> **前提**: [04 テーブルの結合](04_joins.md) を済ませ、複数テーブルを結合して
> 1つの結果にできること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. 集約関数の基本(COUNT / SUM / AVG / MIN / MAX)

**集約関数** は、複数行の値を **1つの値にまとめる** 関数です。
`GROUP BY` を書かずに使うと、テーブル全体を1グループとして集計します。

```sql
-- 社員テーブル全体を1つのグループとして集計する
SELECT COUNT(*)     AS 社員数,
       SUM(Salary)  AS 給与合計,
       AVG(Salary)  AS 平均給与,
       MIN(Salary)  AS 最低給与,
       MAX(Salary)  AS 最高給与
FROM   dbo.Employees;
```

- `COUNT` … 件数を数える。
- `SUM` … 合計。数値列にのみ使える。
- `AVG` … 平均。`SUM / COUNT` に相当(ただし NULL の扱いに注意、後述)。
- `MIN` / `MAX` … 最小・最大。数値だけでなく文字列・日付にも使える。

```sql
-- 日付にも MIN / MAX が使える(最初と最後の注文日)
SELECT MIN(OrderDate) AS 最古の注文日,
       MAX(OrderDate) AS 最新の注文日
FROM   dbo.Orders;
```

> ⚠️ 集約関数を書いた `SELECT` に、集約していない「素の列」を混ぜると
> エラーになります(`GROUP BY` が必要)。詳しくは第4・5節で扱います。

## 2. 集約関数は NULL を無視する

`COUNT(*)` を **除く** すべての集約関数は、**NULL の行を計算に含めません**。
これは合計・平均を求めるうえで極めて重要な性質です。

```sql
-- Salary はどの社員も入っているので NULL の影響はないが、
-- AVG は「値がある行の合計 ÷ 値がある行数」で計算される点を意識する。
SELECT SUM(Salary) AS 給与合計,
       COUNT(*)     AS 全行数,
       COUNT(Salary) AS 給与のある行数,
       AVG(Salary)  AS 平均給与
FROM   dbo.Employees;
```

- `AVG(列)` の分母は **その列が NULL でない行数** です(全行数ではない)。
- そのため「NULL を 0 とみなして平均したい」場合は、`AVG(ISNULL(列, 0))` のように
  **明示的に NULL を 0 に変換** してから平均を取る必要があります。両者は結果が変わります。

```sql
-- 「NULL は無視」と「NULL を 0 扱い」で平均が変わることを体感する例。
-- Discount は 0.00〜1.00 で必ず値が入っているが、書き方の違いを示す。
SELECT AVG(Discount)            AS 割引率_平均_NULL無視,
       AVG(ISNULL(Discount, 0)) AS 割引率_平均_NULLは0
FROM   dbo.OrderDetails;
```

> ⚠️ 「平均が想定より高い/低い」ときは、**NULL 行が分母から外れている** ことがよくある原因です。
> NULL をどう扱うべきか(無視か 0 扱いか)を必ず意識しましょう。

## 3. COUNT(*) と COUNT(列) と COUNT(DISTINCT 列) の違い

`COUNT` には3つの書き方があり、**数える対象が違います**。

```sql
SELECT COUNT(*)                    AS 全社員,      -- 行数そのもの
       COUNT(Email)                AS Email有り,   -- Email が NULL でない行数
       COUNT(DepartmentId)         AS 部署有り,     -- DepartmentId が NULL でない行数
       COUNT(DISTINCT DepartmentId) AS 部署の種類数  -- 異なる DepartmentId の個数
FROM   dbo.Employees;
```

- `COUNT(*)` … **行数** を数える。NULL があっても関係なく、その行が存在すれば数える。
- `COUNT(列)` … その列が **NULL でない行だけ** を数える(NULL は数えない)。
- `COUNT(DISTINCT 列)` … その列の **異なる値の個数**(重複を除く。NULL は数えない)。

このデータでは次のようになります。

- `COUNT(*)` = 13(全社員)。
- `COUNT(Email)` = 12(社員8 中村は `Email` が NULL なので数えない)。
- `COUNT(DepartmentId)` = 12(社員13 佐々木は `DepartmentId` が NULL なので数えない)。
- `COUNT(DISTINCT DepartmentId)` = 4(部署は 1〜5 あるが、社員がいるのは 1〜4 の4種類。
  NULL は数えない。社員のいない経理部5も現れない)。

> ⚠️ 「登録件数」を数えるつもりで `COUNT(列)` を使うと、その列が NULL の行が
> こっそり除外されます。**単純な行数が欲しいなら `COUNT(*)`** を使いましょう。

## 4. GROUP BY でグループごとに集計する

`GROUP BY` は、指定した列の **同じ値ごとに行をまとめて** グループを作り、
各グループに対して集約関数を計算します。

```sql
-- 部署ごとの人数と平均給与
SELECT DepartmentId,
       COUNT(*)    AS 人数,
       AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;
```

- `GROUP BY DepartmentId` … `DepartmentId` が同じ社員を1グループにまとめる。
- 各グループについて `COUNT(*)` と `AVG(Salary)` が1行ずつ返る。

### GROUP BY と NULL

`GROUP BY` では **NULL も1つのグループ** として扱われます(NULL 同士は同じグループ)。

```sql
-- カテゴリごとの商品数。CategoryId が NULL の商品(19,20)は
-- 「NULL のグループ」として1行にまとまる。
SELECT CategoryId,
       COUNT(*) AS 商品数
FROM   dbo.Products
GROUP  BY CategoryId;
```

- 高級万年筆(19)とノベルティグッズ(20)は `CategoryId` が NULL なので、
  **NULL という1つのグループ**(商品数2)になります。
- 「未分類」を分かりやすく表示したいときは `ISNULL(CategoryId, ...)` や
  `CASE` でラベルを付けるとよいでしょう。

```sql
SELECT ISNULL(CAST(CategoryId AS NVARCHAR(10)), N'未分類') AS カテゴリ,
       COUNT(*) AS 商品数
FROM   dbo.Products
GROUP  BY CategoryId
ORDER  BY CategoryId;
```

## 5. SELECT に書ける列の制約(集約されない列は GROUP BY へ)

`GROUP BY` を使うクエリの `SELECT` には、次のどちらかしか書けません。

1. **`GROUP BY` に挙げた列**、または
2. **集約関数**(`COUNT`/`SUM`/… でくるんだ式)。

グループ内には複数の行があるため、「集約していない素の列」は
**どの行の値を返せばよいか決まらず**、エラーになります。

```sql
-- ✗ エラー: LastName は集約されておらず GROUP BY にも無い
SELECT DepartmentId, LastName, AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;
```

```sql
-- ○ 集約しない列は GROUP BY に入れる(この場合はグループの意味も変わる)
SELECT DepartmentId, AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;
```

- 「部署ごとに1行」が欲しいなら、`SELECT` の非集約列は `DepartmentId` だけにします。
- 個々の社員名も見たいなら、それは「集計」ではなく「一覧」なので `GROUP BY` は使いません
  (ウィンドウ関数で「明細＋集計」を並べる方法は後の章で扱います)。

> ⚠️ 他の一部のDB(古い MySQL 等)では非集約列を許すことがありますが、
> **SQL Server では必ずエラー** です。ルールは上の2択、と覚えてください。

## 6. HAVING と WHERE の違い(評価順序)

`WHERE` と `HAVING` はどちらも「絞り込み」ですが、**評価される段階が違います**。

| 句 | 何を絞り込むか | 集約関数を書けるか |
|---|---|---|
| `WHERE` | **グループ化する前の個々の行** | 書けない |
| `HAVING` | **グループ化した後のグループ(集計結果)** | 書ける |

論理評価順序([01](01_select_basics.md) 参照)は
`FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY` です。
`WHERE` は集計の **前**、`HAVING` は集計の **後** に効きます。

```sql
-- 部署ごとの平均給与を求め、その平均が 50万を超える部署だけを残す。
-- ・WHERE  : 集計前に「部署未設定(NULL)の社員」を除外する
-- ・HAVING : 集計後に「平均給与 > 500000 のグループ」だけ残す
SELECT DepartmentId,
       COUNT(*)    AS 人数,
       AVG(Salary) AS 平均給与
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL      -- 行の絞り込み(集計前)
GROUP  BY DepartmentId
HAVING AVG(Salary) > 500000;         -- グループの絞り込み(集計後)
```

- 集約関数を条件にできるのは `HAVING` だけです(`WHERE AVG(...) > ...` は書けません)。
- 逆に、**集計に関係ない単純な行の除外は `WHERE` で** 行うのが効率的です
  (集計前に行数を減らせるため)。「なんでも `HAVING`」にしないこと。

```sql
-- ✗ WHERE に集約関数は書けない
SELECT DepartmentId, AVG(Salary) AS 平均給与
FROM   dbo.Employees
WHERE  AVG(Salary) > 500000        -- エラー
GROUP  BY DepartmentId;
```

> ⚠️ 「集計後の条件」は `HAVING`、「集計前の条件」は `WHERE`。
> 迷ったら「その条件は集約関数を含むか?」を見る。含むなら `HAVING`。

## 7. 結合してから集計する(顧客別・月別の売上)

集約は結合と組み合わせると一気に実用的になります。明細金額は
**`Quantity * UnitPrice * (1 - Discount)`** で計算します([04](04_joins.md) 参照)。

```sql
-- 顧客別の売上合計(注文と明細を結合してから集計)
SELECT o.CustomerId,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上合計
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY o.CustomerId
ORDER  BY 売上合計 DESC;
```

- まず `FROM`/`JOIN` で「注文明細の1行=商品1品」の粒度に展開し、
  そのうえで `CustomerId` ごとに `SUM` します。
- `ORDER BY` は集計の後なので、`SELECT` で付けた別名(`売上合計`)が使えます。

```sql
-- 月別の売上(年・月でグループ化)
SELECT YEAR(o.OrderDate)  AS 年,
       MONTH(o.OrderDate) AS 月,
       COUNT(DISTINCT o.OrderId) AS 注文件数,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY YEAR(o.OrderDate), MONTH(o.OrderDate)
ORDER  BY 年, 月;
```

- **`COUNT(*)` は明細行の数** になってしまう点に注意。
  「注文の件数」を数えたいときは `COUNT(DISTINCT o.OrderId)` とします
  (1注文に複数明細があるため)。ここが `COUNT(*)` と `COUNT(DISTINCT ...)` の使い分けの好例です。

## 8. 小計・総計を一度に出す(GROUPING SETS / ROLLUP / CUBE)

複数の粒度の集計(明細＋小計＋総計)を **1回のクエリ** で出す仕組みです。

### ROLLUP(階層的な小計＋総計)

`ROLLUP (A, B)` は「A・B ごと」「A ごとの小計」「総計」を段階的に出します。

```sql
-- 地域 × 担当(SalesRepId)ごとの顧客数に、
-- 地域ごとの小計と全体総計を足す
SELECT Region,
       SalesRepId,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY ROLLUP (Region, SalesRepId);
```

- 「Region と SalesRepId の組み合わせ」の行に加え、
  各 Region の **小計行**(SalesRepId が NULL)と、**総計行**(両方 NULL)が返ります。
- 小計・総計の行では、集計されていない列が **NULL** として表示されます。

### CUBE(あらゆる組み合わせの小計)

`CUBE (A, B)` は「A ごと」「B ごと」「A×B」「総計」の **全組み合わせ** を出します。

```sql
SELECT Region,
       SalesRepId,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY CUBE (Region, SalesRepId);
```

- `ROLLUP` が階層的(A→A,B の順)なのに対し、`CUBE` は **対称的に全パターン** を出します。

### GROUPING SETS(欲しい集計だけ列挙)

`GROUPING SETS` は、出したい集計の粒度を **明示的に列挙** します。

```sql
-- 「地域ごとの合計」と「担当ごとの合計」と「総計」だけが欲しい
SELECT Region,
       SalesRepId,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY GROUPING SETS ((Region), (SalesRepId), ());
```

- `(Region)` … 地域ごと、`(SalesRepId)` … 担当ごと、`()` … 総計(グループ化なし)。
- `ROLLUP (A,B)` は `GROUPING SETS ((A,B),(A),())`、
  `CUBE (A,B)` は `GROUPING SETS ((A,B),(A),(B),())` と等価です。

## 9. GROUPING() で「小計行」と「NULL データ」を見分ける

`ROLLUP`/`CUBE` の小計・総計行では、集計対象の列が NULL で表示されます。
しかし **元データにも NULL がある** 場合(顧客9・11 は `SalesRepId` が NULL)、
「これは小計の NULL か、データの NULL か」が見た目で区別できません。

そこで **`GROUPING(列)`** を使います。これは、その行でその列が
**小計/総計のために集約された結果 NULL なら 1**、**素の値(NULL含む)なら 0** を返します。

```sql
SELECT CASE WHEN GROUPING(Region) = 1     THEN N'(全地域)'
            ELSE ISNULL(Region, N'(地域なし)') END        AS 地域,
       CASE WHEN GROUPING(SalesRepId) = 1 THEN N'(小計)'
            WHEN SalesRepId IS NULL       THEN N'(担当なし)'
            ELSE CAST(SalesRepId AS NVARCHAR(10)) END     AS 担当,
       COUNT(*) AS 顧客数
FROM   dbo.Customers
GROUP  BY ROLLUP (Region, SalesRepId)
ORDER  BY GROUPING(Region), Region,
         GROUPING(SalesRepId), SalesRepId;
```

- `GROUPING(SalesRepId) = 1` … その行は担当の **小計行**。
- `GROUPING(SalesRepId) = 0 かつ SalesRepId IS NULL` … 元データが **担当なし(NULL)** の顧客
  (顧客9 イオタ商会、顧客11 ラムダソフト)。
- `GROUPING()` を `ORDER BY` に使うと、小計・総計行を先頭/末尾に整えられます。

> ⚠️ `ROLLUP` を使い、かつ元データに NULL があり得る列を集計するときは、
> **`GROUPING()` で必ず区別** しましょう。しないと「小計」と「NULL」が混同されて誤読します。

## よくあるつまずき

- **平均が想定と合わない** → `AVG(列)` は NULL 行を分母から除く。NULL を 0 扱いしたいなら `AVG(ISNULL(列,0))`。
- **登録件数が少なく出る** → `COUNT(列)` は NULL を数えない。行数が欲しいなら `COUNT(*)`。
- **`SELECT` でエラー(列が GROUP BY にない)** → 非集約列は `GROUP BY` に入れるか、集約関数でくるむ。
- **`WHERE` に集約関数を書いてエラー** → 集計後の条件は `HAVING`。集計前の行絞り込みは `WHERE`。
- **注文件数のつもりが多すぎる** → `COUNT(*)` は明細行数。注文数は `COUNT(DISTINCT OrderId)`。
- **ROLLUP の小計行とデータの NULL が区別できない** → `GROUPING(列)` で判定する。

## この章のまとめ

- 集約関数 `COUNT`/`SUM`/`AVG`/`MIN`/`MAX` は複数行を1値にまとめる。
  **`COUNT(*)` 以外は NULL を無視** する。
- `COUNT(*)`=行数、`COUNT(列)`=非NULL行数、`COUNT(DISTINCT 列)`=異なる値の個数。
- `GROUP BY` でグループごとに集計。**NULL も1グループ**。
  `SELECT` に書けるのは **GROUP BY の列か集約関数だけ**。
- `WHERE`=集計前の行絞り込み(集約関数不可)、`HAVING`=集計後のグループ絞り込み(集約関数可)。
- `ROLLUP`/`CUBE`/`GROUPING SETS` で小計・総計を一括取得。
  NULL データがあるときは **`GROUPING()`** で小計行と区別する。

➡ 演習: [exercises/05_aggregation.md](../exercises/05_aggregation.md)
