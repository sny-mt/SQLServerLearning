# 15 一時テーブルとテーブル変数

> **このトピックのゴール**: 中間結果を持つ手段(一時テーブル `#t` / テーブル変数 `@t` /
> CTE / 派生テーブル / ビュー)の違いを理解し、**「この中間結果はどこに持たせるべきか」を
> 自分で判断できる**ようになる。とくに **CTE は中間結果を実体化しない** という
> もっとも多い誤解を解き、統計情報の有無が実行プランをどう変えるかを実測で体感する。
>
> **前提**: [14 APPLY (CROSS APPLY / OUTER APPLY)](14_apply.md) までを済ませ、
> [07 共通表式 (CTE) と再帰](07_cte.md) の内容を理解していること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ この章の **5 節と 8 節** では **100万行のテーブル `dbo.OrdersBig`** を使います。
> まだ作っていない場合は、先に `sample-db/03_bulk_data.sql` を実行してください
> (環境により 10〜60 秒程度かかります)。それ以外の節は小さいテーブルだけで読めます。

## 1. 中間結果を持つ手段は 6 つある

複雑なクエリは「まず A を作り、それを材料に B を作る」という段階的な組み立てになります。
その **途中の結果(中間結果)** をどこに置くかで、選択肢は大きく 6 つあります。

```sql
-- ① ローカル一時テーブル: セッション内で共有される「本物のテーブル」
SELECT DepartmentId, AVG(Salary) AS 平均給与
INTO   #DeptAvg
FROM   dbo.Employees
GROUP  BY DepartmentId;

-- ② グローバル一時テーブル: 他のセッションからも見える
SELECT * INTO ##DeptAvgShared FROM #DeptAvg;

-- ③ テーブル変数: 変数と同じスコープ(バッチ/プロシージャ)を持つ
DECLARE @DeptAvg TABLE (DepartmentId INT, 平均給与 DECIMAL(18, 6));
INSERT INTO @DeptAvg SELECT DepartmentId, AVG(Salary) FROM dbo.Employees GROUP BY DepartmentId;

-- ④ CTE: 直後の 1 文でだけ使える名前付きの「定義」
WITH DeptAvg AS (
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees GROUP BY DepartmentId
)
SELECT * FROM DeptAvg;

-- ⑤ 派生テーブル: FROM 句の中に直接書いたサブクエリ
SELECT * FROM (SELECT DepartmentId, AVG(Salary) AS 平均給与
               FROM dbo.Employees GROUP BY DepartmentId) AS x;

-- ⑥ ビュー: データベースに永続する名前付きの定義(CREATE VIEW)
```

大分類はたった 2 つです。

- **実体化する(データが物理的に書き出される)**: ①一時テーブル ②グローバル一時テーブル ③テーブル変数
- **実体化しない(その場で展開される定義にすぎない)**: ④CTE ⑤派生テーブル ⑥ビュー

この違いが、この章のすべての判断の土台になります。

## 2. 【最重要】CTE は中間結果を実体化しない

もっとも多い誤解が **「CTE に入れておけば 1 回だけ計算されて、あとは使い回される」** というものです。
**これは誤りです。** CTE は「名前を付けた使い捨ての定義」であり、**参照した回数だけ評価されうる**
のが実態です(実際にどう展開されるかはオプティマイザが決めます)。

```sql
-- 重い集計を CTE にして「2 回」参照している
WITH DeptAvg AS (
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees
    GROUP  BY DepartmentId
)
SELECT a.DepartmentId,
       a.平均給与,
       b.平均給与 AS 相手側
FROM   DeptAvg AS a
JOIN   DeptAvg AS b ON b.DepartmentId = a.DepartmentId + 1;
```

このクエリの実行プランを見ると、**`Employees` を集計する部分が 2 か所** に現れます。
CTE 名は 1 つでも、中身は 2 回計算されているのです。

```sql
-- 一時テーブルなら「1 回だけ」計算され、以降は読むだけ
SELECT DepartmentId, AVG(Salary) AS 平均給与
INTO   #DeptAvg
FROM   dbo.Employees
GROUP  BY DepartmentId;

SELECT a.DepartmentId, a.平均給与, b.平均給与 AS 相手側
FROM   #DeptAvg AS a
JOIN   #DeptAvg AS b ON b.DepartmentId = a.DepartmentId + 1;

DROP TABLE IF EXISTS #DeptAvg;
```

- **判断基準**: 中間結果を **2 回以上参照する** かつ **その計算が重い** なら、
  CTE ではなく **一時テーブルに落とす**。
- 1 回しか参照しない整理目的なら CTE で十分(実体化のコストがかからないぶん有利)。
- ビューも派生テーブルも同じ性質(定義であって保存ではない)。
  「ビューにしたから速くなる」ということはありません。

> ⚠️ CTE を一時テーブルに落とすと **速くなることも遅くなることもある** ので、
> 「重い計算を複数回参照している」ときの手段として使ってください。
> 軽い CTE を一時テーブルにすると、書き込みコストのぶん遅くなるだけです。

## 3. ローカル一時テーブル `#t`

`#` で始まる名前のテーブルは **ローカル一時テーブル** です。作った **セッション専用** で、
実体は `tempdb` に作られます。

```sql
-- 作る前に必ず消す(SQL Server 2016+ の DROP TABLE IF EXISTS)
DROP TABLE IF EXISTS #ProductSales;

CREATE TABLE #ProductSales
(
    ProductId   INT            NOT NULL PRIMARY KEY,
    ProductName NVARCHAR(100)  NOT NULL,
    合計数量     INT            NOT NULL,
    売上合計     DECIMAL(18, 2) NOT NULL
);

INSERT INTO #ProductSales (ProductId, ProductName, 合計数量, 売上合計)
SELECT p.ProductId,
       p.ProductName,
       SUM(od.Quantity),
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
FROM   dbo.OrderDetails AS od
JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
GROUP  BY p.ProductId, p.ProductName;

SELECT * FROM #ProductSales ORDER BY 売上合計 DESC;

DROP TABLE IF EXISTS #ProductSales;
```

一時テーブルの性質:

- **実体は `tempdb`**。普通のテーブルとほぼ同じように扱える(制約・インデックス・`ALTER TABLE` も可)。
- **スコープはセッション**。同じ接続なら `GO` をまたいでも、別のバッチからも見える。
- **セッションが切れると自動的に消える**。ただし後片付けは明示的に書くのが作法。
- **名前は衝突しない**。内部的にセッションごとの一意サフィックスが付くため、
  10 人が同時に `#ProductSales` を作っても互いに干渉しません。
- **統計情報を持つ**(次節と 5 節の主役)。

> ⚠️ 同じセッションでスクリプトを2回実行すると
> `データベースに '#ProductSales' という名前のオブジェクトが既に存在します。` になります。
> **スクリプトの先頭に `DROP TABLE IF EXISTS #t;` を書く**のが定番の回避策です。

### ストアドプロシージャ内でのスコープ

一時テーブルは「呼び出し元で作ったものを、呼び出し先のプロシージャから参照できる」
という性質があります(逆はできません)。プロシージャ内で作った `#t` は、
そのプロシージャが終わると自動的に破棄されます。詳しくは
[16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) で扱います。

## 4. `SELECT INTO` と `CREATE TABLE` + `INSERT` の使い分け

一時テーブルの作り方は 2 通りあり、目的が違います。

```sql
-- (A) SELECT ... INTO: 定義を書かずに一発で作る
DROP TABLE IF EXISTS #Emp;
SELECT e.EmployeeId,
       e.LastName + N' ' + e.FirstName AS 氏名,
       d.DepartmentName,
       e.Salary
INTO   #Emp
FROM   dbo.Employees   AS e
LEFT   JOIN dbo.Departments AS d ON d.DepartmentId = e.DepartmentId;

-- (B) CREATE TABLE + INSERT: 型・NULL 許容・制約を自分で決める
DROP TABLE IF EXISTS #Emp2;
CREATE TABLE #Emp2
(
    EmployeeId     INT            NOT NULL PRIMARY KEY,
    氏名            NVARCHAR(100)  NOT NULL,
    DepartmentName NVARCHAR(50)   NULL,
    Salary         DECIMAL(18, 2) NOT NULL
);
INSERT INTO #Emp2 (EmployeeId, 氏名, DepartmentName, Salary)
SELECT e.EmployeeId,
       e.LastName + N' ' + e.FirstName,
       d.DepartmentName,
       e.Salary
FROM   dbo.Employees   AS e
LEFT   JOIN dbo.Departments AS d ON d.DepartmentId = e.DepartmentId;
```

| | `SELECT INTO` | `CREATE TABLE` + `INSERT` |
|---|---|---|
| 書く量 | 少ない(定義不要) | 多い(定義を書く) |
| 列の型 | ソースの式から**推論**される | **自分で決める** |
| NULL 許容 | ソース依存(意図せず NULL 可になりがち) | 明示できる |
| PK / 制約 | **引き継がれない** | 定義できる |
| 実行前の存在チェック | 実行するまで型が分からない | 定義が読めば分かる |
| ログ | 条件により**最小ログ**で高速 | 通常のログ |

- **試行錯誤・アドホックな分析** → `SELECT INTO` が速くて楽。
- **本番のプロシージャに入れるコード** → `CREATE TABLE` + `INSERT` で
  型と NULL 許容を固定するほうが事故が減る。
- `SELECT INTO` は **`IDENTITY` 属性を引き継いでしまう** という落とし穴があります。
  外したいときは `SELECT ISNULL(EmployeeId, 0) AS EmployeeId ...` のように式で包みます。

## 5. 一時テーブルは統計情報を持ち、インデックスを後から作れる

一時テーブルが「本物のテーブル」であることの最大の恩恵が **統計情報** です。
オプティマイザは統計情報から行数や値の分布を見積もり、
結合方式(Nested Loops / Hash Match)やメモリ量を決めます。

```sql
DROP TABLE IF EXISTS #Recent;
SELECT OrderId, CustomerId, EmployeeId, OrderDate, Amount
INTO   #Recent
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';

-- 後からインデックスを追加できる(ここが一時テーブルの強み)
CREATE NONCLUSTERED INDEX IX_Recent_CustomerId ON #Recent (CustomerId) INCLUDE (Amount);

-- 統計情報が実際に存在することを確認する
SELECT s.name           AS 統計名,
       sp.rows          AS 行数,
       sp.rows_sampled  AS 標本行数,
       sp.last_updated  AS 最終更新
FROM   tempdb.sys.stats AS s
CROSS  APPLY tempdb.sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('tempdb..#Recent');

DROP TABLE IF EXISTS #Recent;
```

- `#Recent` を作った直後は統計が無くても、**列を条件に使った時点で自動作成** されます
  (`AUTO_CREATE_STATISTICS` が既定で有効なため)。
- **後からインデックスを作れる** ので、「一時テーブルに落とす → 結合キーに索引 → 何度も結合」
  という定石が使えます。インデックスの詳細は
  [18 インデックスと実行プラン](18_indexes_execution_plans.md)。
- 一時テーブルは **トランザクションの対象**です。`BEGIN TRAN` 内での `INSERT` は
  `ROLLBACK` で取り消されます。

## 6. テーブル変数 `@t` — 手軽だが統計情報を持たない

`DECLARE @名前 TABLE (...)` で宣言するのが **テーブル変数** です。
実体はやはり `tempdb` に作られますが、**変数** として扱われる点が決定的に違います。

```sql
DECLARE @DeptSummary TABLE
(
    DepartmentId INT            NOT NULL PRIMARY KEY,   -- 制約経由なら索引になる
    人数          INT            NOT NULL,
    平均給与       DECIMAL(18, 2) NOT NULL,
    INDEX IX_平均給与 NONCLUSTERED (平均給与)              -- SQL Server 2014+ のインライン索引
);

INSERT INTO @DeptSummary (DepartmentId, 人数, 平均給与)
SELECT DepartmentId, COUNT(*), AVG(Salary)
FROM   dbo.Employees
WHERE  DepartmentId IS NOT NULL
GROUP  BY DepartmentId;

SELECT d.DepartmentName, s.人数, s.平均給与
FROM   @DeptSummary AS s
JOIN   dbo.Departments AS d ON d.DepartmentId = s.DepartmentId
ORDER  BY s.平均給与 DESC;
```

### (1) 統計情報を持たない ← 最大の弱点

テーブル変数には統計情報がありません。そのためオプティマイザは中身を見積もれず、
**行数を 1 行と推定** します(SQL Server 2017 以前、または 2019+ でも遅延コンパイルが効かない場合)。

- 実際に 10 行しか入っていないなら、推定 1 行でも大差は出ない。
- 実際に **10 万行** 入っていると、「1 行しかない」前提で
  Nested Loops やメモリ不足のソートが選ばれ、**実行プランが破綻** します。
  これが「テーブル変数にしたら急に遅くなった」の正体です。

### (2) トランザクションのロールバックの影響を受けない

テーブル変数は変数なので、**`ROLLBACK` してもデータが消えません**。
これは弱点ではなく、うまく使えば強力な性質です。

```sql
DROP TABLE IF EXISTS #Log;
CREATE TABLE #Log (メッセージ NVARCHAR(100));
DECLARE @Log TABLE (メッセージ NVARCHAR(100));

BEGIN TRAN;
    INSERT INTO #Log VALUES (N'一時テーブルに記録');
    INSERT INTO @Log VALUES (N'テーブル変数に記録');
ROLLBACK;

SELECT N'#Log'  AS 置き場所, メッセージ FROM #Log     -- 0 行(消える)
UNION ALL
SELECT N'@Log',            メッセージ FROM @Log;     -- 1 行(残る)

DROP TABLE IF EXISTS #Log;
```

- **エラー時にもログや処理結果を残したい**なら、テーブル変数が唯一の選択肢になります。
- 逆に「トランザクションと一緒に取り消してほしい」中間結果には向きません。

### (3) インデックスは「宣言時」にしか作れない

テーブル変数に `CREATE INDEX` はできません。宣言の中で作るしかありません。

- `PRIMARY KEY` / `UNIQUE` **制約経由**(どのバージョンでも可)
- `INDEX 名前 NONCLUSTERED (列)` の **インライン索引構文**(SQL Server 2014 以降)

「データを入れてみたら思ったより多かったので索引を足す」ができないのが痛いところです。

### (4) ユーザー定義関数(UDF)の中で使える

一時テーブル `#t` は **UDF 内では作れません**。UDF で中間結果を持ちたいなら
テーブル変数一択です(そもそも複数ステートメントのテーブル値関数は
`RETURNS @t TABLE (...)` という形でテーブル変数を返します)。
詳細は [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) で扱います。

### (5) SQL Server 2019+ の「テーブル変数の遅延コンパイル」

SQL Server 2019 で **テーブル変数の遅延コンパイル(Table Variable Deferred Compilation)** が
導入され、この弱点は大きく緩和されました。

- テーブル変数を参照する文のコンパイルを **実際に行が入るまで遅らせ**、
  **実際の行数** を使ってプランを作るようになります。
- 有効になる条件: **SQL Server 2019 (15.x) 以降** かつ
  **データベース互換性レベル 150 以上**。

```sql
-- 互換性レベルの確認(150 未満なら遅延コンパイルは効かない)
SELECT name, compatibility_level
FROM   sys.databases
WHERE  name = N'SalesLearning';
```

> ⚠️ 遅延コンパイルは「**行数**の見積もりを直す」だけで、
> **列の値の分布(ヒストグラム)までは分かりません**。統計情報が無いこと自体は変わらないため、
> 「大量データはやはり一時テーブル」という原則は 2019 以降も有効です。
> 2017 以前では `OPTION (RECOMPILE)` を付けると、その文だけ実際の行数でコンパイルできます。

## 7. 【判断表】結局どれを使えばいいのか

### 6 手段の性質比較

| | `#t` 一時テーブル | `##t` グローバル一時 | `@t` テーブル変数 | CTE | 派生テーブル | ビュー |
|---|---|---|---|---|---|---|
| データを実体化するか | する | する | する | **しない** | **しない** | **しない** |
| 格納先 | tempdb | tempdb | tempdb | — | — | — |
| 有効範囲 | セッション | **全セッション** | バッチ / プロシージャ | **直後の 1 文** | その `FROM` 句 | DB に永続 |
| 統計情報 | **あり** | あり | **なし** | — | — | — |
| インデックス | **後から作れる** | 後から作れる | 宣言時のみ | 不可 | 不可 | (インデックス付きビューは別) |
| `ROLLBACK` の影響 | 受ける | 受ける | **受けない** | — | — | — |
| UDF 内で使えるか | 不可 | 不可 | **可** | 可 | 可 | 可 |
| 再帰 | — | — | — | **可** | 不可 | 不可 |
| 複数回参照 | 何度でも(再計算なし) | 何度でも | 何度でも | 参照ごとに**再評価** | 1 回だけ | 参照ごとに再評価 |

### 選択のフローチャート

| こんなとき | 選ぶもの | 理由 |
|---|---|---|
| **1 文の中で整理したいだけ**(1 回参照) | **CTE** | 実体化のコストがかからず、読みやすい |
| ネストが浅く、名前を付ける価値もない | 派生テーブル | 短く書ける |
| **数十〜数百行**の小さな中間結果 | **テーブル変数** | 宣言が手軽、統計が無くても影響が小さい |
| **数千行以上**の中間結果 | **一時テーブル** | 統計情報が無いと大量データでプランが破綻する |
| 中間結果を **2 回以上参照** する | **一時テーブル** | CTE だと参照回数ぶん再計算されうる |
| 中間結果に **インデックス** を張りたい | **一時テーブル** | テーブル変数は後から張れない |
| **ロールバックしても残したい**(エラーログ等) | **テーブル変数** | トランザクションの影響を受けない |
| **UDF の中**で中間結果を持ちたい | **テーブル変数** | `#t` は UDF 内で作れない |
| 複数セッション/ジョブで共有したい | グローバル一時 `##t` or 恒久テーブル | ただし競合・寿命管理に注意 |
| 何度も使う定義を **名前で共有** したい | **ビュー** | DB に永続する定義。データは持たない |

> ⚠️ グローバル一時テーブル `##t` は「作成セッションが終了し、かつ誰も参照していない」ときに消えます。
> 名前がセッション間で共有されるため **同名衝突** や **寿命の読みにくさ** の問題があり、
> 実務ではまず使いません。「別セッションと共有したい」と思ったら、
> 通常は恒久テーブル + 明示的な削除のほうが安全です。

## 8. 【実演】100万行で見る「テーブル変数 vs 一時テーブル」

ここからは `dbo.OrdersBig`(100万行)を使います。
まず計測の道具である `SET STATISTICS IO / TIME` を覚えましょう。

```sql
SET STATISTICS IO   ON;   -- 論理読み取り(何ページ読んだか)を出す
SET STATISTICS TIME ON;   -- CPU 時間と経過時間を出す
```

- **論理読み取り(logical reads)** … バッファから読んだ 8KB ページ数。
  **環境差に左右されにくい**ので、チューニングの主指標にします。
- **CPU 時間 / 経過時間** … 実測時間。他の負荷に影響されるため、複数回の平均で見ます。
- 結果は SSMS の「メッセージ」タブに出ます。計測が終わったら `OFF` に戻します。

### (A) テーブル変数に大量投入した場合

```sql
SET STATISTICS IO, TIME ON;
GO

DECLARE @Recent2024 TABLE
(
    OrderId    INT NOT NULL PRIMARY KEY,
    CustomerId INT NOT NULL,
    Amount     DECIMAL(12, 0) NOT NULL
);

-- 2024 年分(約 10 万行)を投入
INSERT INTO @Recent2024 (OrderId, CustomerId, Amount)
SELECT OrderId, CustomerId, Amount
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';

SELECT @@ROWCOUNT AS 投入行数;

-- 顧客マスタと結合して集計
SELECT c.CustomerName,
       COUNT(*)      AS 件数,
       SUM(r.Amount) AS 売上合計
FROM   @Recent2024 AS r
JOIN   dbo.Customers AS c ON c.CustomerId = r.CustomerId
GROUP  BY c.CustomerName
ORDER  BY 売上合計 DESC;
GO
```

**実際の実行プランを含める**(SSMS で `Ctrl + M`)を有効にして実行し、
`@Recent2024` のスキャン演算子にマウスを当ててください。

- SQL Server 2017 以前 / 互換性レベル 140 以下:
  **推定行数 = 1**、実際の行数 = 約 100,000。**2 桁以上の乖離**が出ます。
  この見積もりのもとで Nested Loops が選ばれ、100,000 回のループになることがあります。
- SQL Server 2019+ / 互換性レベル 150 以上:
  遅延コンパイルにより **推定行数がほぼ実際の行数に一致** します。

### (B) 一時テーブルに落とした場合

```sql
DROP TABLE IF EXISTS #Recent2024;
GO

SELECT OrderId, CustomerId, Amount
INTO   #Recent2024
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2024-01-01';

CREATE CLUSTERED INDEX IX_Recent2024_CustomerId ON #Recent2024 (CustomerId);

SELECT c.CustomerName,
       COUNT(*)      AS 件数,
       SUM(r.Amount) AS 売上合計
FROM   #Recent2024 AS r
JOIN   dbo.Customers AS c ON c.CustomerId = r.CustomerId
GROUP  BY c.CustomerName
ORDER  BY 売上合計 DESC;
GO

DROP TABLE IF EXISTS #Recent2024;
GO
SET STATISTICS IO, TIME OFF;
GO
```

- 統計情報があるため **推定行数が実際に近く**、Hash Match による一括結合が選ばれます。
- インデックスを後付けできるので、同じ中間結果を何度も結合する場合はさらに差が開きます。

### (C) 推定と実際のズレを数値で確認する

古い互換性レベルでも新しい環境でも、**同じ文に `OPTION (RECOMPILE)` を付けると
実際の行数でコンパイル** されます。これを付ける/付けないで推定行数を比較すると、
統計情報の有無の影響がはっきり分かります。

```sql
DECLARE @T TABLE (OrderId INT PRIMARY KEY, CustomerId INT, Amount DECIMAL(12, 0));
INSERT INTO @T SELECT OrderId, CustomerId, Amount
               FROM dbo.OrdersBig WHERE OrderDate >= '2024-01-01';

-- ① そのまま(古い環境では推定 1 行)
SELECT COUNT(*) FROM @T AS t JOIN dbo.Customers AS c ON c.CustomerId = t.CustomerId;

-- ② 実際の行数でコンパイルさせる
SELECT COUNT(*) FROM @T AS t JOIN dbo.Customers AS c ON c.CustomerId = t.CustomerId
OPTION (RECOMPILE);
```

> ⚠️ 「テーブル変数だから遅い」のではなく **「見積もりが外れるから遅い」** のが本質です。
> 数十行しか入らないテーブル変数は、推定 1 行でもプランはほとんど変わらないので問題ありません。
> **行数が読めない/多い中間結果を、深く考えずにテーブル変数へ入れる** のが危険なのです。

## 9. 実務パターン: 段階的に一時テーブルへ落とす

巨大な 1 本のクエリ(CTE を 5 段も 6 段も重ねたもの)は、読みにくいだけでなく
**オプティマイザにとっても難問**です。見積もり誤差が段を重ねるごとに増幅し、
プランが不安定になります。

実務では、処理を **意味のある段** で一時テーブルに落とすのが定石です。

```sql
SET NOCOUNT ON;

DROP TABLE IF EXISTS #対象注文;
DROP TABLE IF EXISTS #明細集計;

-- 【段①】対象を絞り込む(母集合を小さくするのが最優先)
SELECT o.OrderId,
       o.CustomerId,
       o.EmployeeId,
       o.OrderDate
INTO   #対象注文
FROM   dbo.Orders AS o
WHERE  o.OrderDate >= '2023-07-01'
  AND  o.ShipDate IS NOT NULL;

CREATE CLUSTERED INDEX IX_対象注文 ON #対象注文 (OrderId);

-- 【段②】絞り込んだ注文だけを明細と結合して集計する
SELECT t.OrderId,
       SUM(od.Quantity)                                        AS 合計数量,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))      AS 売上合計
INTO   #明細集計
FROM   #対象注文        AS t
JOIN   dbo.OrderDetails AS od ON od.OrderId = t.OrderId
GROUP  BY t.OrderId;

CREATE CLUSTERED INDEX IX_明細集計 ON #明細集計 (OrderId);

-- 【段③】最終的な見せ方を組み立てる(ここは読みやすさ優先で CTE / JOIN)
SELECT c.CustomerName                          AS 顧客名,
       e.LastName + N' ' + e.FirstName          AS 担当者,
       t.OrderDate                              AS 受注日,
       s.合計数量,
       s.売上合計
FROM   #対象注文     AS t
JOIN   #明細集計     AS s ON s.OrderId = t.OrderId
JOIN   dbo.Customers AS c ON c.CustomerId = t.CustomerId
LEFT   JOIN dbo.Employees AS e ON e.EmployeeId = t.EmployeeId
ORDER  BY s.売上合計 DESC;

-- 【後片付け】
DROP TABLE IF EXISTS #対象注文;
DROP TABLE IF EXISTS #明細集計;
```

このやり方の利点:

- **可読性**: 「絞る → 集計する → 見せる」と段ごとに責務が分かれ、
  各段を単独で `SELECT` して検証できる(デバッグが劇的に楽になる)。
- **プランの安定**: 段ごとに統計情報が作られるため、見積もり誤差が次の段に伝播しにくい。
- **性能**: 早い段階で母集合を小さくし、そこにインデックスを張れる。

このパターンは、そのまま **ストアドプロシージャの中身** になります。
段①〜③をプロシージャに包み、パラメータで期間を受け取る形が実務の定番です
(→ [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md))。

> ⚠️ やりすぎにも注意。一時テーブルへの書き込みは `tempdb` への I/O を伴います。
> **軽い処理まで段に分けると遅くなります**。「重い」「複数回参照する」「索引が欲しい」
> のいずれかに当てはまる段だけを落としましょう。

## 10. 後片付けを必ず書く

一時テーブルはセッション終了で自動的に消えますが、**接続プールを使うアプリや
SSMS で同じ接続を使い回す場面では残り続けます**。次の作法を徹底してください。

```sql
-- 冒頭で「前回の残骸」を消す
DROP TABLE IF EXISTS #対象注文;
DROP TABLE IF EXISTS #明細集計;

-- ... 処理 ...

-- 末尾でも消す
DROP TABLE IF EXISTS #対象注文;
DROP TABLE IF EXISTS #明細集計;
```

- `DROP TABLE IF EXISTS` は **SQL Server 2016 以降** の構文です。
  2014 以前なら次のように書きます。

```sql
IF OBJECT_ID('tempdb..#対象注文') IS NOT NULL DROP TABLE #対象注文;
```

- 存在確認は `OBJECT_ID('tempdb..#名前')`。`#` が付いていても
  **`tempdb..` を付けて調べる**のがポイントです。
- テーブル変数は `DROP` 不要(バッチが終われば自動的に解放される)。
- グローバル一時テーブル `##t` は **必ず明示的に `DROP`** すること。
  誰かが参照している限り残り続けます。

## よくあるつまずき

- **「CTE に入れたから 1 回しか計算されない」と思い込む** → 参照回数ぶん再評価されうる。
  重い中間結果を複数回参照するなら一時テーブルへ。
- **テーブル変数に 10 万行入れて激遅** → 統計情報が無く推定 1 行。一時テーブルに変える、
  または 2019+ / 互換性レベル 150 にする、`OPTION (RECOMPILE)` を付ける。
- **`#t` が「既に存在します」エラー** → 同一セッションで再実行している。
  先頭に `DROP TABLE IF EXISTS #t;` を書く。
- **テーブル変数に `CREATE INDEX` してエラー** → 宣言時のインライン索引か制約で作る。
- **`ROLLBACK` したのにテーブル変数の中身が残っている** → 仕様どおり。
  取り消したいなら一時テーブルを使う。
- **UDF の中で `#t` を作ろうとしてエラー** → UDF 内はテーブル変数のみ。
- **`SELECT INTO` した一時テーブルに PK が無い** → 制約は引き継がれない。
  必要なら後から `ALTER TABLE` / `CREATE INDEX` で追加する。
- **`SELECT INTO` の列が意図せず `IDENTITY` になっている** → ソースの `IDENTITY` 列は引き継がれる。
  `ISNULL(列, 0)` などの式で包んで外す。
- **`OBJECT_ID('#t')` が常に NULL** → `OBJECT_ID('tempdb..#t')` と書く。

## この章のまとめ

- 中間結果の置き場所は 6 つ。分かれ目は **実体化するか(`#t` / `##t` / `@t`)、
  しないか(CTE / 派生テーブル / ビュー)**。
- **CTE は実体化しない**。名前を付けた使い捨ての定義であり、**参照した回数だけ評価されうる**。
  重い中間結果を 2 回以上参照するなら **一時テーブルに落とす**。
- **一時テーブル `#t`**: tempdb・セッションスコープ・**統計情報あり**・**後から索引を張れる**・
  `ROLLBACK` の影響を受ける。`SELECT INTO`(手軽)と `CREATE TABLE`+`INSERT`(型を固定)を使い分ける。
- **テーブル変数 `@t`**: **統計情報なし(推定 1 行)** で大量データではプランが破綻する。
  一方で **`ROLLBACK` の影響を受けず**、**UDF 内で使える**。索引は宣言時のみ。
  SQL Server 2019+ / 互換性レベル 150 の **遅延コンパイル** で行数見積もりは改善する。
- **判断の目安**: 少行数 → テーブル変数 / 多い・複数回参照・索引が要る → 一時テーブル /
  一度きりの整理 → CTE。
- 実務では **「絞る → 集計する → 見せる」を段ごとに一時テーブルへ落とす** と、
  可読性もプランの安定性も上がる。ただし軽い処理でやりすぎない。
- 計測は `SET STATISTICS IO, TIME ON`。**論理読み取り**を主指標に見る。
- **後片付け(`DROP TABLE IF EXISTS #t;`)まで必ず書く**。

➡ 演習: [exercises/15_temp_tables.md](../exercises/15_temp_tables.md)
