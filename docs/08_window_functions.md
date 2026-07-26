# 08 ウィンドウ関数

> **このトピックのゴール**: `OVER` 句を使って、**行を潰さずに** 集計・順位付け・
> 前後行との比較ができるようになる。順位関数(`ROW_NUMBER`/`RANK`/`DENSE_RANK`/`NTILE`)、
> 累計や構成比、`LAG`/`LEAD`、`FIRST_VALUE`/`LAST_VALUE`、そしてフレーム(`ROWS`/`RANGE`)を理解する。
>
> **前提**: [07 共通テーブル式(CTE)](07_cte.md) を済ませ、`WITH` で中間結果に名前を付けられること。
> `GROUP BY` による集約([05 集約と GROUP BY])も理解していると比較しやすい。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。
明細売上は `Quantity * UnitPrice * (1 - Discount)` で計算します。

## 1. ウィンドウ関数とは — 「行を潰さない集計」

`GROUP BY` は複数行を **1行にまとめて** しまいます。一方 **ウィンドウ関数** は、
各行を残したまま、その行に関連する「窓(ウィンドウ)」に対する集計結果を **横に付け足す** 関数です。

```sql
-- GROUP BY: 部門ごとに 1 行へ潰れる(社員個々の行は消える)
SELECT DepartmentId,
       AVG(Salary) AS 部門平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;

-- ウィンドウ関数: 社員 13 行を残したまま、各行に「所属部門の平均給与」を付ける
SELECT EmployeeId, LastName, DepartmentId, Salary,
       AVG(Salary) OVER (PARTITION BY DepartmentId) AS 部門平均給与
FROM   dbo.Employees;
```

- 後者は **13 行がそのまま返り**、各社員の隣に自分の部門の平均が並びます。
- 「自分の給与は部門平均と比べて高いか低いか」を **1 クエリで** 見られるのがウィンドウ関数の強みです。

> ⚠️ `GROUP BY` を使ったクエリで、集約していない列(`LastName` など)を `SELECT` に混ぜるとエラーになります。
> 「明細行を残したまま集計値も見たい」ときは、`GROUP BY` ではなくウィンドウ関数を使います。

## 2. OVER 句の構造(PARTITION BY / ORDER BY / フレーム)

ウィンドウ関数は必ず `OVER (...)` を伴います。`OVER` の中身は最大 3 つの部品でできています。

```text
関数(...) OVER (
    PARTITION BY 列    -- ① 窓をグループに分ける(省略時は全行が1つの窓)
    ORDER BY     列    -- ② 窓の中での並び順(順位・累計・LAG などで必須)
    フレーム指定       -- ③ ORDER BY がある時、窓の中のどこからどこまでを対象にするか
)
```

- **① PARTITION BY** … `GROUP BY` に似て、窓を分割します。省略すると **全行が 1 つの窓**。
- **② ORDER BY** … 窓の中での順序。順位関数・累計・`LAG`/`LEAD` では意味を持ちます。
- **③ フレーム** … `ROWS`/`RANGE`(第 8 節)。省略すると **既定フレーム** が適用されます(落とし穴あり)。

> ⚠️ `OVER` の中の `ORDER BY` は「窓の中での並び」を決めるだけで、
> **最終的な結果の並び順ではありません**。結果を並べたいなら、別途クエリ末尾に `ORDER BY` を書きます。

## 3. 順位関数 — ROW_NUMBER / RANK / DENSE_RANK

「部門内で給与が高い順に順位を付ける」といった処理は順位関数の出番です。
`PARTITION BY` で部門ごとに分け、`ORDER BY` で順位の基準を決めます。

```sql
-- 部門ごとに、給与の高い順で順位を振る
SELECT DepartmentId, LastName, Salary,
       ROW_NUMBER() OVER (PARTITION BY DepartmentId ORDER BY Salary DESC) AS 部門内順位
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, 部門内順位;
```

3 つの順位関数は **同順位(タイ)の扱い** が違います。次のように、注文件数で顧客を順位付けると差がはっきりします
(注文件数が同じ顧客が複数いるため、タイが発生します)。

```sql
WITH 注文数 AS (
    SELECT CustomerId,
           COUNT(*) AS 注文件数
    FROM   dbo.Orders
    GROUP  BY CustomerId
)
SELECT CustomerId, 注文件数,
       ROW_NUMBER() OVER (ORDER BY 注文件数 DESC) AS row_number,
       RANK()       OVER (ORDER BY 注文件数 DESC) AS rank,
       DENSE_RANK() OVER (ORDER BY 注文件数 DESC) AS dense_rank
FROM   注文数
ORDER  BY 注文件数 DESC, CustomerId;
```

| 関数 | 同順位の扱い | 例(件数 4,3,2,2,2,1,…) |
|---|---|---|
| `ROW_NUMBER()` | タイでも **必ず連番**(重複なし) | 1,2,3,4,5,6,… |
| `RANK()` | タイは **同じ順位**。その後は **番号が飛ぶ** | 1,2,3,3,3,6,… |
| `DENSE_RANK()` | タイは **同じ順位**。その後も **飛ばない** | 1,2,3,3,3,4,… |

- **`ROW_NUMBER`** … とにかく一意の連番が欲しいとき(ページング・重複排除・「各グループの先頭 1 件」など)。
- **`RANK`** … 「3 位タイが 3 人いたら次は 6 位」という一般的な順位付け。
- **`DENSE_RANK`** … 順位を詰めたいとき(「上位 3 グレード」のように **値の種類** で数えたいとき)。

> ⚠️ 順位関数(`ROW_NUMBER`/`RANK`/`DENSE_RANK`)では `OVER` の中の `ORDER BY` が **必須** です。
> 何を基準に順位を付けるか決められないためです。

## 4. 各グループの上位 N 件を取り出す(ROW_NUMBER の定番活用)

`ROW_NUMBER` は「部門ごとの給与トップ 2」のような **グループ別 Top-N** に定番です。
ウィンドウ関数は `WHERE` では直接使えない(評価順序の都合)ため、**CTE で一度列にしてから絞り込みます**。

```sql
-- 各部門で給与が高い順に 2 人まで
WITH 順位付き AS (
    SELECT DepartmentId, LastName, Salary,
           ROW_NUMBER() OVER (PARTITION BY DepartmentId ORDER BY Salary DESC) AS 順位
    FROM   dbo.Employees
    WHERE  DepartmentId IS NOT NULL
)
SELECT DepartmentId, LastName, Salary, 順位
FROM   順位付き
WHERE  順位 <= 2
ORDER  BY DepartmentId, 順位;
```

- 「トップ 1 件だけ」なら `WHERE 順位 = 1`。同順位も含めたいなら `ROW_NUMBER` の代わりに `RANK` を使います。

> ⚠️ `WHERE ROW_NUMBER() OVER (...) <= 2` と直接書くことは **できません**。
> ウィンドウ関数は `SELECT` と `ORDER BY` でしか書けないため、CTE / サブクエリで包んでから絞り込みます。

## 5. NTILE — グループを N 等分する

`NTILE(n)` は、並べた行を **できるだけ均等な n 個のグループ** に分け、各行が何番目のグループかを返します。
四分位(4 等分)や、上位・下位の層分けに使います。

```sql
-- 給与の高い順に、社員を 4 つの層(四分位)に分ける
SELECT LastName, Salary,
       NTILE(4) OVER (ORDER BY Salary DESC) AS 給与四分位
FROM   dbo.Employees
ORDER  BY Salary DESC;
```

- 行数が n で割り切れないときは、**先頭のグループから 1 行ずつ多く** 配分されます
  (13 行を 4 分割 → 4,3,3,3 行)。
- 「上位 25%」を層で扱いたいときは `給与四分位 = 1` を絞り込みます。

## 6. 集約ウィンドウ ① 構成比(全体に対する割合)

`SUM(...) OVER (...)` のような集約関数もウィンドウ関数として使えます。
`ORDER BY` を **付けなければ**、その窓の **全行の合計** が各行に付きます。これを使うと構成比が出せます。

```sql
-- 各社員の給与が、所属部門の給与合計に占める割合(構成比)
SELECT DepartmentId, LastName, Salary,
       SUM(Salary) OVER (PARTITION BY DepartmentId)                              AS 部門給与合計,
       CAST(100.0 * Salary
            / SUM(Salary) OVER (PARTITION BY DepartmentId) AS DECIMAL(5,1))      AS 部門内構成比_pct
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;
```

```sql
-- カテゴリ内で、各商品の単価がカテゴリ合計に占める割合
SELECT c.CategoryName, p.ProductName, p.UnitPrice,
       CAST(100.0 * p.UnitPrice
            / SUM(p.UnitPrice) OVER (PARTITION BY p.CategoryId) AS DECIMAL(5,1)) AS カテゴリ内構成比_pct
FROM   dbo.Products p
JOIN   dbo.Categories c ON c.CategoryId = p.CategoryId
ORDER  BY c.CategoryName, p.UnitPrice DESC;
```

- ポイントは **分母を `SUM(...) OVER (PARTITION BY ...)`** にすること。行を潰さずに「合計」を各行へ配れるので割り算ができます。
- `100.0` のように **小数** で掛けると整数割り算の切り捨てを避けられます。

## 7. 集約ウィンドウ ② 累計(running total)

`SUM(...) OVER (ORDER BY ...)` のように **`ORDER BY` を付ける** と、
「先頭からその行まで」の **累計(running total)** になります。月別売上の累計を出してみます。

```sql
-- 月別売上と、その累計(running total)
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       SUM(月売上) OVER (ORDER BY 月
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS 累計売上
FROM   月次
ORDER  BY 月;
```

- `DATEFROMPARTS(年, 月, 1)` で「その月の 1 日」を作り、月単位にまとめています(2012 以降)。
- 累計は明示的に `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`(= 先頭から現在行まで)と書いています。
  **フレームを省略しても累計になりますが**、既定フレームには落とし穴があります(第 8 節)。

## 8. フレーム — ROWS と RANGE、そして既定フレームの落とし穴

`ORDER BY` を伴うウィンドウ関数では、「窓の中の **どこからどこまで** を計算対象にするか」= **フレーム** を指定できます。

```text
ROWS  BETWEEN <開始> AND <終了>    -- 物理的な「行数」で範囲を数える
RANGE BETWEEN <開始> AND <終了>    -- ORDER BY の「値」で範囲を数える(同値の行=peer をまとめて扱う)
```

主な開始・終了の指定:

- `UNBOUNDED PRECEDING` … 窓の先頭
- `n PRECEDING` … n 行前(`ROWS` の場合)
- `CURRENT ROW` … 現在行
- `n FOLLOWING` … n 行後(`ROWS` の場合)
- `UNBOUNDED FOLLOWING` … 窓の末尾

**既定フレームの落とし穴**: `OVER (ORDER BY ...)` と書いてフレームを省略すると、
既定は **`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** になります。
`RANGE` は「現在行と **ORDER BY の値が同じ行(peer)**」をすべて含めるため、
**キーに重複があると累計が想定とズレます**。

```sql
-- 既定(RANGE)と ROWS の違い。ORDER BY のキーに同値があると差が出る
SELECT LastName, DepartmentId, Salary,
       SUM(Salary) OVER (ORDER BY DepartmentId)                                        AS 累計_既定RANGE,
       SUM(Salary) OVER (ORDER BY DepartmentId
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)             AS 累計_ROWS
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, LastName;
```

- `累計_既定RANGE` … 同じ `DepartmentId` の行は **まとめて** 加算されるため、同部門の行は全員同じ累計値になります。
- `累計_ROWS` … 1 行ずつ物理的に加算されるので、行ごとに増えていきます。
- **「1 行ずつの累計」が欲しいときは、必ず `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` を明示** しましょう。
  `ORDER BY` のキーが一意(重複なし)なら既定 `RANGE` でも同じ結果になりますが、明示する癖が安全です。

> ⚠️ `RANGE` は既定であるうえ、`ROWS` より処理が重くなりがちです。
> 累計・移動集計では **原則 `ROWS` を明示** すると、意図も性能も安定します。

```sql
-- 移動平均の例: 直前 2 か月と当月の 3 か月移動平均
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月, 月売上,
       AVG(月売上) OVER (ORDER BY 月
                         ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS 三か月移動平均
FROM   月次
ORDER  BY 月;
```

## 9. LAG / LEAD — 前後の行と比較する

`LAG`(前の行)・`LEAD`(次の行)は、**同じ列の別の行の値** を現在行に持ってこられます。
「前月比」「前回注文からの間隔」など、時系列の比較に必須です。

```sql
-- 月別売上と、前月売上・前月差・前月比
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       o
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       LAG(月売上)  OVER (ORDER BY 月)                    AS 前月売上,
       月売上 - LAG(月売上) OVER (ORDER BY 月)             AS 前月差,
       CAST(100.0 * 月売上 / LAG(月売上) OVER (ORDER BY 月)
            AS DECIMAL(6,1))                              AS 前月比_pct
FROM   月次
ORDER  BY 月;
```

- `LAG(列)` は 1 行前、`LAG(列, 2)` なら 2 行前。既定では前がなければ `NULL`。
  第 3 引数で既定値を指定できます: `LAG(月売上, 1, 0)`。
- `LEAD` は逆向き(次の行)。同じ書き方です。
- **最初の行は前月がないため `前月売上` が `NULL`**、その行の `前月比` も `NULL` になります(想定どおり)。

```sql
-- 顧客ごとに、前回注文からの日数(注文間隔)
SELECT CustomerId, OrderId, OrderDate,
       LAG(OrderDate) OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId) AS 前回注文日,
       DATEDIFF(DAY,
                LAG(OrderDate) OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId),
                OrderDate)                                                       AS 前回からの日数
FROM   dbo.Orders
ORDER  BY CustomerId, OrderDate, OrderId;
```

## 10. FIRST_VALUE / LAST_VALUE と LAST_VALUE の罠

`FIRST_VALUE` / `LAST_VALUE` は、窓(フレーム)の **最初 / 最後の行の値** を返します。
「部門で最も給与の高い人の名前を各行に付ける」といった用途に使えます。

```sql
-- 各部門の「最高給与者」の名前を、部門の全社員行に付ける
SELECT DepartmentId, LastName, Salary,
       FIRST_VALUE(LastName) OVER (PARTITION BY DepartmentId
                                   ORDER BY Salary DESC)  AS 部門トップ給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;
```

**`LAST_VALUE` の罠**: 既定フレームは `RANGE ... CURRENT ROW`(= 現在行まで)なので、
`LAST_VALUE` を素直に書くと **「窓の末尾」ではなく「現在行」の値** が返り、期待外れになります。
窓全体の最後を取りたいなら **フレームを末尾まで広げます**。

```sql
-- ✗ 誤り: 既定フレームは現在行まで → 各行が「その行自身」の値になってしまう
SELECT DepartmentId, LastName, Salary,
       LAST_VALUE(LastName) OVER (PARTITION BY DepartmentId ORDER BY Salary DESC) AS 誤_最下位給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;

-- ○ 正しい: フレームを末尾まで広げると、部門で最も給与の低い人が全行に付く
SELECT DepartmentId, LastName, Salary,
       LAST_VALUE(LastName) OVER (PARTITION BY DepartmentId ORDER BY Salary DESC
                                  ROWS BETWEEN UNBOUNDED PRECEDING
                                           AND UNBOUNDED FOLLOWING)               AS 部門最下位給与者
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
ORDER  BY DepartmentId, Salary DESC;
```

- 実務では `LAST_VALUE(... ORDER BY x DESC)` を避け、`FIRST_VALUE(... ORDER BY x ASC/DESC)` に **逆向きの ORDER BY** で置き換えるほうが安全でわかりやすいこともあります。

## 11. 顧客ごとの注文連番(ROW_NUMBER の PARTITION BY)

「その顧客にとって何回目の注文か」という連番も、`PARTITION BY` + `ROW_NUMBER` で作れます。

```sql
-- 顧客ごとに、注文を古い順で 1,2,3… と番号付け
SELECT CustomerId, OrderId, OrderDate,
       ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY OrderDate, OrderId) AS 顧客内注文連番
FROM   dbo.Orders
ORDER  BY CustomerId, 顧客内注文連番;
```

- `ORDER BY OrderDate, OrderId` のように **一意になるまでキーを足す** と、連番が安定します
  (同じ日に複数注文があっても順番が確定する)。
- `連番 = 1` を絞り込めば「各顧客の初回注文」だけを取り出せます(第 4 節の Top-N と同じ考え方)。

## よくあるつまずき

- **`WHERE` でウィンドウ関数を使おうとしてエラー** → ウィンドウ関数は `SELECT`/`ORDER BY` だけ。
  CTE / サブクエリで包んでから `WHERE` で絞る。
- **累計が階段状にならず、同じ値が続く** → 既定フレームが `RANGE` のため。
  `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` を明示する。
- **`LAST_VALUE` が現在行の値になる** → 既定フレームは現在行まで。
  `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` で窓全体に広げる。
- **順位が付かない / 意味不明** → 順位関数は `OVER` 内の `ORDER BY` が必須。
- **`OVER` の `ORDER BY` を書いたのに結果が並ばない** → それは窓内の順序指定。
  結果の並びはクエリ末尾の `ORDER BY` で別途指定する。
- **構成比が全部 0 になる** → 整数どうしの割り算で切り捨て。`100.0 *` のように小数を混ぜる。
- **`RANK` と `DENSE_RANK` を取り違える** → タイの後に番号を飛ばすのが `RANK`、詰めるのが `DENSE_RANK`。

## この章のまとめ

- ウィンドウ関数は **行を潰さずに** 集計・順位・前後比較を各行へ付け足す。`GROUP BY` との最大の違いはここ。
- `OVER (PARTITION BY … ORDER BY … フレーム)` の 3 部品を理解する。`OVER` 内の `ORDER BY` は **窓内の順序**。
- 順位: `ROW_NUMBER`(常に連番)/ `RANK`(タイ後に飛ぶ)/ `DENSE_RANK`(タイ後も詰める)/ `NTILE(n)`(n 等分)。
- 集約ウィンドウ: `ORDER BY` なし → 全体合計(構成比)、`ORDER BY` あり → 累計(running total)。
- `LAG`/`LEAD` で前後行と比較(前月比・注文間隔など)。`FIRST_VALUE`/`LAST_VALUE` で窓の端の値。
- **フレームの既定は `RANGE ... CURRENT ROW`**。累計・移動集計・`LAST_VALUE` では **`ROWS` を明示** して落とし穴を避ける。

➡ 演習: [exercises/08_window_functions.md](../exercises/08_window_functions.md)
