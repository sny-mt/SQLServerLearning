# 03 並べ替えとページング

> **このトピックのゴール**: `ORDER BY` で結果を意図した順序に並べ、
> `TOP` や `OFFSET-FETCH` で「上位 n 件」や「ページ単位」の取り出しができるようになる。
>
> **前提**: [02 WHERE による絞り込み](02_where_filtering.md) を済ませ、
> 条件で行を絞り込めること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. ORDER BY が無ければ順序は保証されない(最重要)

まず大原則です。**`ORDER BY` を書かないかぎり、結果行の順序は一切保証されません。**

```sql
-- このクエリの行の並びは「たまたま」の順序。次に実行したら変わりうる。
SELECT EmployeeId, LastName, Salary
FROM   dbo.Employees;
```

- 主キー順に見えても、それは偶然です。インデックスの選択、並列実行、
  データ量の変化などで **同じクエリでも並びが変わる** ことがあります。
- 「見た目が揃っているから大丈夫」は禁物。順序が意味を持つなら、**必ず `ORDER BY` を書く**。

> ⚠️ `TOP` や `OFFSET-FETCH` で「上位 n 件」を取るときも、
> `ORDER BY` が無ければ「どの n 件が返るか」すら不定です。順序指定は必須と考えてください。

## 2. ORDER BY の基本(ASC / DESC)

```sql
-- 給与の高い順に社員を並べる
SELECT LastName, FirstName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;
```

- `ASC` … 昇順(小さい→大きい)。**既定値**なので省略できます。
- `DESC` … 降順(大きい→小さい)。
- `ORDER BY` は **論理評価順序で最後**(`SELECT` の後)に実行されます。
  そのため `SELECT` で付けた **別名を `ORDER BY` では使えます**([01](01_select_basics.md) 参照)。

```sql
-- 昇順(既定)。ASC は省略可
SELECT ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice;        -- = ORDER BY UnitPrice ASC
```

## 3. 複数キーで並べ替える

カンマ区切りで **複数の並べ替えキー** を指定できます。左のキーが優先され、
値が同じ行だけが次のキーで並びます。

```sql
-- まず部署ID昇順、同じ部署の中では給与の高い順
SELECT DepartmentId, LastName, Salary
FROM   dbo.Employees
ORDER  BY DepartmentId ASC, Salary DESC;
```

- キーごとに `ASC` / `DESC` を個別に指定できます(上の例は片方 ASC、片方 DESC)。
- 並び順を安定させたいときは、最後に **一意な列(主キーなど)** を足すのが定石です。

```sql
-- HireDate が同日の社員が複数いても、EmployeeId で並びが決まる(安定)
SELECT HireDate, EmployeeId, LastName
FROM   dbo.Employees
ORDER  BY HireDate ASC, EmployeeId ASC;
```

## 4. 式・別名・序数での並べ替えとその是非

`ORDER BY` には、列名だけでなく **式** や **SELECT の別名** も書けます。
さらに **序数(SELECT リストの何番目か)** でも指定できますが、これは注意が必要です。

```sql
-- 式で並べ替え(税込単価の高い順)
SELECT ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice * 1.1 DESC;

-- SELECT の別名で並べ替え(読みやすい・推奨)
SELECT ProductName,
       UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
ORDER  BY 税込単価 DESC;

-- 序数(SELECT の2番目の列 = 税込単価)で並べ替え
SELECT ProductName,
       UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
ORDER  BY 2 DESC;
```

- **別名での指定は読みやすく、おすすめ**です。
- **序数(`ORDER BY 2`)は非推奨**。SELECT リストの列を足したり並べ替えたりすると、
  番号がずれて **意図しない列で並んでしまう** バグの温床になります。列名か別名で書きましょう。

> ⚠️ 序数は「短く書ける」魅力がありますが、保守で壊れやすい書き方です。
> アドホックな確認以外では避けるのが無難です。

## 5. NULL の順序(既定では NULL は最小扱い)

`ORDER BY` において、SQL Server は **NULL を「最小値」として扱います**。

- 昇順(`ASC`)では NULL が **先頭** に来る。
- 降順(`DESC`)では NULL が **末尾** に来る。

```sql
-- Email 昇順。Email が NULL の社員(中村)が先頭にまとまる
SELECT EmployeeId, LastName, Email
FROM   dbo.Employees
ORDER  BY Email ASC;
```

SQL Server には `NULLS FIRST` / `NULLS LAST` 構文が **ありません**(一部の他DBにはあります)。
NULL の位置を意図的に制御したいときは、**並べ替え用の補助キー** を作ります。

```sql
-- NULL を必ず「最後」に回し、その中で Email 昇順にする
SELECT EmployeeId, LastName, Email
FROM   dbo.Employees
ORDER  BY CASE WHEN Email IS NULL THEN 1 ELSE 0 END,  -- NULL を後ろへ
          Email ASC;
```

- `CASE WHEN Email IS NULL THEN 1 ELSE 0 END` … NULL なら 1、それ以外 0。
  これを第1キーにすると NULL 行だけが後ろに集まります。

## 6. 上位 n 件を取る `TOP (n)`

`TOP (n)` は先頭から **n 件だけ** 返します。**必ず `ORDER BY` と併用**しましょう
(でないと「どの n 件か」が不定になります)。

```sql
-- 給与トップ3の社員
SELECT TOP (3) LastName, FirstName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;
```

```sql
-- 単価の高い商品トップ5
SELECT TOP (5) ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice DESC;
```

- 件数は `TOP (5)` のように **括弧で囲む** のが推奨表記です(`TOP 5` も動きますが括弧付きが今の標準)。
- `TOP` は `SELECT` に対して指定します。

## 7. 割合で取る `TOP (n) PERCENT`

`PERCENT` を付けると **全体の n%** を返します(端数は切り上げ)。

```sql
-- 給与上位25%の社員(13人なら切り上げで4人)
SELECT TOP (25) PERCENT LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;
```

- 13 行の 25% = 3.25 → **切り上げて 4 行** が返ります。

## 8. 同順位を含める `WITH TIES`

`WITH TIES` を付けると、**最後の行と ORDER BY のキー値が同じ行を全部** 含めます。
「ちょうど n 件」を超えることがあります。

```sql
-- 給与トップ3。ただし3位と同額の社員がいれば全員含める
SELECT TOP (3) WITH TIES LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC;
```

- `WITH TIES` は **`ORDER BY` が必須**(同順位の判定にキーが要るため)。
- 同順位が無ければ通常の `TOP (n)` と同じ結果になります。

> ⚠️ `WITH TIES` は結果件数が n を超えうる点に注意。
> 「厳密に n 件」が欲しい場面では使わないこと。

## 9. ページング `OFFSET-FETCH`

一覧を「1ページ n 件ずつ」表示したいときは `OFFSET ... FETCH` を使います。
**`ORDER BY` の一部**として書くため、`ORDER BY` が **必須** です。

```sql
-- 給与の高い順に並べ、6件目から5件(=2ページ目、1ページ5件想定)
SELECT LastName, Salary
FROM   dbo.Employees
ORDER  BY Salary DESC
OFFSET 5 ROWS               -- 先頭5件を飛ばす
FETCH  NEXT 5 ROWS ONLY;    -- そこから5件取る
```

- `OFFSET m ROWS` … 先頭 m 件を **スキップ**。
- `FETCH NEXT n ROWS ONLY` … そこから **n 件** 取得。
- ページ番号 `p`(1始まり)、1ページ `size` 件なら **`OFFSET (p - 1) * size ROWS FETCH NEXT size ROWS ONLY`**。

```sql
-- 3ページ目・1ページ4件(= 9件目から4件)。注文を古い順に
SELECT OrderId, OrderDate
FROM   dbo.Orders
ORDER  BY OrderDate ASC, OrderId ASC
OFFSET (3 - 1) * 4 ROWS
FETCH  NEXT 4 ROWS ONLY;
```

- `OFFSET` だけを書いて `FETCH` を省くと「先頭 m 件を飛ばして残り全部」になります。
- ページング結果を安定させるには、**一意になるまで `ORDER BY` キーを足す**(上の `OrderId` のように)。

> ⚠️ `OFFSET-FETCH` は `ORDER BY` 無しでは構文エラーになります。
> また `TOP` と `OFFSET-FETCH` は **同じクエリで併用できません**。

## よくあるつまずき

- **並び順がときどき変わる** → `ORDER BY` を書いていない。順序が要るなら必ず指定。
- **`ORDER BY 2` にしたら別の列で並んだ** → 序数はSELECTリスト変更で壊れる。列名/別名で書く。
- **NULL が先頭に来て驚く** → 既定で NULL は最小扱い。`CASE` で補助キーを作って制御する。
- **`OFFSET-FETCH` がエラー** → `ORDER BY` が必須。また `TOP` とは併用不可。
- **`WITH TIES` で n 件より多く返った** → 仕様どおり。厳密 n 件が要るなら使わない。
- **ページをめくると同じ行が重複/欠落** → `ORDER BY` が一意でない。主キーを最後のキーに足す。

## この章のまとめ

- **`ORDER BY` が無ければ順序は保証されない**。順序が意味を持つなら必ず書く。
- `ASC`(既定)/`DESC`、複数キー、式や別名で並べ替え可能。**序数(`ORDER BY 2`)は避ける**。
- SQL Server では **NULL は最小扱い**(昇順で先頭)。制御は `CASE` の補助キーで。
- `TOP (n)` / `TOP (n) PERCENT` / `WITH TIES` で上位を取得。いずれも `ORDER BY` 併用が前提。
- ページングは `OFFSET m ROWS FETCH NEXT n ROWS ONLY`。**`ORDER BY` 必須**、`TOP` とは併用不可。

➡ 演習: [exercises/03_order_paging.md](../exercises/03_order_paging.md)
