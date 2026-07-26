# 11 条件式と NULL 処理

> **このトピックのゴール**: `CASE` 式で値を場合分けし、`COALESCE`/`ISNULL`/`NULLIF`/
> `IIF`/`CHOOSE` を適材適所で使い分けられるようになる。さらに **NULL** が
> 比較・集約・`DISTINCT`・`GROUP BY`・`ORDER BY`・文字列連結でどう扱われるかを
> 体系的に理解し、`CASE` を使った区分分けやピボット的集計まで書けるようにする。
>
> **前提**: [10 ピボットとアンピボット](10_pivot_unpivot.md) までを済ませ、
> NULL と三値論理の基本([02 WHERE による絞り込み](02_where_filtering.md))を
> 押さえていること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. CASE 式 — 検索 CASE

`CASE` は SQL の中で **条件によって値を切り替える** ための式です。
まずは条件を自由に書ける **検索 CASE**(searched CASE)から。

```sql
-- 給与を区分ラベルに変換する
SELECT LastName, FirstName, Salary,
       CASE
           WHEN Salary >= 800000 THEN N'高'
           WHEN Salary >= 500000 THEN N'中'
           ELSE                       N'低'
       END AS 給与区分
FROM   dbo.Employees;
```

- `WHEN 条件 THEN 値` を上から順に評価し、**最初に TRUE になった** `THEN` の値を返します。
- どの `WHEN` にも当てはまらないときは `ELSE` の値。`ELSE` を省くと **NULL** が返ります。
- `CASE` は **式** なので、`SELECT` の列・`WHERE`・`ORDER BY`・`GROUP BY`・
  集約関数の中など、値を書ける場所ならどこにでも置けます。

> ⚠️ `WHEN` は上から順に評価され、**最初に一致したもの勝ち**です。
> 範囲で区分するときは「広い条件を下、狭い条件を上」に並べないと、
> 意図しない枝に落ちます(上の例は大きい閾値から順に並べている)。

## 2. CASE 式 — 単純 CASE

**1つの式を複数の値と等値比較** するだけなら、単純 CASE(simple CASE)が簡潔です。

```sql
-- 部署コードを名称に置き換える(等値比較の連続)
SELECT LastName, DepartmentId,
       CASE DepartmentId
           WHEN 1 THEN N'営業部'
           WHEN 2 THEN N'開発部'
           WHEN 3 THEN N'マーケティング部'
           WHEN 4 THEN N'人事部'
           WHEN 5 THEN N'経理部'
           ELSE        N'未配属'
       END AS 部署名
FROM   dbo.Employees;
```

- `CASE 式 WHEN 値1 THEN … WHEN 値2 THEN … END` は
  `式 = 値1`、`式 = 値2`… の等値比較を順に行う糖衣構文です。
- 検索 CASE で `WHEN DepartmentId = 1 THEN …` と書いても同じ結果になります。

> ⚠️ 単純 CASE は内部で **`=` 比較** を使います。`= NULL` は常に UNKNOWN なので、
> `CASE DepartmentId WHEN NULL THEN …` は **決して一致しません**。
> NULL を判定したいときは検索 CASE で `WHEN DepartmentId IS NULL THEN …` と書きます。
> (上の例では `DepartmentId=NULL` の佐々木彩は `ELSE` の「未配属」に落ちます。)

## 3. COALESCE と ISNULL — NULL を既定値で置き換える

「NULL のときだけ代わりの値を出す」典型パターンです。よく似た2つの関数があります。

```sql
-- Email 未登録を「(未登録)」と表示する
SELECT LastName, FirstName,
       COALESCE(Email, N'(未登録)') AS メール,   -- 標準SQL
       ISNULL(Email,  N'(未登録)') AS メール2     -- SQL Server 専用
FROM   dbo.Employees;
```

どちらも「Email が NULL なら『(未登録)』」を返しますが、**中身はかなり違います**。

| | `COALESCE` | `ISNULL` |
|---|---|---|
| 標準準拠 | **ANSI 標準** | SQL Server 専用(非標準) |
| 引数の個数 | **2個以上**(可変) | **2個固定** |
| 戻り値の型 | 引数群のうち **データ型の優先順位が最も高い型** | **第1引数の型**に合わせる |
| 実体 | `CASE` 式に展開される | 組み込み関数 |
| 第1引数の評価回数 | 複数回評価されうる(副問い合わせ注意) | 1回 |

**引数の個数**: `COALESCE` は「最初に NULL でない値」を返すので、候補を何個でも並べられます。

```sql
-- 受注担当(Orders.EmployeeId)→ 顧客の営業担当(SalesRepId)→ それも無ければ 0
SELECT o.OrderId,
       COALESCE(o.EmployeeId, c.SalesRepId, 0) AS 担当者ID
FROM   dbo.Orders   AS o
JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId;
```

**戻り型の違い(落とし穴)**: `ISNULL` は結果を **第1引数の型・長さ** に合わせます。
第1引数が短い型だと、第2引数が **切り詰められる** ことがあります。

```sql
-- ISNULL は第1引数 varchar(3) に合わせるため 'ABCDEF' が 'ABC' に切られる
SELECT ISNULL(CAST(NULL AS varchar(3)), 'ABCDEF') AS 切り詰め;   -- → 'ABC'
-- COALESCE は型優先順位で決まるため切られない
SELECT COALESCE(CAST(NULL AS varchar(3)), 'ABCDEF') AS 非切詰;   -- → 'ABCDEF'
```

- 迷ったら **`COALESCE` を既定**にするのがおすすめ(標準・多引数・型の直感が素直)。
- `ISNULL` は「2引数で速く書きたい」「戻り型を第1引数に固定したい」ときに。

> ⚠️ `COALESCE(サブクエリ, 既定値)` のように第1引数が副問い合わせだと、
> `CASE` 展開の都合で **サブクエリが2回評価される** ことがあります。
> 重い副問い合わせでは性能に注意しましょう。

## 4. NULLIF — 等しいときだけ NULL にする

`NULLIF(a, b)` は **`a = b` なら NULL**、そうでなければ `a` を返します。
`COALESCE`/`ISNULL` の逆向き(値 → NULL)の道具です。

```sql
-- ゼロ除算を避ける: 分母が 0 なら NULL にして割り算を NULL にする
SELECT ProductId,
       SUM(Quantity)                                   AS 数量計,
       SUM(Quantity * UnitPrice * (1 - Discount))
         / NULLIF(SUM(Quantity), 0)                    AS 単位あたり売上
FROM   dbo.OrderDetails
GROUP  BY ProductId;
```

- `SUM(Quantity)` が 0 のとき `NULLIF(..., 0)` が NULL になり、`x / NULL = NULL` で
  例外(ゼロ除算エラー)を回避できます。
- `NULLIF(a, b)` は内部的に `CASE WHEN a = b THEN NULL ELSE a END` と等価です。
  よって `a` が NULL のときは `a = b` が UNKNOWN となり、結果は NULL になります。

## 5. IIF — 2分岐の CASE を短く

`IIF(条件, 真の値, 偽の値)`(SQL Server 2012 以降)は、
**2択の検索 CASE** を短く書くための糖衣構文です。

```sql
-- 未出荷(ShipDate が NULL)フラグを立てる
SELECT OrderId, OrderDate, ShipDate,
       IIF(ShipDate IS NULL, N'未出荷', N'出荷済') AS 出荷状況
FROM   dbo.Orders;
```

- `IIF(cond, a, b)` は `CASE WHEN cond THEN a ELSE b END` と完全に等価です。
- 3分岐以上になるなら、無理に `IIF` をネストせず素直に `CASE` を使いましょう。

> ⚠️ `IIF` は SQL Server 2012 以降の機能です。それ以前や他DBへの移植を考えるなら
> `CASE` のほうが安全です。

## 6. CHOOSE — 番号でリストから選ぶ

`CHOOSE(索引, 値1, 値2, …)`(SQL Server 2012 以降)は、
**1 始まりの整数** で候補リストから値を選びます。

```sql
-- DepartmentId(1〜5)を番号で名称に変換する
SELECT LastName, DepartmentId,
       CHOOSE(DepartmentId, N'営業部', N'開発部', N'マーケ部', N'人事部', N'経理部')
         AS 部署名
FROM   dbo.Employees;
```

- 索引が **1 未満・リスト個数超・NULL** のときは **NULL** を返します。
  上の例で `DepartmentId=NULL` の社員は結果も NULL になります。
- 索引が連番のコード値にきれいに対応するときだけ有効。歯抜けや条件分岐には `CASE` を。

## 7. 三値論理の総まとめ

SQL の条件評価は TRUE / FALSE に **UNKNOWN** を加えた **三値論理** です。
NULL が絡むと結果は UNKNOWN になり、これが各所の挙動の根っこにあります。

- `NULL = 何か`・`NULL <> 何か`・`NULL > 何か` は **すべて UNKNOWN**。
- NULL 判定は必ず **`IS NULL` / `IS NOT NULL`**(`= NULL` は効かない)。
- `WHERE`・`ON`・`HAVING` は **TRUE の行だけ** を残す(FALSE と UNKNOWN は落とす)。
- `CHECK` 制約は逆で、**UNKNOWN を許可** する(FALSE だけを弾く)。

論理演算の要点(`AND`/`OR`/`NOT` と UNKNOWN):

| 式 | 結果 |
|---|---|
| `TRUE  AND UNKNOWN` | UNKNOWN |
| `FALSE AND UNKNOWN` | **FALSE**(片方が FALSE なら確定) |
| `TRUE  OR  UNKNOWN` | **TRUE**(片方が TRUE なら確定) |
| `FALSE OR  UNKNOWN` | UNKNOWN |
| `NOT UNKNOWN` | UNKNOWN |

```sql
-- CASE でも三値論理は同じ。条件が UNKNOWN の WHEN は「一致しない」扱い。
SELECT LastName, Email,
       CASE WHEN Email = N'x' THEN N'一致'   -- Email が NULL なら UNKNOWN → この枝は選ばれない
            ELSE N'不一致または未登録'
       END AS 判定
FROM   dbo.Employees;
```

> ⚠️ `CASE` の `WHEN` 条件が UNKNOWN のときは「TRUE ではない」ので、その枝は選ばれず
> 次の `WHEN`(最終的には `ELSE`)へ進みます。NULL を別扱いしたいなら
> **明示的に `WHEN 列 IS NULL THEN …` を先頭付近に書く** のが安全です。

## 8. NULL は集約・DISTINCT・GROUP BY・ORDER BY・連結でどう扱われるか

NULL の振る舞いは句ごとに異なります。まとめて押さえましょう。

### 8-1. 集約関数は NULL を無視する(COUNT(*) は例外)

```sql
SELECT COUNT(*)        AS 全社員数,      -- 13(NULL 行も数える)
       COUNT(Email)    AS メール登録数,  -- 12(Email が NULL の中村を除外)
       COUNT(DISTINCT DepartmentId) AS 部署種類数,  -- NULL は数えない
       AVG(Salary)     AS 平均給与        -- NULL があればその行は分母からも除外
FROM   dbo.Employees;
```

- `COUNT(*)` は **行数** を数える(NULL を含めて全行)。
- `COUNT(列)`・`SUM`・`AVG`・`MIN`・`MAX` は **NULL を無視** する。
  特に `AVG` は「NULL でない値の合計 ÷ NULL でない値の個数」で、**分母も NULL を除く**。
- 集約対象が全部 NULL なら `SUM`/`AVG`/`MIN`/`MAX` は **NULL**(0 ではない)。

### 8-2. DISTINCT と GROUP BY は NULL を「1つの値」とみなす

```sql
-- DepartmentId で集計。NULL(佐々木彩)は 1 グループにまとまる
SELECT DepartmentId, COUNT(*) AS 人数
FROM   dbo.Employees
GROUP  BY DepartmentId;

-- DISTINCT でも複数の NULL は 1 つに畳まれる
SELECT DISTINCT DepartmentId
FROM   dbo.Employees;
```

- `=` では「NULL = NULL は UNKNOWN」なのに、`GROUP BY`/`DISTINCT` では
  **NULL 同士は同じ** とみなされ、1つのグループ/1行にまとまります(集合演算の都合)。
- ラベルを付けたいときは `CASE`/`COALESCE` を **GROUP BY と SELECT の両方** に書きます。

```sql
-- NULL 部署を「未配属」ラベルで集計
SELECT COALESCE(CAST(DepartmentId AS NVARCHAR(10)), N'未配属') AS 部署,
       COUNT(*) AS 人数
FROM   dbo.Employees
GROUP  BY COALESCE(CAST(DepartmentId AS NVARCHAR(10)), N'未配属');
```

### 8-3. ORDER BY では NULL は最小(昇順で先頭)

```sql
-- SQL Server は NULL を最小扱い。昇順だと NULL が先頭に来る
SELECT LastName, Email
FROM   dbo.Employees
ORDER  BY Email ASC;      -- Email が NULL の行が先頭

-- NULL を必ず最後に回したいときは CASE の補助キーを足す
SELECT LastName, Email
FROM   dbo.Employees
ORDER  BY CASE WHEN Email IS NULL THEN 1 ELSE 0 END,  -- NULL を後ろへ
          Email ASC;
```

- SQL Server には `NULLS LAST` 構文が無いため、`CASE` の補助キーで制御します。

### 8-4. 文字列連結は方式で NULL の扱いが変わる

```sql
SELECT LastName,
       LastName + N'/' + Email                 AS 連結_プラス,   -- NULL 伝播で全体 NULL
       CONCAT(LastName, N'/', Email)           AS 連結_CONCAT,   -- NULL を空文字扱い
       CONCAT_WS(N'/', LastName, Email)         AS 連結_WS        -- 区切り込みで NULL 無視
FROM   dbo.Employees;
```

- `+` 連結は **片方が NULL だと結果全体が NULL**。
- `CONCAT`(2012+)は NULL を **空文字** として扱い、他の値は残る。
- `CONCAT_WS`(2017+)は区切り文字付き連結で、NULL の引数を **飛ばす**。
- 集約連結の `STRING_AGG`(2017+)も **NULL を無視** して連結します。

## 9. CASE を使った区分分けとピボット的集計

`CASE` を集約関数の中に入れると、**条件ごとの縦横集計(ピボット)** が書けます。

```sql
-- 給与区分ごとの人数を1行に横並びで集計する
SELECT
    SUM(CASE WHEN Salary >= 800000 THEN 1 ELSE 0 END) AS 高,
    SUM(CASE WHEN Salary >= 500000
             AND  Salary <  800000 THEN 1 ELSE 0 END) AS 中,
    SUM(CASE WHEN Salary <  500000 THEN 1 ELSE 0 END) AS 低
FROM   dbo.Employees;
```

- `SUM(CASE WHEN 条件 THEN 1 ELSE 0 END)` は「条件を満たす行数」= 条件付きカウント。
  `COUNT(CASE WHEN 条件 THEN 1 END)`(ELSE 無しで NULL → COUNT が無視)でも同じ。
- 列見出しに区分を割り当てることで、`GROUP BY` せずに横持ち集計ができます。

条件付きの **金額集計**(未出荷を除いた売上など)にも使えます。

```sql
-- 出荷済みだけの売上と、未出荷を含む全売上を並べて出す
SELECT
    SUM(CASE WHEN o.ShipDate IS NOT NULL
             THEN od.Quantity * od.UnitPrice * (1 - od.Discount)
             ELSE 0 END)                                   AS 出荷済売上,
    SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))    AS 全売上
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId;
```

区分ラベルで **縦持ち** に集計するなら `GROUP BY` に `CASE` を置きます。

```sql
-- 商品を価格帯で区分して、区分ごとの商品数と平均単価
SELECT CASE WHEN UnitPrice >= 10000 THEN N'高価格'
            WHEN UnitPrice >= 1000  THEN N'中価格'
            ELSE                         N'低価格'
       END                    AS 価格帯,
       COUNT(*)               AS 商品数,
       AVG(UnitPrice)         AS 平均単価
FROM   dbo.Products
GROUP  BY CASE WHEN UnitPrice >= 10000 THEN N'高価格'
               WHEN UnitPrice >= 1000  THEN N'中価格'
               ELSE                         N'低価格'
          END;
```

> ⚠️ `SELECT` の別名は `GROUP BY` では使えません([01 の評価順序](01_select_basics.md))。
> そのため上のように **同じ `CASE` 式を SELECT と GROUP BY の両方** に書く必要があります。
> 重複が気になるなら、サブクエリ/CTE で先に区分列を作ってから `GROUP BY` すると1回で済みます。

## よくあるつまずき

- **単純 CASE で NULL を拾えない** → `WHEN NULL` は `= NULL` で常に UNKNOWN。
  検索 CASE の `WHEN 列 IS NULL THEN …` を使う。
- **`ISNULL` で第2引数が切れる/型が想定外** → 戻り型が第1引数に合わせられるため。
  型の直感が欲しいなら `COALESCE`。
- **`+` 連結の結果が丸ごと NULL** → NULL 伝播。`CONCAT`/`CONCAT_WS` を使う。
- **NULL 部署が集計から消える/別枠になる** → `SUM`/`AVG` は NULL 無視、
  `GROUP BY`/`DISTINCT` は NULL を1グループに畳む。ラベルは `COALESCE` を SELECT と GROUP BY 両方に。
- **ORDER BY で NULL が先頭に来て驚く** → SQL Server は NULL 最小。
  `CASE WHEN 列 IS NULL THEN 1 ELSE 0 END` を補助キーに足す。
- **ゼロ除算エラー** → 分母を `NULLIF(分母, 0)` にして NULL 化する。
- **`AVG` が思ったより高い/低い** → NULL は分母から除外される。0 として数えたいなら
  `AVG(COALESCE(列, 0))` のように明示する。

## この章のまとめ

- `CASE` は式。**検索 CASE**(条件自由)と **単純 CASE**(等値比較)を使い分ける。
  `WHEN` は上から順、最初の一致が勝ち。`ELSE` 省略時は NULL。
- NULL 既定値は `COALESCE`(標準・多引数・型が素直)を基本に、`ISNULL`(2引数・戻り型は第1引数)を補助的に。
- `NULLIF(a,b)` は `a=b` のとき NULL(ゼロ除算回避に有用)。
- `IIF` は2分岐 CASE、`CHOOSE` は1始まりの番号選択(いずれも 2012+、範囲外/NULL は NULL)。
- **三値論理**: NULL 絡みは UNKNOWN。判定は `IS NULL`。`CASE` の UNKNOWN 枝は選ばれない。
- NULL の句別挙動: 集約は無視(`COUNT(*)` 除く)/ `DISTINCT`・`GROUP BY` は1つに畳む /
  `ORDER BY` は最小 / `+` 連結は伝播・`CONCAT` は空文字扱い。
- `SUM(CASE WHEN … THEN 1 ELSE 0 END)` で条件付き集計・ピボット的な横持ちができる。

➡ 演習: [exercises/11_conditional_null.md](../exercises/11_conditional_null.md)

➡ 次のトピック: [12 組み込み関数](../exercises/12_builtin_functions.md)
