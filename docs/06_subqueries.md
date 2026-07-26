# 06 サブクエリ

> **このトピックのゴール**: クエリの中に別のクエリ(サブクエリ)を入れ子にして、
> 「平均より高い社員」「注文のない顧客」のような **一段深い問い** を表現できるようになる。
> スカラーサブクエリ・`IN`/`NOT IN`・派生テーブル・相関サブクエリ・`EXISTS`/`NOT EXISTS`・
> `ANY`/`ALL` を使い分け、**`NOT IN` に NULL が混ざる罠**を回避できるようにする。
>
> **前提**: [05 集約とグループ化](05_aggregation.md) を済ませ、`AVG`/`MAX`/`COUNT` と
> `GROUP BY` を理解していること。NULL と三値論理([02 WHERE による絞り込み](02_where_filtering.md))も復習しておくと理解が早い。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. サブクエリとは

**サブクエリ(副問い合わせ)** は、別のクエリの中に入れ子にした `SELECT` 文です。
「まず内側で値や集合を求め、それを外側のクエリが使う」という二段構えで問いを表現します。

サブクエリは書ける場所と返す形によって分類できます。

| 分類 | 返すもの | 主な使いどころ |
|---|---|---|
| スカラーサブクエリ | **単一の値**(1行1列) | `WHERE` の比較右辺、`SELECT` の式 |
| 複数行サブクエリ | **1列の値の集合** | `IN` / `NOT IN` / `ANY` / `ALL` |
| テーブル式サブクエリ | **表(複数行複数列)** | `FROM` 句の派生テーブル |
| 相関サブクエリ | 外側の行ごとに評価 | `EXISTS` / `NOT EXISTS`、相関スカラー |

- サブクエリは必ず **括弧 `( )`** で囲みます。
- 内側の `SELECT` にも `WHERE`・`GROUP BY` などを普通に書けます。

## 2. スカラーサブクエリ(単一の値を返す)

**1行1列** を返すサブクエリは、ひとつの値のように比較式の中で使えます。
典型は「**全体の平均と比べる**」パターンです。

```sql
-- 全社平均より給与が高い社員
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  Salary > (SELECT AVG(Salary) FROM dbo.Employees);
```

- 内側 `(SELECT AVG(Salary) ...)` はまず1つの平均値を返し、外側はそれと各行を比較します。
- 全社平均はおよそ 55.2 万円。佐藤・鈴木・伊藤・渡辺・小林・吉田の6名が該当します。
- `WHERE Salary > 551538` のように定数を手で書く必要がなく、**データが変わっても正しく追従**します。

> ⚠️ スカラーサブクエリが **2行以上を返すとエラー**になります
> (`Subquery returned more than 1 value`)。`=`・`>` などの右辺に置くサブクエリは、
> 必ず1行1列に収まるよう `AVG`/`MAX` などの集約や `TOP (1)` で1件に絞ります。

## 3. WHERE 内のサブクエリ(IN / NOT IN)

サブクエリが **1列の集合** を返すなら、`IN` / `NOT IN` で「その集合に含まれるか」を判定できます。
`IN (値1, 値2, ...)` のリスト部分をサブクエリに置き換えるイメージです。

```sql
-- 一度でも注文された商品(注文明細に登場する ProductId の集合に含まれる)
SELECT ProductName
FROM   dbo.Products
WHERE  ProductId IN (SELECT ProductId FROM dbo.OrderDetails);
```

```sql
-- 廃番でない商品だけを出す(廃番の ProductId 集合を NOT IN で除外)
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  ProductId NOT IN (
           SELECT ProductId
           FROM   dbo.Products
           WHERE  Discontinued = 1   -- 廃番(USBハブ・ホチキス)
       );
-- 同義: WHERE Discontinued = 0  … この例は直接書くほうが簡単だが、
--       「別テーブルの集合を除外する」形の練習として NOT IN を使っている
```

- サブクエリ側は **1列だけ** を `SELECT` します(複数列だと `IN` では使えません)。
- この2つの `NOT IN` は、集合側の `ProductId` が **NOT NULL** なので安全です。
  しかし **集合側に NULL が混ざると `NOT IN` は破綻します**。これは本章の最後(9 節)で詳しく扱います。

## 4. FROM 内のサブクエリ(派生テーブル)

`FROM` 句にサブクエリを書くと、その結果を **ひとつの表** のように扱えます。
これを **派生テーブル(derived table)** と呼びます。集約した中間結果をさらに絞り込むときに便利です。

```sql
-- 部門ごとの平均給与を派生テーブルにし、平均 50万円以上の部門だけを出す
SELECT d.DepartmentId,
       d.平均給与
FROM   ( SELECT DepartmentId,
                AVG(Salary) AS 平均給与
         FROM   dbo.Employees
         WHERE  DepartmentId IS NOT NULL
         GROUP  BY DepartmentId ) AS d      -- ← 派生テーブルには別名が必須
WHERE  d.平均給与 >= 500000;
```

- 派生テーブルには **必ず別名(ここでは `d`)** を付けます。付けないと構文エラーです。
- 派生テーブル内で付けた列の別名(`平均給与`)は、外側から **列名として参照**できます。
  これにより [01](01_select_basics.md) で触れた「`WHERE` で別名が使えない」制約を回避できます。
- 同じことは後述の CTE([07 CTE](../exercises/07_cte.md))でも書け、複雑になるほど CTE のほうが読みやすくなります。

## 5. SELECT 内のスカラーサブクエリ

`SELECT` の並びの中にスカラーサブクエリを書くと、**各行に「全体から計算した値」を添える**ことができます。

```sql
-- 各社員の給与と、全社平均との差
SELECT LastName,
       Salary,
       Salary - (SELECT AVG(Salary) FROM dbo.Employees) AS 平均との差
FROM   dbo.Employees;
```

外側の行を参照する(相関する)スカラーサブクエリも書けます。次は顧客ごとの注文件数です。

```sql
-- 各顧客の注文件数(相関スカラーサブクエリ)
SELECT c.CustomerName,
       ( SELECT COUNT(*)
         FROM   dbo.Orders AS o
         WHERE  o.CustomerId = c.CustomerId ) AS 注文件数   -- ← 外側 c を参照
FROM   dbo.Customers AS c;
```

- 内側の `WHERE o.CustomerId = c.CustomerId` で **外側の各行 `c` を参照**しています(これが「相関」・次節)。
- 注文が1件もない顧客(ラムダソフト)は `COUNT(*)` が **0** になります(NULL ではありません)。

> ⚠️ `SELECT` 内スカラーサブクエリは **1行ごとに評価**されるため、行数が多いと重くなりがちです。
> 件数が多い場面では結合([04 結合](04_joins.md))や `GROUP BY` での集計に書き換えられないか検討しましょう。

## 6. 相関サブクエリ

**相関サブクエリ(correlated subquery)** は、内側から **外側のクエリの列を参照**するサブクエリです。
外側の1行ごとに内側が評価される、という点が独立したサブクエリと異なります。

```sql
-- 各部門で最高給の社員(内側で「その社員と同じ部門の最高給」を求めて比較)
SELECT e.LastName,
       e.DepartmentId,
       e.Salary
FROM   dbo.Employees AS e
WHERE  e.Salary = ( SELECT MAX(e2.Salary)
                    FROM   dbo.Employees AS e2
                    WHERE  e2.DepartmentId = e.DepartmentId );   -- ← 外側 e を参照
```

- 外側 `e` の行ごとに、内側は「`e` と同じ部門の最高給」を計算し、それと `e.Salary` が等しい行を残します。
- 結果は 佐藤(営業)・伊藤(開発)・小林(マーケ)・吉田(人事)。
- **外側と内側で別名を分ける**(`e` と `e2`)のが相関サブクエリの定石です。同名だと自分自身を指してしまいます。

> ⚠️ 部署未定の社員(佐々木, `DepartmentId = NULL`)は結果に出ません。
> 内側の `e2.DepartmentId = NULL` はどの行にも一致せず `MAX` が NULL になり、
> `e.Salary = NULL` が UNKNOWN になって除外されるためです(三値論理・[02](02_where_filtering.md))。

## 7. EXISTS / NOT EXISTS

`EXISTS (サブクエリ)` は、サブクエリが **1行でも返せば TRUE**、1行も返さなければ FALSE を返します。
「**存在するかどうか** だけ」を見るので、サブクエリの `SELECT` の中身は何でもよく、慣習的に `SELECT 1` と書きます。

```sql
-- 一度でも注文したことがある顧客
SELECT c.CustomerName
FROM   dbo.Customers AS c
WHERE  EXISTS ( SELECT 1
                FROM   dbo.Orders AS o
                WHERE  o.CustomerId = c.CustomerId );
```

`NOT EXISTS` はその逆で、「**1件も存在しない**」行を残します。

```sql
-- 注文が1件もない顧客(= ラムダソフト)
SELECT c.CustomerName, c.City
FROM   dbo.Customers AS c
WHERE  NOT EXISTS ( SELECT 1
                    FROM   dbo.Orders AS o
                    WHERE  o.CustomerId = c.CustomerId );
```

相関条件を組み合わせると、より具体的な問いも書けます。

```sql
-- 担当営業(SalesRepId)が、その顧客の注文の受注担当(Orders.EmployeeId)も務めている顧客
SELECT c.CustomerName, c.SalesRepId
FROM   dbo.Customers AS c
WHERE  EXISTS ( SELECT 1
                FROM   dbo.Orders AS o
                WHERE  o.CustomerId = c.CustomerId
                  AND  o.EmployeeId = c.SalesRepId );
```

```sql
-- 注文明細に登場する商品のうち、廃番でないものだけ
SELECT p.ProductName
FROM   dbo.Products AS p
WHERE  p.Discontinued = 0
  AND  EXISTS ( SELECT 1
                FROM   dbo.OrderDetails AS od
                WHERE  od.ProductId = p.ProductId );
```

- `EXISTS` は **存在の有無しか見ない**ので、内側で NULL があっても結果に影響しません。
  ここが `IN`/`NOT IN` との決定的な違いで、**NULL に強い**理由です。
- `NOT EXISTS` は「差集合(〜がない側)」を安全に取り出す定番手段です。

> ⚠️ `EXISTS` の内側の `SELECT` に書く列は評価されません。`SELECT 1` でも `SELECT *` でも
> 結果は同じです(存在判定だけのため)。可読性のため `SELECT 1` を推奨します。

## 8. ANY / SOME / ALL

比較演算子(`>` `<` `=` など)にサブクエリの **集合すべて/いずれか** を組み合わせる修飾子です。
`ANY` と `SOME` は完全に同義です。

- `> ANY (集合)` … 集合の **いずれか** より大きい ⇔ 集合の **最小値** より大きい
- `> ALL (集合)` … 集合の **すべて** より大きい ⇔ 集合の **最大値** より大きい

```sql
-- 開発部(DepartmentId=2)の「誰よりも」給与が高い社員(> ALL)
SELECT LastName, Salary
FROM   dbo.Employees
WHERE  Salary > ALL ( SELECT Salary
                      FROM   dbo.Employees
                      WHERE  DepartmentId = 2 );
-- 開発部の最高給は伊藤の78万。それより高いのは佐藤(95万)だけ。
```

```sql
-- 開発部の「誰か」より給与が高い社員(> ANY = 開発部の最低給 40万 より上)
SELECT LastName, Salary
FROM   dbo.Employees
WHERE  Salary > ANY ( SELECT Salary
                      FROM   dbo.Employees
                      WHERE  DepartmentId = 2 );
```

`IN` / `NOT IN` は `ANY` / `ALL` で言い換えられます。

- `x IN (集合)` は `x = ANY (集合)` と同義。
- `x NOT IN (集合)` は `x <> ALL (集合)` と同義。

```sql
-- IN と = ANY は同じ結果
SELECT ProductName FROM dbo.Products
WHERE  ProductId = ANY (SELECT ProductId FROM dbo.OrderDetails);
```

> ⚠️ `> ALL (空集合)` は **TRUE**、`> ANY (空集合)` は **FALSE** になります。
> また `NOT IN` ⇔ `<> ALL` なので、**集合に NULL が混ざると `<> ALL` も同じ罠**を踏みます(次節)。

## 9. NOT IN にサブクエリの NULL が混ざる落とし穴(最重要)

`NOT IN (サブクエリ)` は、**サブクエリが1つでも NULL を返すと、結果が常に0件**になります。
`IN` は問題ないのに `NOT IN` だけが壊れる、実務で頻発する罠です。

```sql
-- やりたいこと: どの顧客の担当営業にもなっていない社員を出す
-- ✗ Customers.SalesRepId には NULL(担当なしの顧客)が含まれるため、これは 0 件になる
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  e.EmployeeId NOT IN ( SELECT c.SalesRepId
                             FROM   dbo.Customers AS c );
```

なぜ0件になるのか。`x NOT IN (2, 3, 4, NULL)` は
`x <> 2 AND x <> 3 AND x <> 4 AND x <> NULL` と同義です。
最後の `x <> NULL` は **必ず UNKNOWN**。`TRUE AND UNKNOWN = UNKNOWN` なので
全体が TRUE になれず、**どの行も残りません**([02 の三値論理](02_where_filtering.md))。

対策は3つ。**いちばんの推奨は `NOT EXISTS`** です。

```sql
-- ○ 対策1(推奨): NOT EXISTS で書き換える(NULL に強い)
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  NOT EXISTS ( SELECT 1
                    FROM   dbo.Customers AS c
                    WHERE  c.SalesRepId = e.EmployeeId );
```

```sql
-- ○ 対策2: サブクエリ側で NULL を明示的に除外する
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  e.EmployeeId NOT IN ( SELECT c.SalesRepId
                             FROM   dbo.Customers AS c
                             WHERE  c.SalesRepId IS NOT NULL );  -- ← NULL を除く
```

- 対策1・2とも、どの顧客の担当にもなっていない社員(佐藤・伊藤・渡辺・山本・中村・小林・加藤・吉田・山田・佐々木)が正しく返ります。担当営業は鈴木(2)・高橋(3)・田中(4)のみです。
- `NOT EXISTS` は内側の NULL に影響されないため、**NULL を気にせず書ける**のが最大の利点です。

> ⚠️ 実務で `NOT IN (サブクエリ)` を書くときは、**サブクエリ側の列が NULL を返し得るか** を必ず確認。
> NULL 可の列(FK で NULL 許可、外部結合の結果など)を `NOT IN` に渡すのは危険です。
> 迷ったら `NOT EXISTS` に統一するのが安全策です。

## よくあるつまずき

- **`NOT IN (サブクエリ)` が 0 件になる** → サブクエリが NULL を返している。`NOT EXISTS` に書き換える(または `IS NOT NULL` で除外)。
- **`Subquery returned more than 1 value` エラー** → `=`/`>` の右辺のスカラーサブクエリが2行以上返している。`MAX`/`AVG`/`TOP (1)` で1件に絞る。
- **派生テーブルで構文エラー** → `FROM (SELECT ...)` に **別名を付け忘れ**ている。`) AS d` を足す。
- **相関サブクエリで結果がおかしい** → 内側と外側の別名が同じ。`e` と `e2` のように **別名を分ける**。
- **相関の対象が NULL の行が消える** → `= (サブクエリ)` は NULL 相手だと UNKNOWN。`EXISTS` か明示的な NULL 処理を検討。
- **`SELECT` 内サブクエリが遅い** → 1行ごとに評価されるため。結合や `GROUP BY` 集計に置き換えられないか検討。

## この章のまとめ

- サブクエリは括弧で囲んだ入れ子の `SELECT`。返す形で **スカラー / 集合 / 表** を使い分ける。
- スカラーサブクエリは `WHERE` の比較右辺や `SELECT` の式に。**1行1列**でないとエラー。
- 集合を返すなら `IN` / `NOT IN` / `ANY` / `ALL`。`IN`⇔`= ANY`、`NOT IN`⇔`<> ALL`。
- `FROM` の **派生テーブル**(別名必須)で中間結果をさらに絞れる。
- **相関サブクエリ**は外側の行を参照し1行ごとに評価される(各部門の最高給・顧客別件数など)。
- **`EXISTS` / `NOT EXISTS`** は存在の有無だけを見るため **NULL に強い**。差集合は `NOT EXISTS` が定番。
- **`NOT IN (サブクエリ)` に NULL が混ざると全滅**。原則 `NOT EXISTS` を使う。

➡ 演習: [exercises/06_subqueries.md](../exercises/06_subqueries.md)

➡ 次のトピック: [07 CTE(共通テーブル式)](../exercises/07_cte.md)
