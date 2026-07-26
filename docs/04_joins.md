# 04 テーブル結合 (JOIN)

> **このトピックのゴール**: 複数のテーブルを `JOIN` で結び付けて、1つの結果に
> まとめられるようになる。内部結合・外部結合の違い、`ON` と `WHERE` の使い分け、
> 自己結合を理解する。
>
> **前提**: [03 並べ替えとページング](03_order_paging.md) を済ませ、
> 1テーブルからの取得・絞り込み・並べ替えができること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. なぜ結合が要るのか

`SalesLearning` はデータを目的別のテーブルに分けて持っています。
たとえば「どの社員がどの部署か」を知るには、`Employees` の `DepartmentId` を
`Departments` の `DepartmentId` に突き合わせる必要があります。この突き合わせが **結合 (JOIN)** です。

```sql
SELECT Employees.LastName, Departments.DepartmentName
FROM   dbo.Employees
JOIN   dbo.Departments
       ON Employees.DepartmentId = Departments.DepartmentId;
```

- `JOIN`(= `INNER JOIN`)は、`ON` の条件を満たす行同士だけを結び付けます。
- `ON` には **結合条件**(どの列とどの列を突き合わせるか)を書きます。

## 2. INNER JOIN と ON

`INNER JOIN` は、**両方のテーブルで条件が一致した行だけ**を返します。
どちらか一方にしか存在しない行は結果から落ちます。

```sql
-- 社員と、その所属部署名
SELECT Employees.EmployeeId,
       Employees.LastName,
       Departments.DepartmentName
FROM   dbo.Employees
INNER JOIN dbo.Departments
       ON Employees.DepartmentId = Departments.DepartmentId;
```

- `INNER` は省略でき、`JOIN` だけでも内部結合になります。本書では意図を明確にするため `INNER JOIN` と書きます。
- この結果には **部署が NULL の社員(佐々木彩)** は現れません。`ON` で一致しないためです。
- 同様に、**社員が1人もいない経理部** も現れません。

> ⚠️ `INNER JOIN` は「両側にある行だけ」。`NULL` 同士は決して一致しません
> (`NULL = NULL` は真になりません)。片側にしかない行も拾いたいときは、後述の外部結合を使います。

## 3. テーブル別名(エイリアス)

テーブル名を毎回書くのは冗長です。`AS` でテーブルに **別名** を付けると簡潔になります。

```sql
SELECT e.EmployeeId,
       e.LastName,
       d.DepartmentName
FROM   dbo.Employees   AS e
INNER JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId;
```

- テーブル別名は `AS` を省略して `dbo.Employees e` とも書けます。
- 別名を付けたら、それ以降は **別名で参照**します(`Employees.LastName` ではなく `e.LastName`)。
- 同じ列名が両テーブルにある場合(`DepartmentId` など)は、`e.DepartmentId` のように
  **必ず別名で修飾**しないと「あいまいな列名」エラーになります。

本書ではこれ以降、テーブル別名を使って書きます。

## 4. LEFT / RIGHT / FULL OUTER JOIN

外部結合は「片方に一致相手がいなくても、その行を残す」結合です。
一致相手がない側の列は **NULL** で埋められます。

### LEFT OUTER JOIN(左表を全部残す)

```sql
-- すべての社員を残し、部署があれば部署名も付ける
SELECT e.LastName,
       d.DepartmentName
FROM   dbo.Employees   AS e
LEFT JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId;
```

- `FROM` 側(左)の `Employees` は **全行**が残ります。
- 部署が NULL の **佐々木彩** も残り、`DepartmentName` は NULL になります。
- `OUTER` は省略可能(`LEFT JOIN` = `LEFT OUTER JOIN`)。

「注文が1件もない顧客」を拾うのも LEFT JOIN の典型です。

```sql
-- すべての顧客を残し、注文があれば OrderId も付ける。
-- 注文なしの顧客(ラムダソフト)は OrderId が NULL で現れる。
SELECT c.CustomerName,
       o.OrderId
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId;
```

### RIGHT OUTER JOIN(右表を全部残す)

`LEFT` の左右が入れ替わっただけです。`FROM` の後ろ(右)のテーブルを全行残します。

```sql
-- すべての部署を残し、所属社員がいれば社員名も付ける。
-- 社員のいない経理部も残り、社員側の列は NULL になる。
SELECT d.DepartmentName,
       e.LastName
FROM   dbo.Employees   AS e
RIGHT JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId;
```

> 💡 `RIGHT JOIN` は、テーブルの順番を入れ替えれば `LEFT JOIN` で同じことが書けます。
> 実務では **LEFT JOIN に統一**したほうが読みやすい、という流儀が一般的です。

### FULL OUTER JOIN(両方とも全部残す)

```sql
-- 社員のいない部署も、部署のない社員も、両方拾う
SELECT e.LastName,
       d.DepartmentName
FROM   dbo.Employees   AS e
FULL OUTER JOIN dbo.Departments AS d
       ON e.DepartmentId = d.DepartmentId;
```

- 左右どちらの「相手なし」行も残ります。相手のない側は NULL になります。
- ここでは **部署なしの佐々木彩**(部署名が NULL)と **社員なしの経理部**(社員名が NULL)の
  両方が結果に現れます。

## 5. CROSS JOIN(直積)

`CROSS JOIN` は結合条件を持たず、**左の全行 × 右の全行** の組み合わせをすべて返します。

```sql
-- 全カテゴリ × 全地域の組み合わせ表(条件なし)
SELECT c.CategoryName, r.Region
FROM   dbo.Categories AS c
CROSS JOIN (SELECT DISTINCT Region FROM dbo.Customers) AS r;
```

- 行数は「左の行数 × 右の行数」に膨れます。意図せぬ `CROSS JOIN` は事故のもとです。
- 「ありうる全組み合わせを作ってから、実データと突き合わせる」ような用途で使います。

> ⚠️ `ON` を書き忘れた結合や、`FROM A, B` のようにカンマで並べて `WHERE` の結合条件を
> 書き忘れると、実質 `CROSS JOIN` になり **行数が爆発**します。

## 6. 3テーブル以上の多段結合

`JOIN` は必要なだけ連ねられます。前の結合結果に次のテーブルを足していくイメージです。

```sql
-- 注文 × 顧客 × 受注担当社員 を1つにまとめる
SELECT o.OrderId,
       o.OrderDate,
       c.CustomerName,
       e.LastName AS 受注担当
FROM   dbo.Orders    AS o
INNER JOIN dbo.Customers AS c ON o.CustomerId = c.CustomerId
INNER JOIN dbo.Employees AS e ON o.EmployeeId = e.EmployeeId
ORDER BY o.OrderId;
```

さらに明細まで足せば、注文明細の金額まで一気に取れます。

```sql
-- 注文明細の売上金額(明細単位)
SELECT o.OrderId,
       c.CustomerName,
       p.ProductName,
       od.Quantity * od.UnitPrice * (1 - od.Discount) AS 明細売上
FROM   dbo.Orders        AS o
INNER JOIN dbo.Customers     AS c  ON o.CustomerId = c.CustomerId
INNER JOIN dbo.OrderDetails  AS od ON o.OrderId    = od.OrderId
INNER JOIN dbo.Products      AS p  ON od.ProductId = p.ProductId
ORDER BY o.OrderId, p.ProductName;
```

- 明細金額は本プロジェクト共通で `Quantity * UnitPrice * (1 - Discount)` で計算します。
- 多段結合では、途中に1つでも `INNER JOIN` を混ぜると、その条件で行が落ちる点に注意します。
  「全顧客を必ず残したい」なら、その顧客より右側の結合はすべて `LEFT JOIN` にします。

## 7. 自己結合(同じテーブルを2回使う)

`Employees` は `ManagerId` で **自分自身(上司の EmployeeId)** を参照しています。
同じテーブルに **異なる別名** を2つ付ければ、社員と上司を並べられます。

```sql
-- 社員と、その上司の氏名
SELECT e.LastName  AS 社員,
       m.LastName  AS 上司
FROM   dbo.Employees AS e
LEFT JOIN dbo.Employees AS m
       ON e.ManagerId = m.EmployeeId
ORDER BY e.EmployeeId;
```

- `e` を「社員」、`m` を「上司」として同じテーブルを2役で使います。これが **自己結合**です。
- `INNER JOIN` にすると、上司がいない **社長(佐藤太郎, ManagerId=NULL)** が消えてしまいます。
  社長も残したいので `LEFT JOIN` を使っています。
- 同じテーブルを2回使うため、**別名は必須**です(付けないと区別できません)。

## 8. 結合条件を ON に書くか WHERE に書くか(最重要の落とし穴)

`INNER JOIN` では、追加の絞り込みを `ON` に書いても `WHERE` に書いても
**結果は同じ**です(内部結合はどうせ一致行しか残らないため)。

ところが **外部結合では話がまったく違います**。

```sql
-- (A) 右側テーブルの条件を ON に書く
--     → 未出荷(ShipDate が NULL)の注文も含め、全注文が残る。
--        出荷済みでない注文は Orders 側だけ残り、条件は「付加情報」として働く。
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
      AND o.ShipDate IS NOT NULL;
```

```sql
-- (B) 同じ条件を WHERE に書く
--     → LEFT JOIN が実質 INNER JOIN に化ける。
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
WHERE  o.ShipDate IS NOT NULL;
```

何が起きているのか:

- (B) では、注文のない顧客(ラムダソフト)は `o.ShipDate` が NULL のまま `WHERE` に渡ります。
  `NULL IS NOT NULL` は偽なので、その行は捨てられます。**外部結合で残したかった行が消える**のです。
- つまり「右側テーブルの列に対する条件を `WHERE` に書く」と、外部結合が **実質 INNER 結合**になります。

> ⚠️ 覚え方: **外部結合で「残したい側」を守る条件は `ON` に、
> 結果を絞り込む条件は `WHERE` に**。特に「右側テーブルの列 = 値」を `WHERE` に書くと
> LEFT JOIN が INNER 化する、という落とし穴に注意。
>
> 逆に、`WHERE o.OrderId IS NULL` のように「NULL であること」を条件にすると、
> **一致相手のない行だけ**(= 注文のない顧客)を抽出できます。これは正しい使い方です。

```sql
-- 注文が1件もない顧客だけを抽出(LEFT JOIN + IS NULL の定番パターン)
SELECT c.CustomerName
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o ON c.CustomerId = o.CustomerId
WHERE  o.OrderId IS NULL;   -- → ラムダソフトだけが残る
```

## 9. 外部結合で生じる NULL の扱い

外部結合で埋められた NULL は、計算や連結で注意が要ります。

```sql
-- 顧客と担当営業(Customers.SalesRepId → Employees.EmployeeId)。
-- 担当が未設定の顧客(イオタ商会・ラムダソフト)も残す。
SELECT c.CustomerName,
       ISNULL(e.LastName, N'(担当未設定)') AS 担当営業
FROM   dbo.Customers AS c
LEFT JOIN dbo.Employees AS e
       ON c.SalesRepId = e.EmployeeId
ORDER BY c.CustomerId;
```

- 担当のない顧客は `e.LastName` が NULL になります。`ISNULL` や `COALESCE` で
  代替表示にすると読みやすくなります。
- NULL を含む数値列を集計するときは、`SUM` は NULL を無視しますが、`+` 連結は
  片方が NULL だと全体が NULL になる、といった NULL の性質([01](01_select_basics.md) 参照)を思い出してください。

## よくあるつまずき

- **INNER JOIN で行が消える** → 片側にしかない行は落ちる。残したいなら外部結合。
- **「あいまいな列名」エラー** → 両テーブルに同名列があるのに修飾していない。`e.DepartmentId` のように別名で修飾する。
- **LEFT JOIN したのに右側の行が消える** → 右側テーブルの条件を `WHERE` に書いた。`ON` に移すか、意図どおりか見直す。
- **自己結合で社長が消える** → 上司 NULL の行は INNER だと落ちる。`LEFT JOIN` にする。
- **行数が爆発した** → `ON`(または結合条件)の書き忘れで実質 `CROSS JOIN` になっている。

## この章のまとめ

- `INNER JOIN` は両側一致行のみ。`ON` に結合条件を書く。
- `LEFT/RIGHT/FULL OUTER JOIN` は片側(または両側)の「相手なし」行を NULL 付きで残す。
- テーブル別名で簡潔に書き、同名列は必ず修飾する。
- `CROSS JOIN` は直積。条件書き忘れの事故に注意。
- 3テーブル以上は `JOIN` を連ねる。全件残したい側の右は `LEFT JOIN` で。
- 自己結合は同じテーブルに別名2つ(社員と上司)。
- **外部結合では、右側テーブルの絞り込み条件を `WHERE` に書くと実質 INNER 化する**。
  「残す条件は `ON`、絞る条件は `WHERE`」「相手なし抽出は `IS NULL`」。

➡ 演習: [exercises/04_joins.md](../exercises/04_joins.md)
