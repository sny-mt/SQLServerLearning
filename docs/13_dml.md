# 13 データ操作 (INSERT / UPDATE / DELETE / MERGE)

> **このトピックのゴール**: 行の **追加(INSERT)・更新(UPDATE)・削除(DELETE)** と、
> 存在すれば更新・なければ追加する **MERGE(UPSERT)** を書けるようになる。
> `OUTPUT` 句で変更行を取得し、**トランザクション**で安全に操作できるようになる。
>
> **前提**: [12 組み込み関数](12_builtin_functions.md) までを済ませ、`SELECT` / `WHERE` /
> `JOIN` を自在に書けること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **最重要 — サンプルDBを壊さないための約束**
> ここまでの章と違い、DML(データ操作言語)は **テーブルの中身を実際に書き換えます**。
> `UPDATE` / `DELETE` を一度実行すると、`SELECT` のように「もう一度実行すればよい」では
> 済みません。学習用の `SalesLearning` を壊さないため、**本章の例・演習・解答は次の
> どちらかの型で必ず実行してください**。
>
> 1. **トランザクションで囲んで必ず ROLLBACK する**
>    ```sql
>    BEGIN TRAN;              -- ここから
>        -- INSERT / UPDATE / DELETE を実行し、結果を SELECT で確認
>    ROLLBACK;                -- 変更を全部なかったことにする(COMMIT しない)
>    ```
> 2. **本物のテーブルを一時テーブル(`#名前`)にコピーして、コピーの方を操作する**
>    ```sql
>    SELECT * INTO #Employees FROM dbo.Employees;   -- コピーを作る
>    -- 以降は #Employees に対して INSERT/UPDATE/DELETE する
>    ```
>
> 本章の解答 SQL(`solutions/13_dml.sql`)は、この方針に従って **すべて `ROLLBACK` するか
> 一時テーブルを使う** 形で書いてあります。実務でも、**新しい UPDATE/DELETE は
> まず `BEGIN TRAN` で試し、結果を確認してから `COMMIT`** する習慣が事故を防ぎます。

## 1. INSERT — 1行だけ追加する(VALUES)

もっとも基本的な形は `INSERT INTO テーブル (列リスト) VALUES (値リスト)` です。

```sql
BEGIN TRAN;

INSERT INTO dbo.Employees
    (EmployeeId, FirstName, LastName, DepartmentId, ManagerId, HireDate, Salary, Email)
VALUES
    (14, N'翔太', N'新井', 1, 1, '2024-04-01', 400000, N'arai@example.com');

SELECT * FROM dbo.Employees WHERE EmployeeId = 14;   -- 追加できたか確認

ROLLBACK;   -- サンプルDBを元に戻す
```

- **列リストは省略できます**が、**必ず書く**のが定石です。省略すると
  テーブルの列順に依存し、定義変更で静かに壊れます。
- 値は列リストと **同じ順序・同じ個数** で並べます。
- 日本語は `N'...'`、日付は `'YYYY-MM-DD'`(文字列)で渡せます。

> ⚠️ NULL 可の列や既定値のある列は、列リストから **外せば** 自動で NULL / 既定値が入ります。
> 逆に、`NOT NULL` で既定値の無い列を外すとエラーになります。

## 2. INSERT — 複数行をまとめて追加する

`VALUES` のあとにカンマ区切りで複数の行を並べられます(1文で最大1000行)。

```sql
BEGIN TRAN;

INSERT INTO dbo.Categories (CategoryId, CategoryName)
VALUES
    (6, N'雑貨'),
    (7, N'ソフトウェア'),
    (8, N'サービス');

SELECT * FROM dbo.Categories ORDER BY CategoryId;

ROLLBACK;
```

- 1行ずつ `INSERT` を3回書くより **速く・読みやすい**です。
- どれか1行でも制約違反(PK重複など)があると、**文全体が失敗**し1行も入りません。

## 3. INSERT ... SELECT — 問い合わせ結果を丸ごと追加する

`VALUES` の代わりに `SELECT` を書くと、**別のテーブルから取り出した行をそのまま挿入**できます。
売上明細を集計して「売上サマリーテーブル」に流し込む、といった処理の定番です。

```sql
BEGIN TRAN;

-- 集計先テーブル(ここでは一時テーブルで代用)
CREATE TABLE #SalesSummary (
    ProductId   INT         PRIMARY KEY,
    ProductName NVARCHAR(100),
    合計数量     INT,
    売上合計     DECIMAL(18,2)
);

-- 注文明細を商品ごとに集計して INSERT
INSERT INTO #SalesSummary (ProductId, ProductName, 合計数量, 売上合計)
SELECT p.ProductId,
       p.ProductName,
       SUM(od.Quantity),
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
FROM   dbo.OrderDetails AS od
JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
GROUP  BY p.ProductId, p.ProductName;

SELECT * FROM #SalesSummary ORDER BY 売上合計 DESC;

ROLLBACK;   -- #SalesSummary ごと破棄される
```

- 挿入先の **列リストと SELECT の列は、順序・個数・型が対応**していなければなりません。
- 明細金額は本プロジェクト共通で `Quantity * UnitPrice * (1 - Discount)` で計算します。
- `SELECT ... INTO 新テーブル FROM ...` は「テーブルを新規作成しながら流し込む」別構文です。
  既存テーブルへ追記するのは `INSERT ... SELECT`、新規作成は `SELECT ... INTO` と使い分けます。

## 4. UPDATE — 既存の行を書き換える(SET と WHERE)

`UPDATE テーブル SET 列 = 値, ... WHERE 条件` の形です。

```sql
BEGIN TRAN;

-- 廃番になった商品(USBハブ)の単価を見直す例
UPDATE dbo.Products
SET    UnitPrice = UnitPrice * 0.9        -- 10% 値下げ
WHERE  ProductId = 5;

SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 5;

ROLLBACK;
```

- `SET 列 = 式` はカンマ区切りで **複数列を同時に更新**できます。
- `SET Salary = Salary + 50000` のように **今の値を使った計算**もできます。
- **`WHERE` を書かないと全行が更新されます**(次の第6節を必ず読むこと)。

## 5. UPDATE ... FROM — 別テーブルと結合して更新する

「営業部(DepartmentId=1)の社員全員を5%昇給」のように、
**更新条件が別テーブルにある**ときは、T-SQL 独自の `UPDATE ... FROM` で結合できます。

```sql
BEGIN TRAN;

UPDATE e
SET    e.Salary = e.Salary * 1.05          -- 5% 昇給
FROM   dbo.Employees   AS e
JOIN   dbo.Departments AS d ON d.DepartmentId = e.DepartmentId
WHERE  d.DepartmentName = N'営業部';

SELECT EmployeeId, LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  DepartmentId = 1;

ROLLBACK;
```

- `UPDATE` の直後に書くのは **更新対象テーブルの別名**(ここでは `e`)です。
- `SET` で書き換えるのは **必ず更新対象テーブル `e` の列**です。結合相手 `d` の列は更新できません。

> ⚠️ **`UPDATE ... FROM` の落とし穴 — 結合で行が増えると結果が不定になる**
> 結合により対象テーブルの1行が **複数行にマッチ**すると、SQL Server はそのうち
> **どれか1つ**の値で更新します(どれになるかは保証されない)。
> 「1行に1回だけ効く」結合になっているか(相手が一意か)を必ず確認しましょう。

## 6. WHERE の付け忘れ — もっとも多い事故

`UPDATE` / `DELETE` で **`WHERE` を書き忘れると、テーブルの全行**が対象になります。

```sql
-- ✗ 大事故: 全社員の給与が一律 500000 になる
UPDATE dbo.Employees SET Salary = 500000;

-- ✗ 大事故: 全商品が消える
DELETE FROM dbo.Products;
```

事故を防ぐ実践的な手順:

1. **まず `SELECT` で対象を確認する**。`UPDATE`/`DELETE` の `WHERE` を、
   同じ条件の `SELECT ... WHERE` に置き換えて **何行ヒットするか**を先に見る。
2. **`BEGIN TRAN` で囲み、行数を確認してから `COMMIT`**。想定と違えば `ROLLBACK`。
3. `SET ROWCOUNT` や `TOP` で影響行を絞る、という保険もある。

```sql
-- ① まず対象を SELECT で確認
SELECT * FROM dbo.Products WHERE Discontinued = 1;

-- ② 件数に納得してから、同じ WHERE で操作(トランザクションで保護)
BEGIN TRAN;
    UPDATE dbo.Products SET UnitPrice = 0 WHERE Discontinued = 1;
    -- @@ROWCOUNT で「実際に何行変わったか」を確認できる
    SELECT @@ROWCOUNT AS 更新行数;
ROLLBACK;   -- 確認だけなので戻す(本番なら COMMIT)
```

## 7. DELETE — 行を削除する(DELETE ... FROM)

`DELETE FROM テーブル WHERE 条件` で行を削除します。`FROM` は省略できますが付けるのが一般的です。

```sql
BEGIN TRAN;

-- 廃番商品を「まだどの注文明細にも使われていない」ものだけ削除する例
DELETE p
FROM   dbo.Products AS p
WHERE  p.Discontinued = 1
  AND  NOT EXISTS (SELECT 1 FROM dbo.OrderDetails AS od
                   WHERE od.ProductId = p.ProductId);

SELECT @@ROWCOUNT AS 削除行数;

ROLLBACK;
```

- 別テーブルの条件で削除するときは `UPDATE ... FROM` と同様に **`DELETE 別名 FROM ... JOIN ...`** と書けます。
- **外部キーで参照されている行は削除できません**(参照整合性違反)。上の例のように、
  先に「参照されていないか」を確認するのが安全です。

> ⚠️ 全行を消したいだけなら `TRUNCATE TABLE テーブル` が高速です。ただし
> `TRUNCATE` は **`WHERE` を付けられず**、**`OUTPUT` も使えず**、外部キーで
> 参照されているテーブルには実行できません。行単位の制御が要るなら `DELETE` を使います。

## 8. トランザクション基礎 — BEGIN TRAN / COMMIT / ROLLBACK

**トランザクション**は「まとめて全部成功、または全部なかったことにする」ための仕組みです。
複数の DML を **1つの塊(原子的)** として扱えます。

```sql
BEGIN TRAN;                          -- トランザクション開始

    UPDATE dbo.Products SET UnitPrice = UnitPrice * 1.1 WHERE CategoryId = 1;
    DELETE FROM dbo.Products WHERE ProductId = 20;

    -- ここで結果を確認して、良ければ COMMIT、まずければ ROLLBACK
-- COMMIT;    -- ← 確定(変更を永続化)
ROLLBACK;      -- ← 取り消し(BEGIN TRAN 以降を全部戻す)
```

- `COMMIT` … それまでの変更を **確定**する。以後は取り消せない。
- `ROLLBACK` … `BEGIN TRAN` 以降の変更を **すべて取り消す**。
- 途中でエラーが起きても自動では戻りません。`TRY...CATCH` と組み合わせるのが定石です。

```sql
BEGIN TRY
    BEGIN TRAN;
        UPDATE dbo.Employees SET Salary = Salary + 10000 WHERE DepartmentId = 2;
        -- 何か別の処理 ...
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;     -- エラー時は確実に戻す
    THROW;                            -- エラーを呼び出し元へ再送出
END CATCH;
```

- `@@TRANCOUNT` は現在開いているトランザクションの深さ。`> 0` なら未確定の取引がある。
- 学習中は、上の型を **「BEGIN TRAN で始めて、確認して ROLLBACK」** と覚えておけば安全です。

## 9. OUTPUT 句 — 変更した行を取り出す

`INSERT` / `UPDATE` / `DELETE` / `MERGE` には `OUTPUT` を付けられ、
変更前後の行を **`inserted` / `deleted` 疑似テーブル** から取得できます。

| 操作 | `inserted`(変更後) | `deleted`(変更前) |
|---|---|---|
| INSERT | 挿入した行 | (なし) |
| DELETE | (なし) | 削除した行 |
| UPDATE | 更新後の行 | 更新前の行 |

```sql
BEGIN TRAN;

-- 昇給の「前後の給与」を記録しながら UPDATE する
UPDATE dbo.Employees
SET    Salary = Salary * 1.05
OUTPUT inserted.EmployeeId,
       deleted.Salary  AS 昇給前,
       inserted.Salary AS 昇給後
WHERE  DepartmentId = 2;

ROLLBACK;
```

```sql
BEGIN TRAN;

-- 削除した行を控えとして取り出す(監査ログ用途の典型)
DELETE FROM dbo.Categories
OUTPUT deleted.CategoryId, deleted.CategoryName
WHERE  CategoryId = 5;

ROLLBACK;
```

- `OUTPUT ... INTO テーブル` とすれば、変更行を **別テーブルへ保存**できます(監査ログなど)。
- 「更新できた件数だけでなく、**何がどう変わったか**」を確実に把握できるのが強みです。

## 10. MERGE — 存在すれば更新・なければ挿入(UPSERT)

`MERGE` は **ターゲット表**と **ソース**を突き合わせ、一致・不一致に応じて
`INSERT` / `UPDATE` / `DELETE` を **1文で**振り分けます。在庫やマスタの同期の定番です。

```sql
BEGIN TRAN;

-- 練習用に Categories のコピーをターゲットにする
SELECT * INTO #CatTarget FROM dbo.Categories;

-- 取り込みたい新データ(ソース): 3=既存(名称変更)/6=新規
;WITH ソース AS (
    SELECT * FROM (VALUES
        (3, N'ステーショナリー'),   -- 既存 → 名称を更新したい
        (6, N'雑貨')                 -- 新規 → 追加したい
    ) AS s (CategoryId, CategoryName)
)
MERGE #CatTarget AS T                         -- ターゲット
USING ソース      AS S                         -- ソース
    ON  T.CategoryId = S.CategoryId            -- 突き合わせキー
WHEN MATCHED THEN                              -- 両方にある → 更新
    UPDATE SET T.CategoryName = S.CategoryName
WHEN NOT MATCHED BY TARGET THEN                -- ソースのみ → 挿入
    INSERT (CategoryId, CategoryName)
    VALUES (S.CategoryId, S.CategoryName)
OUTPUT $action, inserted.CategoryId, inserted.CategoryName, deleted.CategoryName;

SELECT * FROM #CatTarget ORDER BY CategoryId;

ROLLBACK;
```

3つのマッチ節を使い分けます。

- `WHEN MATCHED` … キーが **両方にある** → 通常は `UPDATE`(または `DELETE`)。
- `WHEN NOT MATCHED [BY TARGET]` … **ソースにあってターゲットに無い** → `INSERT`。
- `WHEN NOT MATCHED BY SOURCE` … **ターゲットにあってソースに無い** → `UPDATE`/`DELETE`
  (「ソースから消えたものをターゲットからも消す」同期に使う)。

`OUTPUT` の **`$action`** には、その行が `'INSERT'` / `'UPDATE'` / `'DELETE'` の
どれで処理されたかが入ります。

> ⚠️ **MERGE の注意点**
> - 文の末尾には **必ずセミコロン `;`** が要ります(付け忘れは頻出エラー)。
> - **ソース側のキーが重複していると実行時エラー**(1つのターゲット行に複数マッチ)。
>   ソースは事前に一意化しておくこと。
> - 過去に既知の不具合報告があり、複雑な要件では **`INSERT`/`UPDATE` を分けて書くほうが
>   安全**という意見も根強い。まずは素直な UPSERT から使い始めましょう。

## よくあるつまずき

- **`WHERE` の付け忘れで全行更新/全行削除** → 先に `SELECT` で対象を確認し、`BEGIN TRAN` で保護。
- **`INSERT` の列リストを省略して壊れる** → 列リストは必ず明示する。
- **`INSERT ... SELECT` で列数/型が合わない** → 挿入先の列順と `SELECT` の列を一致させる。
- **`UPDATE ... FROM` で結合が一意でなく値がばらつく** → 相手テーブルが一意か確認する。
- **外部キー参照で `DELETE` が失敗** → 参照している子行を先に処理するか、`NOT EXISTS` で除外。
- **`MERGE` でセミコロン忘れ/ソース重複エラー** → 末尾に `;`、ソースは一意化。
- **`ROLLBACK` し忘れてサンプルDBを汚す** → 実行前に「戻す/コピーで試す」を決めておく。

## この章のまとめ

- `INSERT`(単一/複数 `VALUES`、`INSERT ... SELECT`)で行を追加、`UPDATE`(`SET`)で書き換え、
  `DELETE` で削除。別テーブル条件は `UPDATE ... FROM` / `DELETE ... FROM` で結合できる。
- **`WHERE` の付け忘れは全行操作**という最大の事故。`SELECT` で確認 → `BEGIN TRAN` で保護。
- **トランザクション**(`BEGIN TRAN`/`COMMIT`/`ROLLBACK`)で「全部成功か全部取消」を制御。
  学習中は **ROLLBACK か一時テーブル**でサンプルDBを守る。
- **`OUTPUT`** で `inserted`/`deleted` から変更行を取得(監査・確認に有用)。
- **`MERGE`** は突き合わせて UPSERT。`WHEN MATCHED` / `WHEN NOT MATCHED` を使い分け、
  **末尾のセミコロン**と **ソースの一意性**に注意する。

➡ 演習: [exercises/13_dml.md](../exercises/13_dml.md)

---

これで全トピックは修了です。おつかれさまでした！
学習の全体像は [ROADMAP](../ROADMAP.md) と [README](../README.md) で振り返れます。
気になる章を復習し、実務のクエリで腕試しをしていきましょう。
