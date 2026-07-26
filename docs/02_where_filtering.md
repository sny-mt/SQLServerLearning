# 02 WHERE による絞り込み

> **このトピックのゴール**: `WHERE` 句で行を条件で絞り込めるようになる。
> 比較・論理演算子、`BETWEEN`/`IN`/`LIKE`、そして **NULL と三値論理** の扱いを
> 正しく理解し、`NOT IN` に NULL が混ざる罠を避けられるようにする。
>
> **前提**: [01 SELECT の基礎](01_select_basics.md) を済ませていること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. WHERE の基本

`WHERE` は `FROM` の直後に書き、**条件が真(TRUE)になった行だけ**を残します。

```sql
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  UnitPrice >= 10000;
```

- `WHERE` は `SELECT` より **先に** 評価されます([01 の評価順序](01_select_basics.md)を参照)。
  そのため `SELECT` で付けた別名は `WHERE` では使えません。
- 条件の結果は TRUE / FALSE のほかに **UNKNOWN** があります(NULL 絡み。7 節で解説)。
  **残るのは TRUE の行だけ**で、FALSE と UNKNOWN の行は除かれます。

## 2. 比較演算子

| 演算子 | 意味 |
|---|---|
| `=`  | 等しい |
| `<>` | 等しくない(`!=` も可だが標準は `<>`) |
| `>`  | より大きい |
| `<`  | より小さい |
| `>=` | 以上 |
| `<=` | 以下 |

```sql
-- 給与が 60万円ちょうどではない社員
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  Salary <> 600000;

-- 2018-04-01 以降に入社した社員
SELECT LastName, FirstName, HireDate
FROM   dbo.Employees
WHERE  HireDate >= '2018-04-01';
```

- 文字列・日付の比較も同じ演算子で行えます。日付リテラルは `'YYYY-MM-DD'` 形式が安全です。
- 日本語文字列と比較するときは `N'...'` を使います:
  `WHERE DepartmentName = N'開発部'`。

> ⚠️ `<>`(や後述の `NOT IN` など)は **NULL の行を返しません**。
> 「600000 でない社員」に、`Salary` が NULL の行があっても結果に含まれません。
> 理由は 7 節「三値論理」で説明します。

## 3. 論理演算子 AND / OR / NOT と優先順位

複数条件は `AND`(かつ)・`OR`(または)・`NOT`(否定)で組み合わせます。

```sql
-- 営業部(DepartmentId=1)で、かつ給与 50万円以上
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  DepartmentId = 1
  AND  Salary >= 500000;
```

演算子には **優先順位** があり、強い順に `NOT` → `AND` → `OR` です。
つまり `AND` は `OR` より先にまとまります。

```sql
-- 意図: 「(営業部 または 開発部)で、給与 50万円以上」
-- ✗ 括弧なしだと AND が先に結合し、意味が変わってしまう
SELECT LastName, DepartmentId, Salary
FROM   dbo.Employees
WHERE  DepartmentId = 1 OR DepartmentId = 2 AND Salary >= 500000;
-- ↑ これは「DepartmentId=1」または「DepartmentId=2 かつ Salary>=500000」と解釈される

-- ○ 括弧で意図を固定する
SELECT LastName, DepartmentId, Salary
FROM   dbo.Employees
WHERE  (DepartmentId = 1 OR DepartmentId = 2)
  AND  Salary >= 500000;
```

- **迷ったら括弧を付ける**。読み手にも意図が明確に伝わります。
- `NOT` は条件を反転します: `WHERE NOT (Salary >= 500000)` は `Salary < 500000` と(NULL を除けば)同じ。

> ⚠️ `NOT` と NULL の組み合わせは直感に反することがあります。
> `NOT (UNKNOWN)` は `UNKNOWN` のままで TRUE にはなりません(7 節)。

## 4. 範囲を指定する BETWEEN

`BETWEEN a AND b` は **a 以上 b 以下**(両端を含む)を表します。

```sql
-- 単価が 1000〜5000 円(両端含む)の商品
SELECT ProductName, UnitPrice
FROM   dbo.Products
WHERE  UnitPrice BETWEEN 1000 AND 5000;
-- 同義: UnitPrice >= 1000 AND UnitPrice <= 5000
```

日付の範囲にも使えます。

```sql
-- 2023年内に発注された注文
SELECT OrderId, OrderDate
FROM   dbo.Orders
WHERE  OrderDate BETWEEN '2023-01-01' AND '2023-12-31';
```

- 除外したいときは `NOT BETWEEN`。
- **両端を含む**点に注意。「未満」にしたいときは `BETWEEN` ではなく `>= / <` を使います。

> ⚠️ 日時型(`datetime`)の列に対して `BETWEEN '2023-01-01' AND '2023-12-31'` とすると、
> 12月31日の 00:00:00 までしか含まれず、その日の途中のデータが漏れます。
> 本DBの `OrderDate` は `DATE` 型なので問題ありませんが、時刻を持つ型では
> `>= '2023-01-01' AND < '2024-01-01'` の形が安全です。

## 5. 候補リストで絞る IN

`IN (...)` は「リストのいずれかに一致」を表し、`OR` の連続を短く書けます。

```sql
-- 営業部・開発部・マーケ部(1,2,3)のいずれかに所属
SELECT LastName, DepartmentId
FROM   dbo.Employees
WHERE  DepartmentId IN (1, 2, 3);
-- 同義: DepartmentId = 1 OR DepartmentId = 2 OR DepartmentId = 3
```

文字列のリストも使えます。

```sql
SELECT CustomerName, Region
FROM   dbo.Customers
WHERE  Region IN (N'関東', N'関西');
```

- 否定は `NOT IN`。ただし **リストや列に NULL が混ざると罠** があります(8 節で詳解)。

## 6. あいまい検索 LIKE とワイルドカード

`LIKE` は文字列のパターン一致に使います。

| ワイルドカード | 意味 |
|---|---|
| `%`   | 任意の **0文字以上** の文字列 |
| `_`   | 任意の **1文字** |
| `[ ]` | 括弧内の **いずれか1文字**(範囲 `[a-f]` も可) |
| `[^ ]`| 括弧内 **以外** の1文字 |

```sql
-- 「ノート」で始まる商品(ノートPC, ノートA5 など)
SELECT ProductName
FROM   dbo.Products
WHERE  ProductName LIKE N'ノート%';

-- 「東」を含む地名を持つ顧客
SELECT CustomerName, City
FROM   dbo.Customers
WHERE  City LIKE N'%東%';

-- 3文字目までは任意で「モニター」を含む、など _ は1文字
SELECT ProductName
FROM   dbo.Products
WHERE  ProductName LIKE N'____モニター';  -- 「4Kモニター」等(4文字+モニター)
```

`[ ]` と `[^ ]` の例:

```sql
-- 先頭が A〜C いずれかの英字で始まるものにマッチ(範囲指定)
--   例として英字を含むデータで確認するとよい
SELECT CustomerName
FROM   dbo.Customers
WHERE  CustomerName LIKE N'[アカサ]%';   -- 「ア/カ/サ」で始まる顧客名

-- 先頭が「ア」以外
SELECT CustomerName
FROM   dbo.Customers
WHERE  CustomerName LIKE N'[^ア]%';
```

- 否定は `NOT LIKE`。
- **記号そのものを検索したい**とき(`%` や `_` をリテラルとして探す)は `ESCAPE` を使います:
  `WHERE Code LIKE '%50!%%' ESCAPE '!'`(`!%` で「%という文字」を表す)。
- 大文字小文字・全角半角の区別は **照合順序(Collation)** に依存します。

> ⚠️ `LIKE N'%キーワード%'` のように **前方に `%`** を置くと、索引が使いにくく
> 全件走査になりがちです。件数が多いテーブルでは性能に注意しましょう。

## 7. NULL と三値論理(最重要)

NULL は「値が無い/不明」を表す特別な状態です。SQL の条件評価は
TRUE / FALSE に加え **UNKNOWN** を持つ **三値論理** です。

**NULL は何と比較しても結果が UNKNOWN になります**(等しいとも等しくないとも言えない)。

```sql
-- ✗ これは1行も返らない。= では NULL を判定できない
SELECT LastName, Email
FROM   dbo.Employees
WHERE  Email = NULL;      -- Email が NULL でも「NULL = NULL」は UNKNOWN → 除外される

-- ○ NULL 判定には IS NULL / IS NOT NULL を使う
SELECT LastName, Email
FROM   dbo.Employees
WHERE  Email IS NULL;     -- Email 未登録の社員(中村大輔)がヒット

SELECT LastName, Email
FROM   dbo.Employees
WHERE  Email IS NOT NULL; -- Email 登録済みの社員
```

同様に、部署未定・担当なしなども `IS NULL` で拾います。

```sql
-- 部署が未定の社員(佐々木彩: DepartmentId=NULL)
SELECT LastName, DepartmentId
FROM   dbo.Employees
WHERE  DepartmentId IS NULL;

-- 担当営業が未割り当ての顧客(イオタ商会・ラムダソフト)
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId IS NULL;

-- カテゴリ未分類の商品(高級万年筆・ノベルティグッズ)
SELECT ProductName, CategoryId
FROM   dbo.Products
WHERE  CategoryId IS NULL;
```

三値論理の要点:

- `NULL = NULL` も `NULL <> 何か` も結果は **UNKNOWN**。
- `WHERE` は **TRUE の行だけ**を返す。UNKNOWN の行は「残さない」。
- そのため `<>`・`NOT IN` などの否定条件では、**NULL の行が黙って消える**ことがある。

> ⚠️ 「= NULL が効かない」のは仕様です。必ず `IS NULL` / `IS NOT NULL` を使いましょう。
> (`SET ANSI_NULLS OFF` で挙動を変えることは可能ですが、非推奨・将来廃止予定です。)

## 8. NOT IN に NULL が混ざる落とし穴

`NOT IN (...)` の **リスト側に NULL が含まれる** と、結果が
「常に1行も返らない」という直感に反する挙動になります。

```sql
-- 例: 担当が 2, 3 "以外" の顧客を出したい
-- ✗ サブクエリの結果に NULL が混ざると期待どおりにならない
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId NOT IN (2, 3, NULL);
-- ↑ NULL があると、どの行も TRUE にならず 0 件になる
```

なぜか。`x NOT IN (a, b, NULL)` は
`x <> a AND x <> b AND x <> NULL` と同義です。最後の `x <> NULL` は
**必ず UNKNOWN**。`TRUE AND UNKNOWN = UNKNOWN` なので全体が TRUE になれず、行が残りません。

対策:

```sql
-- ○ 対策1: リスト/サブクエリから NULL を除く
SELECT c.CustomerName, c.SalesRepId
FROM   dbo.Customers AS c
WHERE  c.SalesRepId NOT IN (
           SELECT e.EmployeeId
           FROM   dbo.Employees AS e
           WHERE  e.EmployeeId IS NOT NULL   -- NULL を除外
       );

-- ○ 対策2: NOT EXISTS で書き換える(NULL に強い)
SELECT c.CustomerName, c.SalesRepId
FROM   dbo.Customers AS c
WHERE  NOT EXISTS (
           SELECT 1
           FROM   dbo.Orders AS o
           WHERE  o.CustomerId = c.CustomerId
       );
-- ↑ これは「一度も注文していない顧客」(ラムダソフト)を安全に抽出する例
```

- ちなみに `NOT IN` の **対象列** 側が NULL の行(この例では `SalesRepId IS NULL` の顧客)は、
  そもそも `NULL <> 2` が UNKNOWN のため結果に出てきません。
  「担当がいない顧客も出したい」なら `OR SalesRepId IS NULL` を明示的に足します。

> ⚠️ 実務で `NOT IN (サブクエリ)` を書くときは、**サブクエリ側が NULL を返さないか** を必ず確認。
> 迷ったら `NOT EXISTS` を使うのが安全策です。

## よくあるつまずき

- **`= NULL` で NULL 行が取れない** → `IS NULL` / `IS NOT NULL` を使う。
- **`<>` や `NOT IN` で NULL 行が消える** → 三値論理のため。必要なら `OR 列 IS NULL` を足す。
- **`NOT IN (サブクエリ)` が 0 件になる** → サブクエリに NULL が混ざっている。除外するか `NOT EXISTS` へ。
- **`AND`/`OR` の意図がずれる** → 優先順位は `NOT`→`AND`→`OR`。括弧で固定する。
- **`BETWEEN` が片端を含まないと思っていた** → 両端を **含む**。時刻付きの型では特に注意。
- **日本語の `LIKE` が効かない** → リテラルに `N` を付ける(`LIKE N'ノート%'`)。

## この章のまとめ

- `WHERE` は **TRUE の行だけ** を残す(FALSE と UNKNOWN は除外)。
- 比較 `= <> > < >= <=`、論理 `AND/OR/NOT`(優先順位に注意、括弧で固定)。
- `BETWEEN`(両端含む)、`IN`(OR の短縮)、`LIKE`(`% _ [ ] [^]`)。
- NULL は三値論理。判定は必ず `IS NULL` / `IS NOT NULL`。**`= NULL` は効かない**。
- `<>` / `NOT IN` は NULL 行を落とす。`NOT IN (サブクエリ)` の NULL 混入は `NOT EXISTS` で回避。

➡ 演習: [exercises/02_where_filtering.md](../exercises/02_where_filtering.md)

➡ 次のトピック: [03 並べ替えとページング](../exercises/03_order_paging.md)
