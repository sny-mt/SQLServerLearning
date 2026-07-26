# 21 実務頻出クエリパターン集

> **このトピックのゴール**: 現場で繰り返し登場する定番の要件を、**すぐ思い出せる型(パターン)**
> として身につける。「グループごとの最新行」「重複削除」「ギャップ&アイランド」「番号表」
> 「累計・前年同月比」「カンマ区切り連結」「帳票用のクロス集計」「カーソルを使わない発想」の
> 8 パターンを、**業務要件 → 解法 → なぜそう書くか** の順で押さえる。
>
> **前提**: [20 動的SQL](20_dynamic_sql.md) までを済ませ、`JOIN` / `CTE` /
> [ウィンドウ関数](08_window_functions.md) / [APPLY](14_apply.md) を読み書きできること。
> `SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。
明細売上は `Quantity * UnitPrice * (1 - Discount)` で計算します。

この章は **レシピ集** です。前から順に読んでもよいですが、
実務で「あの書き方どうだったっけ」と思ったときに **該当パターンだけ引く** 使い方を想定しています。

> ⚠️ **データを変更する例について**
> 本章にはデータを書き換える例(重複削除など)が含まれます。
> サンプルDBを壊さないよう、**必ず `BEGIN TRAN … ROLLBACK` で囲むか、一時テーブル(`#名前`)の
> コピーに対して操作** しています。この方針は [13 データ操作](13_dml.md) と同じです。
> 自分で試すときも同じ型を守ってください。

---

## 1. パターン① グループごとの最新行 / 上位 N 行

### どんな業務要件で必要になるか

- 「顧客一覧に、**その顧客の最新注文日** を並べて表示したい」
- 「カテゴリごとの **売れ筋トップ3** を出したい」
- 「社員ごとの **直近の受注案件** を一覧にしたい」

いずれも「グループの中で並べて、上から N 件だけ」という同じ形です。
SQL Server には主に **`ROW_NUMBER()` 版** と **`CROSS APPLY` 版** の 2 つの解法があります。

### 解法 A: ROW_NUMBER() 版

```sql
-- 顧客ごとの「最新の注文」1件
WITH 順位付き AS (
    SELECT o.CustomerId,
           o.OrderId,
           o.OrderDate,
           ROW_NUMBER() OVER (PARTITION BY o.CustomerId
                              ORDER BY o.OrderDate DESC, o.OrderId DESC) AS 新しい順
    FROM   dbo.Orders AS o
)
SELECT c.CustomerId,
       c.CustomerName,
       r.OrderId   AS 最新注文Id,
       r.OrderDate AS 最新注文日
FROM   dbo.Customers AS c
JOIN   順位付き       AS r ON r.CustomerId = c.CustomerId
WHERE  r.新しい順 = 1
ORDER  BY c.CustomerId;
```

上位 N 件に広げたいときは、`= 1` を `<= N` に変えるだけです。

```sql
-- カテゴリごとに、単価の高い商品トップ3
WITH 順位付き AS (
    SELECT p.CategoryId,
           p.ProductName,
           p.UnitPrice,
           ROW_NUMBER() OVER (PARTITION BY p.CategoryId
                              ORDER BY p.UnitPrice DESC, p.ProductId) AS 順位
    FROM   dbo.Products AS p
    WHERE  p.CategoryId IS NOT NULL
)
SELECT cat.CategoryName, r.ProductName, r.UnitPrice, r.順位
FROM   順位付き        AS r
JOIN   dbo.Categories AS cat ON cat.CategoryId = r.CategoryId
WHERE  r.順位 <= 3
ORDER  BY cat.CategoryName, r.順位;
```

### 解法 B: CROSS APPLY / OUTER APPLY 版

```sql
-- 顧客ごとの「最新の注文」1件(APPLY 版)
SELECT c.CustomerId,
       c.CustomerName,
       o.OrderId   AS 最新注文Id,
       o.OrderDate AS 最新注文日
FROM   dbo.Customers AS c
CROSS  APPLY (
    SELECT TOP (1) o2.OrderId, o2.OrderDate
    FROM   dbo.Orders AS o2
    WHERE  o2.CustomerId = c.CustomerId
    ORDER  BY o2.OrderDate DESC, o2.OrderId DESC
) AS o
ORDER  BY c.CustomerId;
```

`TOP (1)` を `TOP (3)` にすれば、そのまま **グループ別トップ3** になります。

### なぜそう書くか — 2 つの版の使い分け

| 観点 | `ROW_NUMBER()` 版 | `CROSS APPLY` 版 |
|---|---|---|
| 処理の形 | 明細を **全部** 番号付けしてから捨てる | 親 1 行ごとに **必要な N 件だけ** 取りにいく |
| 得意な場面 | 親を絞らず **全グループ** を処理する / 明細テーブルが小さい | 親が少数に絞られている / 明細が巨大で **(グループキー, 並び順キー)** のインデックスがある |
| 「該当なし」の親 | `JOIN` だと消える(`LEFT JOIN` が必要) | `OUTER APPLY` にすれば **NULL 付きで残る** |
| 読みやすさ | 「上位N」の意図が `順位 <= N` で明快 | サブクエリの `TOP` がそのまま意図になる |

- **`CROSS APPLY` は「親の行数 × インデックスシーク」** で動きます。
  親が 12 行なら 12 回シークするだけなので、明細が 100 万行あっても速い、という形になります。
- **`ROW_NUMBER()` は明細を一度全部並べ替えます**。親を絞らないバッチ集計なら、
  こちらのほうがスキャン 1 回で済んで有利です。
- 迷ったら **両方書いて実行プランを比べる** のが確実です([18 インデックスと実行プラン](18_indexes_execution_plans.md))。

**「注文のない顧客も残したい」** ときは `OUTER APPLY` が簡潔です。

```sql
-- 注文のない顧客(11 ラムダソフト)も NULL 付きで残す
SELECT c.CustomerId,
       c.CustomerName,
       o.OrderId   AS 最新注文Id,
       o.OrderDate AS 最新注文日
FROM   dbo.Customers AS c
OUTER  APPLY (
    SELECT TOP (1) o2.OrderId, o2.OrderDate
    FROM   dbo.Orders AS o2
    WHERE  o2.CustomerId = c.CustomerId
    ORDER  BY o2.OrderDate DESC, o2.OrderId DESC
) AS o
ORDER  BY c.CustomerId;
```

> ⚠️ **`ORDER BY` にタイブレーク(一意になるまでのキー)を必ず足す**こと。
> `ORDER BY o2.OrderDate DESC` だけだと、同じ日に 2 件注文があったときに
> **どちらが返るか不定** になります。`, o2.OrderId DESC` のように主キーを添えると結果が安定します。
> これは `ROW_NUMBER()` 版でもまったく同じです。

> ⚠️ 「同点も全部欲しい」なら `ROW_NUMBER()` ではなく **`RANK()`** を使います。
> `ROW_NUMBER()` は同点でも必ず 1 行に絞ってしまいます。

---

## 2. パターン② 重複行の検出と削除

### どんな業務要件で必要になるか

- 「取り込んだ CSV に **同じ顧客が二重登録** されている。1 件だけ残したい」
- 「バッチが二重実行されて **明細が丸ごと重複** した。片方を消したい」
- 「主キーを付けたいが、**既存データに重複があって付けられない**」

### 解法 1: まず「検出」する

削除の前に、必ず **どれがどれだけ重複しているか** を数えます。

```sql
-- 重複の候補を数える(ここでは「顧客名 + 市」が同じものを重複とみなす)
SELECT CustomerName, City, COUNT(*) AS 件数
FROM   dbo.Customers
GROUP  BY CustomerName, City
HAVING COUNT(*) > 1;
```

実際に重複している **行そのもの** を見たいときはウィンドウ関数が便利です。

```sql
-- 重複グループの行を、明細のまま一覧する
WITH 重複 AS (
    SELECT CustomerId, CustomerName, City,
           COUNT(*)     OVER (PARTITION BY CustomerName, City) AS グループ件数,
           ROW_NUMBER() OVER (PARTITION BY CustomerName, City
                              ORDER BY CustomerId)             AS 連番
    FROM   dbo.Customers
)
SELECT *
FROM   重複
WHERE  グループ件数 > 1
ORDER  BY CustomerName, City, 連番;
```

### 解法 2: CTE に対して DELETE する(定番)

**SQL Server では、CTE を `DELETE` / `UPDATE` の対象にできます。**
これが「重複削除の定番」と呼ばれる書き方です。

サンプルDBの `dbo.Customers` には重複がないので、**一時テーブルに複製** して試します。

```sql
-- ① 実験用のコピーを作る(SELECT INTO は制約や PK を引き継がないので重複を入れられる)
DROP TABLE IF EXISTS #Customers;
SELECT CustomerId, CustomerName, City, Region, SalesRepId
INTO   #Customers
FROM   dbo.Customers;

-- ② わざと重複を作る(同じ会社が別 Id で二重登録された状態)
INSERT INTO #Customers (CustomerId, CustomerName, City, Region, SalesRepId) VALUES
    (101, N'株式会社アルファ商事', N'東京', N'関東',    2),
    (102, N'株式会社アルファ商事', N'東京', N'関東', NULL),
    (103, N'ガンマ物産',          N'大阪', N'関西',    3);

SELECT COUNT(*) AS 削除前 FROM #Customers;   -- 15 行

-- ③ 「顧客名 + 市」が同じものは、CustomerId が小さい 1 件だけ残して削除する
WITH 重複 AS (
    SELECT ROW_NUMBER() OVER (PARTITION BY CustomerName, City
                              ORDER BY CustomerId) AS 連番
    FROM   #Customers
)
DELETE FROM 重複
WHERE  連番 > 1;

SELECT COUNT(*) AS 削除後 FROM #Customers;   -- 12 行

-- ④ 後片付け
DROP TABLE IF EXISTS #Customers;
```

### なぜそう書くか

- **`PARTITION BY` に「重複とみなすキー」、`ORDER BY` に「どれを残すか」を書く。**
  この 2 つが仕様そのものです。「最も古い Id を残す」なら `ORDER BY CustomerId`、
  「最後に更新されたものを残す」なら `ORDER BY UpdatedAt DESC` になります。
- **`連番 > 1` を消す** ので、各グループの先頭 1 件だけが必ず残ります。
- `DELETE FROM 重複` の `重複` は CTE 名です。SQL Server は
  「更新可能なビュー」と同じ規則で、**1 つの基底テーブルだけを参照する CTE への DML** を許します。
  実際に消えるのは `#Customers` の行です。
- **`DISTINCT` では消せません。** `SELECT DISTINCT` は「重複しない結果を返す」だけで、
  テーブルの中身は変わりません。作り直す(`SELECT DISTINCT … INTO 別表` → 入れ替え)なら可能ですが、
  外部キーやインデックスを張り直す必要があり、部分的な重複除去には向きません。
- **主キーがまったく無く、行が完全に同一** の場合でも、この書き方なら消せます。
  `ROW_NUMBER()` は物理行ごとに番号を振るため、「見分けが付かない行」でも区別できるからです。

> ⚠️ **`ORDER BY` が一意でないと、どの行が残るか不定** になります。
> 「どれでもいいから 1 件」なら実害はありませんが、
> **業務的に残すべき行が決まっている場合は必ず一意になるまでキーを足す** こと。

> ⚠️ 本番で `DELETE` する前に、**同じ CTE を `SELECT` に差し替えて件数と中身を確認**しましょう。
> `WITH 重複 AS (…) SELECT * FROM 重複 WHERE 連番 > 1;` と書けば、消える行がそのまま見えます。
> 加えて `BEGIN TRAN` … 確認 … `COMMIT`(または `ROLLBACK`)で囲むのが安全です。

---

## 3. パターン③ ギャップ & アイランド(連続の塊と欠落)

### どんな業務要件で必要になるか

- 「この顧客は **何か月連続で** 取引があったか(継続取引期間)」
- 「**注文が 1 件も無かった期間** はいつからいつまでか」
- 「伝票番号の連番に **欠番** がないか(監査要件)」
- 「機器の稼働ログから、**連続稼働していた区間** を切り出したい」

「連続している塊」を **アイランド(island)**、「抜けている部分」を **ギャップ(gap)** と呼びます。

### 解法 1: アイランド ―「値 − 行番号」が一定になる性質を使う

古典的かつ最速の手法です。**連続している行では「値 − 行番号」が同じ値になる** ことを利用します。

```text
値   :  1  2  3     7  8       11
行番号:  1  2  3     4  5        6
差   :  0  0  0     3  3        5     ← 差が同じ = 同じ塊
```

これを「顧客ごとに、注文があった月の連続区間」に適用します。

```sql
-- 顧客ごとの「注文があった月」の連続区間(継続取引期間)
WITH 注文月 AS (
    -- 同じ月に複数注文があってもよいよう、まず月単位で一意にする
    SELECT DISTINCT
           o.CustomerId,
           DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月
    FROM   dbo.Orders AS o
),
グループ化 AS (
    SELECT CustomerId,
           月,
           -- 「通算月数 − 顧客内の行番号」が同じ行が 1 つの塊になる
           DATEDIFF(MONTH, '2000-01-01', 月)
             - ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY 月) AS 塊キー
    FROM   注文月
)
SELECT g.CustomerId,
       c.CustomerName,
       MIN(g.月) AS 開始月,
       MAX(g.月) AS 終了月,
       COUNT(*)  AS 連続月数
FROM   グループ化   AS g
JOIN   dbo.Customers AS c ON c.CustomerId = g.CustomerId
GROUP  BY g.CustomerId, c.CustomerName, g.塊キー
ORDER  BY g.CustomerId, 開始月;
```

- 顧客 1(アルファ商事)は 2023-01 と 2023-02 が連続しているため、
  **「2023-01 〜 2023-02 の 2 か月」** という 1 行にまとまります。
  2023-06 と 2024-01 は飛んでいるので、それぞれ別の塊(1 か月)になります。

**日付単位** でも考え方は同じです。日付から行番号ぶんの日数を引くと、連続日は同じ日付に潰れます。

```sql
-- 「注文があった日」の連続区間(日単位)
WITH 注文日 AS (
    SELECT DISTINCT OrderDate FROM dbo.Orders
),
グループ化 AS (
    SELECT OrderDate,
           DATEADD(DAY,
                   -ROW_NUMBER() OVER (ORDER BY OrderDate),
                   OrderDate) AS 塊キー
    FROM   注文日
)
SELECT MIN(OrderDate) AS 開始日,
       MAX(OrderDate) AS 終了日,
       COUNT(*)       AS 連続日数
FROM   グループ化
GROUP  BY 塊キー
ORDER  BY 開始日;
```

### 解法 2: ギャップ ― `LEAD` で「次の値」との差を見る

欠番の検出は、**次の行の値が「自分 + 1」でない場所** を探すだけです。

```sql
-- 伝票番号(ここでは OrderId)の欠番チェック
-- 実験用に、いくつか番号が欠けたデータを一時テーブルへ用意する
DROP TABLE IF EXISTS #伝票;
SELECT OrderId AS 伝票番号
INTO   #伝票
FROM   dbo.Orders
WHERE  OrderId NOT IN (1005, 1006, 1013, 1014);   -- ここが「欠番」になる

WITH 並び AS (
    SELECT 伝票番号,
           LEAD(伝票番号) OVER (ORDER BY 伝票番号) AS 次番号
    FROM   #伝票
)
SELECT 伝票番号 + 1        AS 欠番開始,
       次番号   - 1        AS 欠番終了,
       次番号 - 伝票番号 - 1 AS 欠番件数
FROM   並び
WHERE  次番号 > 伝票番号 + 1
ORDER  BY 欠番開始;

DROP TABLE IF EXISTS #伝票;
```

結果は「1005〜1006(2件)」「1013〜1014(2件)」の 2 行になります。

### なぜそう書くか

- **アイランドは「等差数列どうしの差は一定」** という算数がすべてです。
  連番(行番号)は必ず 1 ずつ増えるので、値も 1 ずつ増えている区間では差が一定になります。
  ギャップをまたぐと差がジャンプし、そこで塊が切れます。
- **月・日を扱うときは「整数に直してから」引く** のがコツです。
  月なら `DATEDIFF(MONTH, 基準日, 月)`、日なら `DATEADD(DAY, -行番号, 日付)` で
  「日付から行番号ぶん引く」形にします(日付から日付は引けないため)。
- **ギャップは `LEAD` / `LAG` のほうが直感的** です。アイランドの補集合として求めることもできますが、
  「次の値との差」を見るほうが式が短く、意図も明確です。
- 重複した値(同じ月に 2 件の注文)があると行番号がずれて塊が壊れるため、
  **必ず `DISTINCT` か `GROUP BY` で一意化してから** 行番号を振ります。

> ⚠️ ギャップ検出は「**先頭より前**」と「**末尾より後**」の欠番を見つけられません。
> 「1 から始まるはずなのに 5 から始まっている」ことも検出したいなら、
> パターン④の番号表を使い、`LEFT JOIN` で「あるべき番号」と突き合わせます。

---

## 4. パターン④ 番号表(Tally / Numbers table)

### どんな業務要件で必要になるか

- 「**売上のない月も 0 で** 帳票に出したい」(欠測を埋める / ゼロ埋め)
- 「4月1日から3月31日までの **全日付** を並べたカレンダーがほしい」
- 「テストデータを **100 万行** 生成したい」
- 「1 行を数量ぶんに **展開** したい(数量 3 → 3 行)」

これらはすべて **「元データに存在しない行を作る」** 要件です。
手続き型なら `WHILE` ループですが、SQL では **番号表(連番の集合)** を作って結合します。

### 解法: インライン番号表を作る

```sql
-- 1 から 100 までの連番を、テーブルを一切使わずに作る
WITH E1(n) AS (
    SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)   -- 10 行
),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),   -- 10 × 10   = 100 行
E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),   -- 100 × 100 = 10,000 行
Tally AS (
    SELECT TOP (100)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM   E4
)
SELECT n FROM Tally ORDER BY n;
```

- `VALUES` で 10 行の「種」を作り、**`CROSS JOIN` で掛け算** して行数を増やします。
  10 → 100 → 10,000 と、`CROSS JOIN` 1 段ごとに **2 乗** になります。
- `ROW_NUMBER() OVER (ORDER BY (SELECT NULL))` が連番を振るイディオムです。
  `(SELECT NULL)` は「並び順はどうでもよい」という意思表示で、余計なソートを避けられます。
- 必要な行数だけ `TOP (n)` で切り出します。**`TOP` には変数や式も書けます。**

> このイディオムは本プロジェクトの `sample-db/03_bulk_data.sql` でも使っています。
> `dbo.OrdersBig` の **100 万行を `WHILE` ループなしで 1 文で** 生成しているのがそれです。
> ループなら 100 万回の往復が発生しますが、番号表なら **1 回の `INSERT … SELECT`** で終わります。
> 大量データ生成でこの差は決定的です。

```sql
-- 参考: 03_bulk_data.sql と同じ考え方で、1000 行ぶんの疑似データを組み立てる例
WITH E1(n) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
Tally AS (
    SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM   E4
)
SELECT n                                        AS 疑似OrderId,
       (n % 12) + 1                             AS CustomerId,
       DATEADD(DAY, n % 365, '2024-01-01')      AS OrderDate
FROM   Tally
ORDER  BY n;
```

### 解法: カレンダー表を作って LEFT JOIN ―「売上のない月を 0 で埋める」

**この章でもっとも出番の多い応用** です。集計結果は「データがある月」しか返しません。
帳票では「売上ゼロの月も 0 と表示」する必要があるため、**先に全月を作ってから左外部結合** します。

```sql
DECLARE @開始 DATE = '2023-01-01';   -- 集計期間の開始月(1日に揃える)
DECLARE @終了 DATE = '2023-12-01';   -- 集計期間の終了月(1日に揃える)

WITH E1(n) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
カレンダー AS (
    -- @開始 から @終了 までの「月初日」を全部作る
    SELECT TOP (DATEDIFF(MONTH, @開始, @終了) + 1)
           DATEADD(MONTH, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @開始) AS 月
    FROM   E2
),
月次売上 AS (
    -- 顧客3(ガンマ物産)の月次売上。注文があるのは 2月・4月・9月 だけ
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)  AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))      AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    WHERE  o.CustomerId = 3
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT cal.月,
       ISNULL(s.売上, 0) AS 売上
FROM   カレンダー AS cal
LEFT   JOIN 月次売上 AS s ON s.月 = cal.月
ORDER  BY cal.月;
```

結果は **12 行** になり、注文のない 1月・3月・5月〜8月・10月〜12月 は `0` で埋まります。

**顧客 × 月のマトリクス** にしたいときは、カレンダーと顧客を `CROSS JOIN` して「あるべき組み合わせ」を作ります。

```sql
DECLARE @開始 DATE = '2023-01-01';
DECLARE @終了 DATE = '2023-12-01';

WITH E1(n) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
カレンダー AS (
    SELECT TOP (DATEDIFF(MONTH, @開始, @終了) + 1)
           DATEADD(MONTH, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @開始) AS 月
    FROM   E2
),
月次売上 AS (
    SELECT o.CustomerId,
           DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY o.CustomerId, DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT c.CustomerName,
       cal.月,
       ISNULL(s.売上, 0) AS 売上
FROM   dbo.Customers AS c
CROSS  JOIN カレンダー AS cal                    -- 顧客 12 × 月 12 = 144 行の「枠」を作る
LEFT   JOIN 月次売上 AS s
       ON  s.CustomerId = c.CustomerId
       AND s.月         = cal.月
ORDER  BY c.CustomerId, cal.月;
```

### なぜそう書くか

- **`LEFT JOIN` の左側が「あるべき行の集合」**、右側が「実績」です。この向きを間違えると欠測が埋まりません。
- `ISNULL(s.売上, 0)`(または `COALESCE`)で **NULL を 0 に落とす** のを忘れないこと。
  そのまま `NULL` を返すと、後段の累計や割り算がすべて `NULL` に汚染されます。
- **`WHERE` に右側テーブルの条件を書くと `LEFT JOIN` が内部結合に化けます。**
  上の例で `WHERE s.売上 > 0` と書くと欠測月が消えてしまいます。
  右側への条件は **`ON` 句に書く**(上の例の `AND s.月 = cal.月` と同じ位置)のが鉄則です。
- 番号表を **毎回 CTE で書くのが面倒なら、恒久的なテーブルを 1 つ作っておく** のも実務では一般的です。
  `dbo.Numbers(n INT PRIMARY KEY)` に 1〜100 万を入れておけば、
  インデックスが効くぶん CTE 版より速く、クエリも短くなります。

> ⚠️ `CROSS JOIN` は行数が **掛け算** になります。顧客 1000 × 日付 3650 = 365 万行です。
> 枠を作るときは **期間と対象を必ず絞る** こと。

---

## 5. パターン⑤ 累計・移動平均・前年同月比

### どんな業務要件で必要になるか

- 「**年度の累計売上** を月ごとに見たい(予算対比)」
- 「季節変動をならすため **3か月移動平均** を出したい」
- 「**前年同月比** で成長を見たい」

[08 ウィンドウ関数](08_window_functions.md) で学んだ道具の、実務での組み立て方です。
ポイントは **「まず月次に集約した CTE を 1 つ作り、その上でウィンドウ関数を重ねる」** という手順です。

### 解法: 月次 CTE の上に指標を重ねる

```sql
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
SELECT 月,
       月売上,
       -- ① 年内でリセットする累計(年度累計)
       SUM(月売上) OVER (PARTITION BY YEAR(月)
                         ORDER BY 月
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS 年累計,
       -- ② 期間全体を通した累計
       SUM(月売上) OVER (ORDER BY 月
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS 通算累計,
       -- ③ 当月を含む直近3か月の移動平均
       CAST(AVG(月売上) OVER (ORDER BY 月
                              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
            AS DECIMAL(18, 0))                                             AS 三か月移動平均
FROM   月次
ORDER  BY 月;
```

### 解法: 前年同月比 — 2 通りの書き方

```sql
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
-- 書き方A: LAG(…, 12) で「12 行前」を取る
SELECT 月,
       月売上,
       LAG(月売上, 12) OVER (ORDER BY 月) AS 前年同月売上,
       CAST(100.0 * 月売上 / NULLIF(LAG(月売上, 12) OVER (ORDER BY 月), 0)
            AS DECIMAL(6, 1))             AS 前年同月比_pct
FROM   月次
ORDER  BY 月;
```

```sql
WITH 月次 AS (
    SELECT DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1) AS 月,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))     AS 月売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
)
-- 書き方B: 「1年前の月」を日付で自己結合する(欠測に強い)
SELECT t.月,
       t.月売上,
       p.月売上 AS 前年同月売上,
       CAST(100.0 * t.月売上 / NULLIF(p.月売上, 0) AS DECIMAL(6, 1)) AS 前年同月比_pct
FROM   月次 AS t
LEFT   JOIN 月次 AS p ON p.月 = DATEADD(YEAR, -1, t.月)
ORDER  BY t.月;
```

### なぜそう書くか

- **累計・移動平均では `ROWS` を明示** します。フレームを省略すると既定が `RANGE` になり、
  同じ値の行がまとめて加算されてしまいます([08 ウィンドウ関数](08_window_functions.md) 第8節)。
- **`PARTITION BY YEAR(月)` を足すだけで「年度リセット」** になります。
  4月始まりの会計年度なら `YEAR(DATEADD(MONTH, -3, 月))` を使うと 4〜3月で区切れます。
- **`NULLIF(分母, 0)` で 0 除算を防ぐ** のは比率計算の必須作法です。
  0 で割るとエラーで落ちますが、`NULLIF` を通せば結果が `NULL` になるだけで済みます。
- **`LAG(…, 12)` は「12 行前」であって「12 か月前」ではありません。**
  途中の月が 1 つでも欠けていると 1 か月ずれた値を拾い、**間違いに気づけません**。
  - **書き方A** は、事前にパターン④のカレンダーでゼロ埋めしてある場合に安全・高速。
  - **書き方B** は、日付そのもので突き合わせるため **欠測があっても正しい**(存在しなければ `NULL`)。
  - 実務では **「④でゼロ埋め → ⑤で LAG」** か **「書き方B の自己結合」** のどちらかにそろえます。
- サンプルDBは 2023-01〜2024-01 の 13 か月ぶんなので、前年同月比が算出できるのは **2024-01 のみ** です。
  それ以外は「前年のデータが無い」ので `NULL` になります(想定どおりの挙動)。

---

## 6. パターン⑥ 行 → カンマ区切り文字列

### どんな業務要件で必要になるか

- 「注文一覧に **含まれる商品名をまとめて 1 セル** に表示したい」
- 「顧客ごとの **担当者リスト** を CSV 出力したい」
- 「メール送信用に **宛先アドレスをセミコロン区切り** で組み立てたい」

### 解法 1: STRING_AGG(SQL Server **2017** 以降)

```sql
-- 注文ごとに、含まれる商品名をカンマ区切りで 1 行にまとめる
SELECT o.OrderId,
       o.OrderDate,
       STRING_AGG(CAST(p.ProductName AS NVARCHAR(MAX)), N', ')
           WITHIN GROUP (ORDER BY p.ProductName) AS 商品一覧,
       COUNT(*)                                  AS 明細件数
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
JOIN   dbo.Products     AS p  ON p.ProductId = od.ProductId
GROUP  BY o.OrderId, o.OrderDate
ORDER  BY o.OrderId;
```

```sql
-- 営業担当ごとに、担当顧客名を並べる
SELECT e.EmployeeId,
       e.LastName + N' ' + e.FirstName AS 担当者,
       STRING_AGG(CAST(c.CustomerName AS NVARCHAR(MAX)), N' / ')
           WITHIN GROUP (ORDER BY c.CustomerId) AS 担当顧客
FROM   dbo.Employees AS e
JOIN   dbo.Customers AS c ON c.SalesRepId = e.EmployeeId
GROUP  BY e.EmployeeId, e.LastName, e.FirstName
ORDER  BY e.EmployeeId;
```

### 解法 2: FOR XML PATH + STUFF(SQL Server **2016 以前**)

`STRING_AGG` が使えない環境では、長らくこの書き方が定番でした。

```sql
-- 注文ごとの商品名カンマ区切り(2016 以前でも動く書き方)
SELECT o.OrderId,
       o.OrderDate,
       STUFF(
           (SELECT N', ' + p.ProductName
            FROM   dbo.OrderDetails AS od
            JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
            WHERE  od.OrderId = o.OrderId
            ORDER  BY p.ProductName
            FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'),
           1, 2, N'')                     AS 商品一覧
FROM   dbo.Orders AS o
ORDER  BY o.OrderId;
```

### なぜそう書くか

- **`STRING_AGG` は集約関数** なので、`GROUP BY` の相棒として素直に書けます。
  並び順を決めるのは `ORDER BY` ではなく **`WITHIN GROUP (ORDER BY …)`** です(専用構文)。
- **`CAST(… AS NVARCHAR(MAX))` を挟む理由**: 入力が `NVARCHAR(100)` などだと結果も
  `NVARCHAR(4000)` 止まりになり、連結が長いと **切り捨てではなくエラー** になります。
  `MAX` にキャストしておけば安全です。
- **`FOR XML PATH('')` の仕組み**: 相関サブクエリの結果を XML 化するとき、要素名を空文字にすると
  タグが付かず、単なる文字列連結として振る舞います。
  - 先頭に余計な `', '` が付くので、**`STUFF(文字列, 1, 2, '')` で先頭 2 文字を削除** します
    (区切り文字が `', '` の 2 文字だから 2)。
  - **`, TYPE` と `.value('.', 'NVARCHAR(MAX)')` は必須** です。これを省くと
    `&`(`&amp;`)や `<`(`&lt;`)が **XML エスケープされたまま** 出てきます。
- **2017 以降なら迷わず `STRING_AGG`** を使ってください。読みやすく、速く、エスケープの罠もありません。
  `FOR XML PATH` は「古いシステムの保守で読む必要がある」ときのための知識です。

**逆方向(カンマ区切り → 行)** は `STRING_SPLIT`(2016 以降)です。

```sql
-- 'ノートPC,本棚,ホチキス' を行に分解して商品を検索する
DECLARE @商品リスト NVARCHAR(400) = N'ノートPC,本棚,ホチキス';

SELECT p.ProductId, p.ProductName, p.UnitPrice
FROM   STRING_SPLIT(@商品リスト, N',') AS s
JOIN   dbo.Products AS p ON p.ProductName = LTRIM(RTRIM(s.value))
ORDER  BY p.ProductId;
```

> ⚠️ `STRING_SPLIT` は **区切り文字が 1 文字** のみ、かつ **元の順序を保証しません**
> (順序を返す `ordinal` 列は SQL Server 2022 以降)。順序が要るならパターン④の番号表で自作します。

---

## 7. パターン⑦ ピボット的な帳票(条件付き集計)

### どんな業務要件で必要になるか

- 「**行=顧客、列=四半期** の売上サマリを Excel 貼り付け用に出したい」
- 「**行=地域、列=月** で、売上と件数を **両方** 並べたい」
- 「各行の右端に **合計列**、最下部に **合計行** がほしい」

[10 PIVOT / UNPIVOT](10_pivot_unpivot.md) で `PIVOT` 演算子を学びましたが、
**実務の帳票では `CASE` 式 + 集約(条件付き集計)のほうが主役** です。

### 解法: CASE + SUM で「列を手で並べる」

```sql
-- 2023年 顧客別 四半期売上サマリ(行=顧客、列=四半期)
SELECT c.CustomerName AS 顧客名,
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 1
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q1],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 2
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q2],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 3
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q3],
       SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate) = 4
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS [Q4],
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))                      AS 年間合計,
       COUNT(DISTINCT o.OrderId)                                                AS 注文件数
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
WHERE  o.OrderDate >= '2023-01-01' AND o.OrderDate < '2024-01-01'
GROUP  BY c.CustomerId, c.CustomerName
ORDER  BY 年間合計 DESC;
```

**売上と件数を同じ表に混ぜる** のも、条件付き集計なら自然に書けます。

```sql
-- 2023年 地域別 上期/下期の「売上」と「注文件数」を 1 表に
SELECT c.Region AS 地域,
       SUM(CASE WHEN MONTH(o.OrderDate) <= 6
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS 上期売上,
       COUNT(DISTINCT CASE WHEN MONTH(o.OrderDate) <= 6
                           THEN o.OrderId END)                                  AS 上期件数,
       SUM(CASE WHEN MONTH(o.OrderDate) > 6
                THEN od.Quantity * od.UnitPrice * (1 - od.Discount) ELSE 0 END) AS 下期売上,
       COUNT(DISTINCT CASE WHEN MONTH(o.OrderDate) > 6
                           THEN o.OrderId END)                                  AS 下期件数
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
WHERE  o.OrderDate >= '2023-01-01' AND o.OrderDate < '2024-01-01'
GROUP  BY c.Region
ORDER  BY 上期売上 + 下期売上 DESC;
```

**合計行** は `GROUP BY … WITH ROLLUP` と `GROUPING()` で付けられます。

```sql
-- 地域別売上 + 最下部に総合計行
SELECT CASE WHEN GROUPING(c.Region) = 1 THEN N'【総合計】'
            ELSE ISNULL(c.Region, N'(地域未設定)') END                        AS 地域,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))                     AS 売上,
       COUNT(DISTINCT o.OrderId)                                              AS 注文件数
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
GROUP  BY c.Region WITH ROLLUP
ORDER  BY GROUPING(c.Region), 売上 DESC;
```

### なぜそう書くか

- **`PIVOT` より `CASE` を選ぶ理由**
  1. **1 つの表に複数の集計を混ぜられる**(売上と件数を並べる、平均も足す)。`PIVOT` は集約関数 1 つだけ。
  2. **条件を自由に書ける**(「上期」「値引きありの明細だけ」など、列の値と一致しない条件も可)。
  3. **`PIVOT` の独特な構文を覚えなくてよい**。他 DBMS にもそのまま持っていける。
  4. 実行プランは `PIVOT` とほぼ同じ(内部的にも似た形に展開されます)。性能上の不利はありません。
- **`ELSE 0` を付けるか付けないか**
  - `SUM` で **合計** を出すときは `ELSE 0`(または省略して `NULL`)どちらでも合計値は同じですが、
    該当行がまったく無い場合、`ELSE 0` があれば `0`、無ければ `NULL` になります。**帳票では `0` が読みやすい** です。
  - `AVG` を使うときは要注意です。`ELSE 0` にすると **0 が母数に入って平均が下がります**。
    平均では `ELSE` を書かず `NULL` にする(=`AVG` の対象外)のが正解です。
- **`COUNT(DISTINCT CASE WHEN 条件 THEN 列 END)`** が「条件付き件数」の型です。
  `CASE` に `ELSE` を書かないので、条件外は `NULL` となり `COUNT` の対象から自動で外れます。
  ここは明細を結合しているので、注文の件数を数えるには `DISTINCT o.OrderId` が必要です。
- **列名が数字で始まるときは角括弧が必要** です。`AS 1月` はエラーになるので `AS [1月]` と書きます。
- **列が可変(対象月がパラメータで変わる)場合は動的SQL** が必要です。
  `CASE` の列を文字列で組み立てて `sp_executesql` に渡します([20 動的SQL](20_dynamic_sql.md))。
  ただし **列が固定なら動的SQLにしない** こと。可読性とプラン再利用の面で損しかありません。

---

## 8. パターン⑧ カーソルを使わない発想

### どんな業務要件で必要になるか

手続き型言語の経験者は、次のような要件でつい `CURSOR` に手が伸びます。

- 「**顧客を 1 件ずつ回して**、購入累計を計算し、ランクを更新する」
- 「**明細を 1 行ずつ読んで**、running total を計算する」
- 「**行ごとに** 条件判定して、別テーブルへ振り分ける」

しかし SQL は **集合(セット)を一度に扱う言語** です。
1 行ずつのループは、SQL Server にとって最も苦手な処理形態になります。

### 解法: 「1 行ずつ」を「1 文で」に置き換える

まずカーソル版を見ます(実験用の一時テーブル上で実行します)。

```sql
-- 準備: 顧客の集計結果を入れる作業テーブル
DROP TABLE IF EXISTS #顧客ランク;
SELECT CustomerId,
       CustomerName,
       CAST(0  AS DECIMAL(18, 2)) AS 累計購入額,
       CAST(N'' AS NVARCHAR(10))  AS ランク
INTO   #顧客ランク
FROM   dbo.Customers;
```

```sql
-- ✗ カーソル版(動くが遅い。書き方の例として示す)
DECLARE @CustomerId INT;
DECLARE @売上 DECIMAL(18, 2);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT CustomerId FROM dbo.Customers;   -- 更新対象と別の表を読む(自分を読みながら更新しない)

OPEN cur;
FETCH NEXT FROM cur INTO @CustomerId;

WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @売上 = ISNULL(SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)), 0)
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    WHERE  o.CustomerId = @CustomerId;

    UPDATE #顧客ランク
    SET    累計購入額 = @売上,
           ランク     = CASE WHEN @売上 >= 1000000 THEN N'A'
                             WHEN @売上 >=  300000 THEN N'B'
                             WHEN @売上 >       0  THEN N'C'
                             ELSE N'-' END
    WHERE  CustomerId = @CustomerId;

    FETCH NEXT FROM cur INTO @CustomerId;
END;

CLOSE cur;
DEALLOCATE cur;

SELECT * FROM #顧客ランク ORDER BY 累計購入額 DESC;
```

同じことが **`UPDATE` 1 文** で書けます。

```sql
-- ○ 集合ベース版(1文で同じ結果)
UPDATE t
SET    累計購入額 = ISNULL(s.売上, 0),
       ランク     = CASE WHEN ISNULL(s.売上, 0) >= 1000000 THEN N'A'
                         WHEN ISNULL(s.売上, 0) >=  300000 THEN N'B'
                         WHEN ISNULL(s.売上, 0) >       0  THEN N'C'
                         ELSE N'-' END
FROM   #顧客ランク AS t
LEFT   JOIN (
    SELECT o.CustomerId,
           SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
    GROUP  BY o.CustomerId
) AS s ON s.CustomerId = t.CustomerId;

SELECT * FROM #顧客ランク ORDER BY 累計購入額 DESC;

DROP TABLE IF EXISTS #顧客ランク;
```

### なぜそう書くか — 置き換えの考え方

カーソルを見たら、**ループの中身が何をしているか** で対応表を引きます。

| ループの中身 | 集合ベースの置き換え先 |
|---|---|
| 各行について集計値を求める | `GROUP BY` した派生表 / CTE と `JOIN` |
| 各行について「関連する上位1件」を取る | `CROSS APPLY` / `OUTER APPLY`(パターン①) |
| 前の行の値を足し込む(running total) | `SUM(…) OVER (ORDER BY … ROWS …)`(パターン⑤) |
| 前の行と比較する | `LAG` / `LEAD`(パターン⑤) |
| 条件で分岐して別々に更新する | `CASE` 式を `SET` に書く / `MERGE` |
| 回数ぶん繰り返して行を作る | 番号表との `CROSS JOIN`(パターン④) |
| 存在すれば更新・無ければ挿入 | `MERGE` または `UPDATE` + `INSERT … WHERE NOT EXISTS` |

**なぜ集合ベースが速いのか**

- カーソルは 1 行ごとに「フェッチ → 変数代入 → 文の実行」を繰り返します。
  12 行なら気になりませんが、**100 万行なら 100 万回の往復** です。
- 1 文で書けば、オプティマイザが **ハッシュ結合・並列実行・一括ログ** といった
  集合向けの最適化を選べます。ループではその余地がありません。
- SQL は **「どうやるか」ではなく「何が欲しいか」** を書く言語です。
  手順を書き下した瞬間に、最適化の機会をこちらから捨てていることになります。

### それでもカーソル(ループ)が必要な場面

「カーソルは絶対悪」ではありません。次のようなケースでは、むしろ素直です。

1. **行ごとに DDL や管理コマンドを実行する**
   例: 全テーブルを回して `ALTER INDEX … REBUILD` する、テーブルごとに統計を更新する。
   1 文では書けないので、カーソルか `sp_MSforeachtable` 相当のループを使います。
2. **行ごとにストアドプロシージャを呼ぶ必要がある**
   例: 既存の業務ロジックがプロシージャに閉じており、1 件ずつ渡す前提になっている。
3. **前の行の「処理結果」に依存する逐次計算**
   例: 在庫の FIFO 引き当てで、残数が次の行の処理内容を変える場合。
   (ただしこの種の計算も、ウィンドウ関数の累計で書けることが多いので、まず集合ベースを検討します)
4. **巨大な更新・削除をバッチに分割する**
   1000 万行を 1 文で消すとログが膨張しロックも長時間になるため、**あえてループします**。
   ただしこれはカーソルではなく `WHILE` + `TOP` です。

```sql
-- 参考: 大量削除をバッチに分割するループ(カーソルではなく WHILE + TOP)
-- ※ 実行はしないでください。書き方の型のみ示します。
-- WHILE 1 = 1
-- BEGIN
--     DELETE TOP (10000) FROM dbo.OrdersBig WHERE OrderDate < '2016-01-01';
--     IF @@ROWCOUNT = 0 BREAK;
--     -- 必要ならここでウェイトやログ切り捨てを挟む
-- END;
```

> ⚠️ どうしてもカーソルを使うときは、**必ず `LOCAL FAST_FORWARD`**(または
> `LOCAL STATIC READ_ONLY FORWARD_ONLY`)を指定します。
> 既定の `GLOBAL DYNAMIC` カーソルは、更新可能で双方向に動ける代わりに **著しく重い** です。
> また、`CLOSE` と `DEALLOCATE` を忘れるとリソースが残り続けます。

---

## よくあるつまずき

- **グループ別 Top-N で結果が毎回変わる** → `ORDER BY` にタイブレークが無い。
  主キーなど一意になるキーを末尾に足す。
- **`CROSS APPLY` にしたら「該当なし」の親が消えた** → `OUTER APPLY` にする。
- **重複削除の `DELETE` が全行消した** → CTE を `SELECT` に差し替えて確認せずに実行した。
  `WHERE 連番 > 1` の条件漏れが典型。必ず `BEGIN TRAN` で試す。
- **アイランドの区間がバラバラになる** → 元データに重複値がある。
  `DISTINCT` / `GROUP BY` で一意化してから `ROW_NUMBER()` を振る。
- **ゼロ埋めしたのに欠測月が消える** → `LEFT JOIN` の右側テーブルへの条件を `WHERE` に書いた。
  条件は `ON` 句へ移す。あるいは `ISNULL(…, 0)` を忘れて `NULL` のまま。
- **前年同月比が 1 か月ずれている** → `LAG(…, 12)` は「12 行前」。
  欠測月があるとずれる。カレンダーでゼロ埋めするか、`DATEADD(YEAR, -1, 月)` で自己結合する。
- **比率計算がエラーで落ちる / 全部 0 になる** → 0 除算は `NULLIF(分母, 0)`、
  整数割り算の切り捨ては `100.0 *` で回避。
- **`STRING_AGG` が長い文字列で失敗する** → 入力を `CAST(… AS NVARCHAR(MAX))` する。
- **`FOR XML PATH` の結果に `&amp;` が混ざる** → `, TYPE).value('.', 'NVARCHAR(MAX)')` を付けていない。
- **`AS 1月` でエラー** → 識別子は数字で始められない。`AS [1月]` と角括弧で囲む。
- **平均の条件付き集計がおかしい** → `AVG` に `ELSE 0` を書くと 0 が母数に入る。`ELSE` は省く。
- **カーソルを消したら結果が変わった** → 元のループが「更新した結果を次の行で読む」順序依存だった。
  その場合はウィンドウ関数で表現できるか検討し、できなければループのまま残す。

## この章のまとめ

- **グループ別 Top-N** は `ROW_NUMBER()`(全グループ処理向き)と `CROSS APPLY`(親が少数+インデックス向き)の 2 択。
  「該当なし」を残したいなら `OUTER APPLY`。`ORDER BY` のタイブレークを忘れない。
- **重複削除** は `ROW_NUMBER() OVER (PARTITION BY キー ORDER BY 残す順)` の CTE に対して `DELETE … WHERE 連番 > 1`。
  SQL Server は **CTE を DML の対象にできる**。実行前に必ず `SELECT` で確認する。
- **ギャップ&アイランド** は「値 − 行番号が一定」でアイランド、`LEAD` の差でギャップ。
  日付は整数に直してから引く。事前に一意化する。
- **番号表(Tally)** は「存在しない行を作る」万能ツール。`VALUES` + `CROSS JOIN` + `ROW_NUMBER()`。
  **カレンダー表を作って `LEFT JOIN`** すれば売上のない月を 0 で埋められる。
  `sample-db/03_bulk_data.sql` の 100 万行生成も同じ手法。
- **累計・移動平均・前年同月比** は「月次 CTE を作ってからウィンドウ関数を重ねる」。
  `ROWS` を明示し、`NULLIF` で 0 除算を防ぎ、`LAG(…,12)` の欠測リスクを理解する。
- **行→カンマ区切り** は 2017 以降なら `STRING_AGG` + `WITHIN GROUP (ORDER BY …)`。
  それ以前は `STUFF(… FOR XML PATH(''), TYPE).value(…), 1, 2, '')`。
- **帳票のクロス集計** は `PIVOT` より **`CASE` + 集約**。複数指標を混ぜられ、条件も自由。合計行は `WITH ROLLUP`。
- **カーソルは最後の手段**。「集計」「上位1件」「累計」「前後比較」「繰り返し生成」はすべて
  集合ベースの定番に置き換わる。DDL の一括実行やバッチ分割など、ループが正解の場面だけに限定する。

➡ 演習: [exercises/21_query_patterns.md](../exercises/21_query_patterns.md)
