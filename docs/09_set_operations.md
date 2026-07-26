# 09 集合演算 (UNION など)

> **このトピックのゴール**: 複数の `SELECT` の結果を **縦方向** に連結・比較する
> 集合演算(`UNION` / `UNION ALL` / `INTERSECT` / `EXCEPT`)を使い分け、
> `JOIN` との違いを説明できるようになる。
>
> **前提**: [08 ウィンドウ関数](08_window_functions.md) までを済ませ、
> `SELECT` / `WHERE` / `JOIN` / サブクエリを一通り書けること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. 集合演算とは — 「縦」に組み合わせる

`JOIN` が複数テーブルを **横方向(列を増やす)** に結合するのに対し、
集合演算は複数の `SELECT` 結果を **縦方向(行を増やす/絞る)** に組み合わせます。

```sql
-- 東京の顧客名と、東京にある部門の所在地ラベルを縦に並べる
SELECT CustomerName AS 名称
FROM   dbo.Customers
WHERE  City = N'東京'
UNION
SELECT DepartmentName
FROM   dbo.Departments
WHERE  Location = N'東京';
```

- 2つ(以上)の `SELECT` を演算子(`UNION` など)でつなぐ。
- 結果は「1つの結果セット」として返る。
- **列名は先頭の `SELECT` のもの** が採用される(2番目以降の別名は無視される)。

主な演算子は次の4つです。

| 演算子 | 意味 | 重複行 |
|---|---|---|
| `UNION` | 和集合(どちらかに現れる行) | 除去する |
| `UNION ALL` | 和集合(そのまま連結) | 残す |
| `INTERSECT` | 積集合(両方に現れる行) | 除去する |
| `EXCEPT` | 差集合(左にあり右にない行) | 除去する |

## 2. 使用ルール(3つの約束)

集合演算でつなぐ各 `SELECT` は、次を満たす必要があります。

```sql
-- ○ 列数が揃い、対応する列の型が互換
SELECT CustomerName, City FROM dbo.Customers
UNION ALL
SELECT DepartmentName, Location FROM dbo.Departments;
```

1. **列数を揃える** … 各 `SELECT` の列数は同じでなければならない。
2. **対応する列の型が互換** … 1列目どうし・2列目どうしが暗黙変換できる型であること
   (`nvarchar` と `nvarchar`、`int` と `decimal` など)。
3. **列名は先頭 `SELECT` が採用** … 結果の見出しは1つ目の `SELECT` で決まる。
   別名を付けたいなら **先頭の `SELECT` に** 付ける。

> ⚠️ 列数が違う、または対応列の型が変換できない(例: `nvarchar` の列と
> `date` の列を対応させる)とエラーになります。
> 位置(左から何番目か)で対応が決まるので、**並び順にも注意**します。

## 3. `UNION` と `UNION ALL` の違い(重複排除と性能)

もっとも重要な使い分けです。

```sql
-- UNION: 重複行を1つにまとめる(全体でユニーク化)
SELECT City FROM dbo.Customers
UNION
SELECT Location FROM dbo.Departments;

-- UNION ALL: 重複を残してそのまま縦連結
SELECT City FROM dbo.Customers
UNION ALL
SELECT Location FROM dbo.Departments;
```

- `UNION` は結果全体で **重複を除去** する。そのために内部で並べ替え/ハッシュ処理が
  走るため、**行数が多いとコストが高い**。
- `UNION ALL` は重複チェックをしない分 **速い**。
- **重複が出ないと分かっている**、または **重複をあえて残したい** ときは
  `UNION ALL` を選ぶのが定石。

> ⚠️ 「とりあえず `UNION`」は避けましょう。重複排除が不要な場面で `UNION` を使うと、
> 無駄な並べ替えで遅くなります。まず `UNION ALL` を検討し、
> 重複を消したいときだけ `UNION` にします。

## 4. `INTERSECT`(積集合)と `EXCEPT`(差集合)

`INTERSECT` は両方に共通する行、`EXCEPT` は左にだけある行を返します。
どちらも **重複を除去** します。

```sql
-- 担当(SalesRepId)が付いている顧客の担当社員 と、
-- 実際に注文を受注した社員(Orders.EmployeeId)の両方に現れる社員Id
SELECT SalesRepId FROM dbo.Customers WHERE SalesRepId IS NOT NULL
INTERSECT
SELECT EmployeeId FROM dbo.Orders    WHERE EmployeeId IS NOT NULL;
```

```sql
-- 一度でも注文したことがある顧客(Ordersに現れる)を「全顧客」から引くと、
-- 注文が1件もない顧客が残る
SELECT CustomerId FROM dbo.Customers
EXCEPT
SELECT CustomerId FROM dbo.Orders;      -- → 顧客11(ラムダソフト)だけが残る
```

- `EXCEPT` は **左 − 右**。順序を入れ替えると意味が変わる(`A EXCEPT B` ≠ `B EXCEPT A`)。
- `INTERSECT` / `EXCEPT` も列数・型互換のルールは `UNION` と同じ。
- `NOT IN` / `NOT EXISTS` でも「注文なし顧客」は書けます(後述の §7 で対比)。

## 5. 集合演算での NULL の扱い

集合演算の重複判定では、**`NULL` どうしは「同じ値」とみなされます**。
これは通常の比較(`NULL = NULL` が「不明」になる)とは **逆の挙動** なので注意します。

```sql
-- 2つの NULL は同一とみなされ、UNION では1行にまとめられる
SELECT SalesRepId FROM dbo.Customers      -- 担当NULLの顧客が複数いる
UNION
SELECT NULL;                              -- それでも NULL は1行だけになる
```

- `UNION` / `INTERSECT` / `EXCEPT` の重複比較では `NULL = NULL` が **真** の扱い。
- そのため `INTERSECT` は「両方に NULL がある」と NULL 行を共通行として返し、
  `EXCEPT` は「左右どちらにも NULL がある」と NULL 行を差から取り除きます。
- 一方 `WHERE 列 = 列` のような通常比較では NULL は一致しません。**文脈で挙動が違う**
  ことを覚えておきましょう(NULL の一般論は
  [11 条件式と NULL 処理](11_conditional_null.md))。

## 6. `ORDER BY` は最後にまとめて1つだけ

並べ替えは **集合演算の全体に対して、末尾に1つだけ** 書きます。
途中の `SELECT` に `ORDER BY` は付けられません。

```sql
-- ○ 末尾に1つだけ。列名は先頭SELECTの見出しで参照する
SELECT CustomerName AS 名称, City AS 地
FROM   dbo.Customers WHERE City = N'東京'
UNION ALL
SELECT DepartmentName, Location
FROM   dbo.Departments WHERE Location = N'東京'
ORDER  BY 名称;          -- 先頭SELECTの別名 or 列位置(ORDER BY 1)で指定
```

- `ORDER BY` は最後の `SELECT` のさらに後ろに1つだけ。
- 並べ替えのキーは **先頭 `SELECT` の列名/別名**、または **列位置番号**(`ORDER BY 1`)。
- 各 `SELECT` に個別の `ORDER BY` を書くとエラー(例外は `TOP` と併用する副問い合わせ内など)。

> ⚠️ 「2番目の `SELECT` の列名」で並べ替えようとすると、その名前は結果に存在しないため
> エラーになります。必ず先頭 `SELECT` の見出し、または位置番号を使います。

## 7. `JOIN` との使い分け

「共通する/しない」を求めるとき、集合演算・`JOIN`・`EXISTS` のどれでも書けることが
あります。目的で選びます。

```sql
-- 注文なし顧客: EXCEPT で書く
SELECT CustomerId FROM dbo.Customers
EXCEPT
SELECT CustomerId FROM dbo.Orders;

-- 同じことを NOT EXISTS で書く(列を増やして情報も返せる)
SELECT c.CustomerId, c.CustomerName
FROM   dbo.Customers AS c
WHERE  NOT EXISTS (SELECT 1 FROM dbo.Orders AS o
                   WHERE o.CustomerId = c.CustomerId);
```

- **縦に結合したい(行を足す)** → `UNION` / `UNION ALL`。
- **横に結合したい(列を足す)** → `JOIN`。
- **「両方にある/片方にない」を単純な列集合で判定したい** → `INTERSECT` / `EXCEPT`。
  簡潔で読みやすい。
- **判定に加えて他の列も返したい/相関条件が複雑** → `JOIN` や `EXISTS` / `NOT EXISTS`。
- `EXCEPT` と `NOT IN` の違いにも注意: `NOT IN` は右側に NULL が混ざると
  期待どおり動かないことがある(全行が消える)。`EXCEPT` や `NOT EXISTS` は安全。

## よくあるつまずき

- **列名が思ったものと違う** → 結果の見出しは先頭 `SELECT`。別名は先頭に付ける。
- **`ORDER BY` でエラー** → 途中の `SELECT` に書いた、または2番目の列名を指定した。
  末尾に1つだけ・先頭 `SELECT` の名前(または位置番号)で。
- **列数/型が合わずエラー** → 各 `SELECT` の列数と、対応列の型互換を確認。
- **遅い `UNION`** → 重複排除が不要なら `UNION ALL` にする。
- **NULL の扱いが直感と逆** → 集合演算では `NULL = NULL` が真(1つにまとまる)。
- **`NOT IN` で結果が空** → 右側の副問い合わせに NULL が含まれている。`EXCEPT` /
  `NOT EXISTS` に置き換える。

## この章のまとめ

- 集合演算は結果を **縦** に組み合わせる。`JOIN` は **横**。
- `UNION`(重複除去)/ `UNION ALL`(そのまま・速い)/ `INTERSECT`(積)/ `EXCEPT`(差)。
- ルールは「**列数を揃える・対応列の型互換・列名は先頭 `SELECT`**」。
- `ORDER BY` は **全体の末尾に1つだけ**、先頭 `SELECT` の名前/位置で指定。
- 重複判定では **`NULL` どうしは同一** とみなされる(通常比較と逆)。
- 「注文なし顧客」などは `EXCEPT` / `NOT EXISTS` で。`NOT IN` は NULL に注意。

➡ 演習: [exercises/09_set_operations.md](../exercises/09_set_operations.md)
