# 07 共通表式 (CTE) と再帰

> **このトピックのゴール**: `WITH` で共通表式(CTE)を定義して複雑なクエリを
> 読みやすく分割し、複数の CTE を連結できるようになる。さらに **再帰 CTE** で
> `Employees.ManagerId` の自己参照をたどり、組織階層を展開できるようになる。
>
> **前提**: [06 サブクエリ](06_subqueries.md) を済ませ、派生テーブル(FROM 句の
> サブクエリ)やスカラーサブクエリを理解していること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. CTE とは — `WITH 名前 AS (...)`

**共通表式(Common Table Expression, CTE)** は、`WITH` で名前を付けた
「一時的な名前付き結果セット」です。直後の 1 文の中で、あたかもテーブルのように参照できます。

```sql
WITH HighPaid AS (
    SELECT EmployeeId, LastName, FirstName, Salary
    FROM   dbo.Employees
    WHERE  Salary >= 500000
)
SELECT LastName, FirstName, Salary
FROM   HighPaid
ORDER  BY Salary DESC;
```

- `WITH CTE名 AS ( SELECT ... )` で定義し、続く `SELECT`(や `INSERT`/`UPDATE`/`DELETE`)から名前で参照する。
- CTE 自体はデータを保存しない。**実行時に評価される論理的な定義**にすぎない(ビューの使い捨て版のようなもの)。
- 列名は `WITH HighPaid (Id, 姓, 名, 給与) AS (...)` のように明示することもできる。

> ⚠️ `WITH` の直前の文には **セミコロンが必須**です。直前行の `;` を省略していると
> `WITH` がキーワードとして解釈されずエラーになります。安全策として **`WITH` の前に `;` を置く**
> スタイル(`;WITH ...`)を好む人もいます。

## 2. CTE は「直後の 1 文」でしか使えない

CTE のスコープは、それに続く **たった 1 つの文** だけです。次の文からはもう見えません。

```sql
WITH HighPaid AS (
    SELECT EmployeeId, Salary FROM dbo.Employees WHERE Salary >= 500000
)
SELECT COUNT(*) FROM HighPaid;   -- ○ ここでは使える

-- ✗ これは別の文。HighPaid はもう存在しないためエラーになる
SELECT AVG(Salary) FROM HighPaid;
```

- 「同じ CTE を複数の文で使い回したい」場合は、CTE ではなく **ビュー** や
  **一時テーブル** を検討する。
- 逆に「この 1 文の中だけで整理したい」なら CTE が最適。

## 3. 派生テーブル(サブクエリ)との可読性比較

同じことは `FROM` 句のサブクエリ(派生テーブル)でも書けます。CTE の主な利点は **可読性** です。

```sql
-- 派生テーブル版: ネストが深くなり、上から下へ読みにくい
SELECT d.DepartmentName, x.平均給与
FROM   dbo.Departments AS d
JOIN  (SELECT DepartmentId, AVG(Salary) AS 平均給与
       FROM   dbo.Employees
       GROUP  BY DepartmentId) AS x
  ON   x.DepartmentId = d.DepartmentId;

-- CTE 版: 「まず部署別平均を作り、それを部署名と結合する」と上から素直に読める
WITH DeptAvg AS (
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees
    GROUP  BY DepartmentId
)
SELECT d.DepartmentName, a.平均給与
FROM   dbo.Departments AS d
JOIN   DeptAvg AS a ON a.DepartmentId = d.DepartmentId;
```

- 処理内容(と多くの場合パフォーマンス)は同じ。**違いは読みやすさ**。
- CTE は「部品に名前を付けて先に定義 → 本体で組み立てる」ため、
  ロジックが複雑になるほど有利になる。
- 同じ派生結果を本体で **2 回以上参照** したいときも、CTE なら名前で使い回せる。

## 4. 複数の CTE を連結する

`WITH` の後にカンマ区切りで **複数の CTE** を並べられます。後ろの CTE は前の CTE を参照できます。

```sql
WITH DeptAvg AS (
    -- ① 部署ごとの平均給与
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees
    GROUP  BY DepartmentId
),
AboveAvg AS (
    -- ② 自部署平均を上回る社員(①を参照)
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.Salary, a.平均給与
    FROM   dbo.Employees AS e
    JOIN   DeptAvg AS a ON a.DepartmentId = e.DepartmentId
    WHERE  e.Salary > a.平均給与
)
SELECT LastName, FirstName, Salary, 平均給与
FROM   AboveAvg
ORDER  BY Salary DESC;
```

- 2 つ目以降の CTE の前は **カンマ**。`WITH` は 1 回だけ書く。
- 定義した順に「前の CTE を材料に次の CTE を作る」と、段階的に組み立てられる。
- パイプライン的に読めるので、多段集計や「絞り込み → 集計 → 再絞り込み」に向く。

## 5. 再帰 CTE の骨格

CTE は **自分自身を参照** できます。これが **再帰 CTE** で、階層(木構造)の展開に使います。
`Employees.ManagerId` は自分のテーブル(社員)を指す自己参照 FK なので、まさに好例です。

再帰 CTE は必ず次の 3 パーツで構成します。

```
WITH 再帰CTE AS (
    アンカーメンバ           -- 出発点(再帰しない SELECT)
    UNION ALL
    再帰メンバ               -- CTE 自身を参照する SELECT
)
SELECT ... FROM 再帰CTE;
```

- **アンカーメンバ**: 再帰の起点となる行。ここでは社長(`ManagerId IS NULL`, EmployeeId 1)。
- **`UNION ALL`**: アンカーと再帰結果を積み上げる。再帰 CTE では基本的に `UNION ALL` を使う。
- **再帰メンバ**: CTE 名を `FROM` に含み、1 段下の行を取り出す。参照が空になると再帰が止まる。

## 6. 組織階層の展開と階層レベルの算出

社長を第 1 レベルとして、部下をたどりながら階層レベルを 1 ずつ増やしていきます。

```sql
WITH OrgTree AS (
    -- アンカー: 社長(上司なし)。レベル 1 から開始
    SELECT e.EmployeeId,
           e.LastName,
           e.FirstName,
           e.ManagerId,
           1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL

    UNION ALL

    -- 再帰: 「1 段上の社員が OrgTree に居る」社員を取り込み、レベル+1
    SELECT e.EmployeeId,
           e.LastName,
           e.FirstName,
           e.ManagerId,
           t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   OrgTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT レベル,
       REPLICATE(N'　', レベル - 1) + LastName + FirstName AS 氏名インデント,
       EmployeeId,
       ManagerId
FROM   OrgTree
ORDER  BY レベル, EmployeeId;
```

- アンカーで `レベル = 1`、再帰メンバで `t.レベル + 1` とすることで **深さ** が求まる。
- 結合条件 `e.ManagerId = t.EmployeeId` が「子 → 親」のたどりを表す。
- `REPLICATE(N'　', レベル - 1)`(全角スペースの繰り返し)で階層をインデント表示すると、
  組織図らしく見える。このデータでは最大レベルは 3(社長 → 部長 → 担当)。

> ⚠️ 再帰メンバでは CTE 自身(`OrgTree`)を **1 回だけ** 参照でき、
> `GROUP BY` / 集約関数 / `DISTINCT` / 外部結合 / `TOP` などは使えないという制約があります。
> 複雑な集計は、再帰 CTE で階層を展開してから **外側の SELECT** で行います。

## 7. 上司チェーン(社長からのパス)を文字列化する

再帰しながら文字列を継ぎ足すと、「社長 → … → 本人」の **パス** を組み立てられます。

```sql
WITH Path AS (
    -- アンカー: 社長。パスは自分の氏名だけ
    SELECT e.EmployeeId,
           e.ManagerId,
           CAST(e.LastName + e.FirstName AS NVARCHAR(400)) AS パス,
           1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL

    UNION ALL

    -- 再帰: 親のパスに ' > 本人' を継ぎ足す
    SELECT e.EmployeeId,
           e.ManagerId,
           CAST(p.パス + N' > ' + e.LastName + e.FirstName AS NVARCHAR(400)),
           p.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   Path AS p ON e.ManagerId = p.EmployeeId
)
SELECT EmployeeId, レベル, パス
FROM   Path
ORDER  BY パス;
```

- 例: 田中健(EmployeeId 4)なら `佐藤太郎 > 鈴木花子 > 田中健` のようなパスになる。
- アンカーの文字列を `CAST(... AS NVARCHAR(400))` で **十分な長さに固定** しておくのがコツ。
  これを怠ると、再帰で文字列を継ぎ足す際に「アンカー側の型が短すぎる」型不一致エラーになりやすい。
- `ORDER BY パス` にすると、階層順に近い並びで一覧できる。

## 8. 無限ループ防止と `OPTION (MAXRECURSION n)`

もしデータに循環(A の上司が B、B の上司が A など)があると、再帰は止まりません。
SQL Server は暴走を防ぐため、**既定で再帰の深さを 100 回に制限** しています。
100 を超えるとクエリはエラーで停止します。

```sql
-- 再帰の上限を明示的に変更する(文末に置くクエリヒント)
WITH OrgTree AS (
    SELECT EmployeeId, ManagerId, 1 AS レベル
    FROM   dbo.Employees WHERE ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.ManagerId, t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   OrgTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT * FROM OrgTree
OPTION (MAXRECURSION 50);   -- 上限を 50 回に
```

- `OPTION (MAXRECURSION n)` は **クエリの一番最後**(セミコロンの直前)に 1 つだけ書く。
- `n` は 0〜32767。**`MAXRECURSION 0` は「無制限」** を意味する。
  循環が無いと確信できる正当に深い階層でだけ使い、通常は避ける。
- この上限は **安全装置** であって、循環データそのものを直してくれるわけではない。
  想定より浅い階層でエラーが出たら、まず **データの循環** を疑う。

## よくあるつまずき

- **`WITH` でいきなりエラー** → 直前の文に `;` が無い。`;WITH` と書くか直前行に `;` を付ける。
- **CTE を次の文でも使おうとしてエラー** → CTE は直後の 1 文限定。ビュー/一時テーブルを検討。
- **再帰が `MAXRECURSION` エラーで止まる** → 大半はデータの循環参照。深さを上げる前に原因を確認。
- **文字列連結パスで型エラー** → アンカー側を `CAST(... AS NVARCHAR(n))` で長めに固定する。
- **再帰メンバで `GROUP BY`/集約が使えない** → 展開は再帰 CTE、集計は外側の SELECT で。
- **アンカーの `WHERE ManagerId IS NULL` 漏れ** → 起点が全社員になり、階層レベルが正しく出ない。

## この章のまとめ

- CTE は `WITH 名前 AS (...)` で定義する使い捨ての名前付き結果セット。**直後の 1 文** でのみ有効。
- 派生テーブルと機能は同じだが、**可読性** と **再利用** で優れる。カンマ区切りで **複数 CTE を連結** できる。
- **再帰 CTE = アンカーメンバ + `UNION ALL` + 再帰メンバ**。自己参照 `ManagerId` で組織階層を展開できる。
- 階層レベルは `レベル + 1`、パスは文字列連結で作る。アンカーは `CAST` で型を固定。
- 暴走防止に既定で 100 回制限。`OPTION (MAXRECURSION n)` で調整(0 は無制限)。深すぎるエラーは循環を疑う。

➡ 演習: [exercises/07_cte.md](../exercises/07_cte.md)
