# 19 トランザクションと分離レベル

> **このトピックのゴール**: `BEGIN TRAN` / `COMMIT` / `ROLLBACK` の「その先」を理解する。
> ネストしたトランザクションと `@@TRANCOUNT` の本当の挙動、`SAVE TRANSACTION`、
> `XACT_ABORT` と `XACT_STATE()` によるエラー処理を書けるようになる。
> さらに **同時実行の3つの異常**(ダーティリード / ノンリピータブルリード / ファントムリード)を
> 実際に **2つのセッションで再現** し、**分離レベル**とロックの仕組み、
> **デッドロック**の原因と対策を、実務の指針まで含めて身につける。
>
> **前提**: [18 インデックスと実行プラン](18_indexes_execution_plans.md) までを済ませていること。
> トランザクションの基礎(`BEGIN TRAN` / `COMMIT` / `ROLLBACK`)は
> [13 データ操作](13_dml.md) の第8節で扱っています。本章はその **発展**です。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **最重要 — 実験用トランザクションを放置しないこと**
> 本章では「トランザクションを開いたまま、別のセッションから様子を見る」実験を何度も行います。
> **開いたまま放置したトランザクションはロックを握り続け、他のすべての作業をブロックします**。
>
> 1. データを変更する例は **必ず `BEGIN TRAN` … `ROLLBACK`** で元に戻す。
> 2. 実験が終わったら **各セッションで次を実行して `0` を確認する**。
>    ```sql
>    SELECT @@SPID AS セッションID, @@TRANCOUNT AS 開いているトランザクション数;
>    -- 0 でなければ ROLLBACK; を実行してから、もう一度確認する
>    IF @@TRANCOUNT > 0 ROLLBACK;
>    ```
> 3. クエリウィンドウを閉じる前にも `@@TRANCOUNT` を確認する。
>    (接続を切れば自動的に `ROLLBACK` されますが、**確認する癖**をつけましょう。)

---

## 1. ACID の復習 — なぜトランザクションが要るのか

トランザクションが保証する4つの性質の頭文字が **ACID** です。

| 性質 | 意味 | SQL Server での実現 |
|---|---|---|
| **A** Atomicity(原子性) | 全部成功か、全部なかったことになるか | ログ先行書き込み + `ROLLBACK` |
| **C** Consistency(一貫性) | 制約を満たした状態から満たした状態へ遷移する | PK/FK/CHECK などの制約 |
| **I** Isolation(分離性) | 同時に走る他のトランザクションの影響を受けない | **ロックと行バージョン管理(=本章の主題)** |
| **D** Durability(永続性) | `COMMIT` した変更は障害が起きても失われない | トランザクションログ |

13章では **A(原子性)** を中心に扱いました。本章の主役は **I(分離性)** です。
分離性は「完全に分離するほど安全だが、同時実行性(スループット)は落ちる」という
**トレードオフ**でできています。どこまで妥協するかを選ぶ設定が **分離レベル** です。

## 2. 3つのトランザクションモード

SQL Server には、トランザクションの始まり方が3種類あります。

### 2-1. 自動コミット(既定)

何も指定しなければ、**1文が1トランザクション**です。成功すれば自動でコミット、
エラーになれば自動でロールバックされます。

```sql
-- この1文だけで「開始 → 実行 → コミット」まで完了している
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
```

### 2-2. 明示的トランザクション

`BEGIN TRANSACTION`(短縮形 `BEGIN TRAN`)で始め、`COMMIT` / `ROLLBACK` で終えます。
**実務で意識して使うのはこれ**です。

```sql
BEGIN TRAN;
    UPDATE dbo.Products SET UnitPrice = UnitPrice * 0.9 WHERE ProductId = 2;
    SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
ROLLBACK;   -- 確認だけなので戻す
```

### 2-3. 暗黙的トランザクション

`SET IMPLICIT_TRANSACTIONS ON` にすると、`INSERT` / `UPDATE` / `DELETE` / `SELECT` などを
実行した瞬間に **自動でトランザクションが開始**され、**`COMMIT` するまで閉じません**。

```sql
SET IMPLICIT_TRANSACTIONS ON;

SELECT COUNT(*) FROM dbo.Orders;      -- ← ここでトランザクションが開始してしまう
SELECT @@TRANCOUNT AS 開いている数;    -- 1

ROLLBACK;                              -- 明示的に閉じる必要がある
SET IMPLICIT_TRANSACTIONS OFF;         -- 元に戻す
```

> ⚠️ **暗黙的トランザクションは「開きっぱなし」事故の温床**です。
> `SELECT` しただけでロックを握り続け、他のセッションを止めてしまいます。
> 一部のアプリケーション/ドライバが既定で ON にしている場合があるので、
> 原因不明のブロッキングを調査するときは真っ先に疑ってください。
> 学習中は **OFF のまま(=自動コミット + 明示的トランザクション)** で進めます。

## 3. @@TRANCOUNT とネストしたトランザクションの「実際の挙動」

`@@TRANCOUNT` は **現在のセッションで開いているトランザクションの深さ** を返します。

```sql
SELECT @@TRANCOUNT AS 深さ;   -- 0(何も開いていない)

BEGIN TRAN;
    SELECT @@TRANCOUNT AS 深さ;   -- 1
    BEGIN TRAN;
        SELECT @@TRANCOUNT AS 深さ;   -- 2
    COMMIT;
    SELECT @@TRANCOUNT AS 深さ;   -- 1  ← まだ確定していない!
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;       -- 0
```

ここが最大の落とし穴です。

> ⚠️ **SQL Server に「本当のネストしたトランザクション」は存在しません。**
> - **内側の `BEGIN TRAN`** は `@@TRANCOUNT` を **+1 するだけ**。
> - **内側の `COMMIT`** は `@@TRANCOUNT` を **-1 するだけ**で、**何も確定しません**。
>   実際にコミットされるのは `@@TRANCOUNT` が **1 → 0** になる、いちばん外側の `COMMIT` だけです。
> - **`ROLLBACK`** は深さに関係なく **いちばん外側まで一気に取り消し**、`@@TRANCOUNT` を **0** にします。

次の例で確かめてみましょう。

```sql
BEGIN TRAN;                                                    -- @@TRANCOUNT = 1
    UPDATE dbo.Products SET UnitPrice = 1 WHERE ProductId = 2;

    BEGIN TRAN;                                                -- @@TRANCOUNT = 2
        UPDATE dbo.Products SET UnitPrice = 2 WHERE ProductId = 3;
    COMMIT;                                                    -- @@TRANCOUNT = 1(確定していない)

ROLLBACK;                                                      -- @@TRANCOUNT = 0(両方とも取り消される)

-- 内側で COMMIT した ProductId=3 の変更も消えていることを確認
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
```

この性質から、**ストアドプロシージャを書くときの定石**が導けます。

```sql
-- プロシージャの中では「自分が開始したときだけ自分が終わらせる」
DECLARE @自分で開始した BIT = 0;

IF @@TRANCOUNT = 0
BEGIN
    BEGIN TRAN;
    SET @自分で開始した = 1;
END

-- ... 何らかの処理 ...

IF @自分で開始した = 1 AND @@TRANCOUNT > 0
    ROLLBACK;   -- 本番なら COMMIT
```

- 呼び出し元がすでにトランザクションを開いているのに、プロシージャが勝手に `COMMIT` すると
  呼び出し元の意図を壊します。逆に `ROLLBACK` すると **呼び出し元のトランザクションごと**消えます。
- `@@TRANCOUNT` を見て「自分が最外側かどうか」を判断するのが安全です。

## 4. SAVE TRANSACTION — 部分的に取り消す

`SAVE TRANSACTION セーブポイント名` を打っておくと、
`ROLLBACK TRANSACTION セーブポイント名` で **そこまで戻す**ことができます。

```sql
BEGIN TRAN;

    UPDATE dbo.Products SET UnitPrice = UnitPrice * 0.9 WHERE ProductId = 2;   -- ① 残したい変更

    SAVE TRANSACTION 値下げ後;          -- ← ここに印を付ける

    UPDATE dbo.Products SET UnitPrice = 0 WHERE ProductId = 3;                 -- ② やっぱり取り消したい変更

    ROLLBACK TRANSACTION 値下げ後;      -- ② だけ取り消す。トランザクションは開いたまま

    SELECT @@TRANCOUNT AS 深さ;         -- 1 のまま(閉じていない)
    SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
    -- → 2 は値下げされたまま、3 は元のまま

ROLLBACK;   -- 最後に全部戻す(学習用)
```

- `SAVE TRANSACTION` は **`@@TRANCOUNT` を変えません**(深さは 1 のまま)。
- `ROLLBACK TRANSACTION セーブポイント名` は **トランザクションを閉じません**。
  最後に必ず `COMMIT` か `ROLLBACK` が要ります。
- 名前を付けない裸の `ROLLBACK` は **全体の取り消し**です。混同しないこと。

> ⚠️ `ROLLBACK TRANSACTION 名前` で「名前付きトランザクション」の名前を指定できるのは
> **いちばん外側の `BEGIN TRAN 名前`** だけです。内側の名前を指定するとエラーになります。
> 実務では **セーブポイント名としてのみ**使うと覚えておくのが安全です。

## 5. XACT_ABORT と TRY-CATCH と XACT_STATE()

### 5-1. SET XACT_ABORT ON

既定(`OFF`)では、実行時エラーが起きても **その文だけが失敗し、トランザクションは開いたまま
続行**してしまうことがあります。これは「途中まで書き込まれた中途半端な状態でコミットする」
事故につながります。

```sql
SET XACT_ABORT ON;   -- 実行時エラーが起きたら、トランザクション全体を自動でロールバックする
```

- **`ON` にすると**、実行時エラー発生時に **トランザクション全体が自動的にロールバック**されます。
- 実務では **`SET XACT_ABORT ON;` を書くのが基本**と考えてよいです
  (特にストアドプロシージャの先頭)。
- なお `SET XACT_ABORT ON` はタイムアウト(クライアント側のキャンセル)には効きません。
  クライアント側でも確実に `ROLLBACK` する作りが必要です。

### 5-2. TRY-CATCH と XACT_STATE()

`TRY...CATCH` の `CATCH` ブロックに入ったとき、トランザクションが
「まだコミットできる状態か」を判定するのが **`XACT_STATE()`** です。

| `XACT_STATE()` | 意味 | やるべきこと |
|---|---|---|
| `1` | アクティブでコミット可能 | `COMMIT` も `ROLLBACK` も選べる |
| `0` | トランザクションが存在しない | 何もしない(`ROLLBACK` するとエラー) |
| `-1` | アクティブだが **コミット不能**(doomed) | **`ROLLBACK` するしかない** |

実務でそのまま使えるひな形です。

```sql
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRAN;

        UPDATE dbo.Employees SET Salary = Salary + 10000 WHERE DepartmentId = 2;

        -- わざとエラーを起こしてみる(0 除算)
        DECLARE @x INT = 1 / 0;

    COMMIT;
END TRY
BEGIN CATCH
    -- -1(コミット不能)なら必ずロールバック
    IF XACT_STATE() = -1
        ROLLBACK;
    -- 1(コミット可能)でも、この学習ではロールバックしておく
    ELSE IF XACT_STATE() = 1
        ROLLBACK;

    SELECT ERROR_NUMBER()  AS エラー番号,
           ERROR_MESSAGE() AS メッセージ,
           XACT_STATE()    AS 状態;

    THROW;   -- エラーを呼び出し元へ再送出(SQL Server 2012+)
END CATCH;

SELECT @@TRANCOUNT AS 残っている深さ;   -- 0 であること
```

- `IF @@TRANCOUNT > 0 ROLLBACK;` でも多くの場面で足りますが、
  **`XACT_STATE()` を見るほうが正確**です(`-1` の状態では `COMMIT` が必ず失敗する)。
- `CATCH` の中では **`ROLLBACK` してから**エラー情報を返すのが定石です。
  `ROLLBACK` する前に長い処理をすると、その間ロックを握り続けます。

## 6. 2つのセッションで実験する準備

ここから先の「同時実行の異常」「ロック」「デッドロック」は、
**1つのクエリウィンドウでは絶対に再現できません**。必ず2つ用意します。

### 6-1. セッションの開き方(SSMS)

1. SSMS のツールバーの **「新しいクエリ」** をクリックして、クエリウィンドウを **もう1つ**開く。
   (`Ctrl` + `N`。これで別の接続=別セッションになります)
2. 両方のウィンドウで `USE SalesLearning;` を実行する。
3. どちらがどちらか分かるように、両方で次を実行して **セッションID(SPID)** を控える。

```sql
SELECT @@SPID AS セッションID;
```

以降、コード例には **`-- 【セッションA】` / `-- 【セッションB】`** のラベルと
**手順番号**を付けます。**必ず書かれた順序どおりに、該当するウィンドウで実行**してください。

> ⚠️ Azure Data Studio や `sqlcmd` でも同じことができますが、
> **「1つの接続 = 1つのセッション」**である点は共通です。同じウィンドウで続けて実行すると
> 同一トランザクション内の操作になってしまい、何も再現できません。

### 6-2. 実験用の共有テーブルを作る(サンプルDBを汚さないため)

異常の再現には「片方が **COMMIT した**変更をもう片方が見る」場面があり、
本物のテーブルでやると `ROLLBACK` で戻せません。そこで
**グローバル一時テーブル(`##` で始まる名前)** を使います。
`#` で始まるローカル一時テーブルと違い、**`##` は他のセッションからも見えます**。

```sql
-- 【セッションA】手順0: 実験用テーブルを作る(Employees のコピー)
SELECT EmployeeId, LastName, FirstName, DepartmentId, Salary
INTO   ##IsoDemo
FROM   dbo.Employees;

SELECT * FROM ##IsoDemo ORDER BY EmployeeId;
```

```sql
-- 【セッションB】手順0': セッションBからも見えることを確認
SELECT * FROM ##IsoDemo ORDER BY EmployeeId;
```

- `##IsoDemo` の中では **自由に `COMMIT` して構いません**。`SalesLearning` の本物のテーブルは
  一切変わりません。
- 実験がすべて終わったら `DROP TABLE ##IsoDemo;` で片付けます
  (作成したセッションの接続が切れると自動で消えます)。

## 7. 同時実行の3つの異常

### 7-1. ダーティリード(Dirty Read)— 未コミットの値を読んでしまう

**まだ `COMMIT` されていない(取り消されるかもしれない)変更を読んでしまう**現象です。

```sql
-- 【セッションA】手順1: 給与を書き換えるが、まだコミットしない
BEGIN TRAN;
UPDATE ##IsoDemo SET Salary = 9999999 WHERE EmployeeId = 3;
-- ここで止める(COMMIT も ROLLBACK もしない)
```

```sql
-- 【セッションB】手順2: 未コミットの値を読んでしまう分離レベルで読む
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT EmployeeId, LastName, Salary FROM ##IsoDemo WHERE EmployeeId = 3;
-- → 9999999 が返る。まだ確定していない「幻の値」を読んでいる
```

```sql
-- 【セッションA】手順3: やっぱり取り消す
ROLLBACK;
```

```sql
-- 【セッションB】手順4: もう一度読むと元の値に戻っている
SELECT EmployeeId, LastName, Salary FROM ##IsoDemo WHERE EmployeeId = 3;
-- → 480000

SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- 既定に戻しておく
```

セッションBは **「存在したことのない値 9999999」で集計や判断をしてしまった**わけです。
これがダーティリードの怖さです。

### 7-2. ノンリピータブルリード(Non-repeatable Read)— 同じ行を2回読むと値が違う

**同じトランザクションの中で同じ行を2回読んだのに、値が変わっている**現象です。

```sql
-- 【セッションA】手順1: 既定(READ COMMITTED)で1回目の読み取り
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN TRAN;
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 480000
-- トランザクションは開いたまま、セッションBへ
```

```sql
-- 【セッションB】手順2: 値を変えて確定させる
BEGIN TRAN;
UPDATE ##IsoDemo SET Salary = 500000 WHERE EmployeeId = 3;
COMMIT;
```

```sql
-- 【セッションA】手順3: 同じトランザクションの中で、もう一度同じ行を読む
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 500000(値が変わった!)
ROLLBACK;
```

同じトランザクション内で「合計を出してから内訳を出す」ような処理をしていると、
**合計と内訳が合わない**という形で表面化します。

`REPEATABLE READ` にすると防げます。

```sql
-- 【セッションA】手順4: 分離レベルを上げてやり直す
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRAN;
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- 1回目
-- 共有ロックをトランザクション終了まで保持する
```

```sql
-- 【セッションB】手順5: 更新しようとすると…
UPDATE ##IsoDemo SET Salary = 700000 WHERE EmployeeId = 3;
-- → 実行中のまま止まる(ブロックされる)
```

```sql
-- 【セッションA】手順6: もう一度読んでも同じ値。終わったらロールバック
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 500000 のまま
ROLLBACK;                                     -- ← ここでセッションBのブロックが解ける
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

```sql
-- 【セッションB】手順7: 動き出したら戻しておく
-- (手順5 の UPDATE は自動コミットなので、値を元に戻す)
UPDATE ##IsoDemo SET Salary = 480000 WHERE EmployeeId = 3;
```

### 7-3. ファントムリード(Phantom Read)— 同じ条件で2回読むと行数が違う

**同じ検索条件で2回読んだのに、前回なかった行が現れる(消える)** 現象です。
値ではなく **行の集合** が変わる点がノンリピータブルリードとの違いです。

```sql
-- 【セッションA】手順1: REPEATABLE READ でも防げないことを確認する
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRAN;
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 4
```

```sql
-- 【セッションB】手順2: 条件に合う「新しい行」を追加して確定
INSERT INTO ##IsoDemo (EmployeeId, LastName, FirstName, DepartmentId, Salary)
VALUES (14, N'新井', N'翔太', 1, 400000);
```

```sql
-- 【セッションA】手順3: 同じ条件でもう一度数える
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5(幻の行が出現!)
ROLLBACK;
```

- `REPEATABLE READ` は「**すでに読んだ行**」にロックを掛けますが、
  「**まだ存在しない行**」にはロックの掛けようがありません。だからファントムが起こります。
- **`SERIALIZABLE`** は「条件に合致する **範囲** 」にロック(キー範囲ロック)を掛けるため、
  セッションBの `INSERT` 自体がブロックされ、ファントムを防げます。

```sql
-- 【セッションA】手順4: SERIALIZABLE でやり直す
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRAN;
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5
```

```sql
-- 【セッションB】手順5: INSERT がブロックされる
INSERT INTO ##IsoDemo (EmployeeId, LastName, FirstName, DepartmentId, Salary)
VALUES (15, N'岡田', N'亮', 1, 390000);
-- → 実行中のまま止まる
```

```sql
-- 【セッションA】手順6: 何度数えても 5。終わったらロールバック
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5
ROLLBACK;                                     -- ← セッションBのブロックが解ける
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

```sql
-- 【セッションB】手順7: 追加した行を消して元に戻す
DELETE FROM ##IsoDemo WHERE EmployeeId IN (14, 15);
```

## 8. 分離レベル — どれがどの異常を防ぐか

### 8-1. 対応表(この章の核心)

| 分離レベル | ダーティリード | ノンリピータブルリード | ファントムリード | 読み取りの仕組み | 同時実行性 |
|---|---|---|---|---|---|
| **READ UNCOMMITTED** | ❌ 起こる | ❌ 起こる | ❌ 起こる | 共有ロックを取らない | 最高(だが危険) |
| **READ COMMITTED**(既定) | ✅ 防ぐ | ❌ 起こる | ❌ 起こる | 文の実行中だけ共有ロック | 高 |
| **REPEATABLE READ** | ✅ 防ぐ | ✅ 防ぐ | ❌ 起こる | 読んだ行の共有ロックをトランザクション終了まで保持 | 中 |
| **SERIALIZABLE** | ✅ 防ぐ | ✅ 防ぐ | ✅ 防ぐ | キー範囲ロックで「条件の範囲」ごと固める | 低 |
| **SNAPSHOT** | ✅ 防ぐ | ✅ 防ぐ | ✅ 防ぐ | **行バージョン管理**(トランザクション開始時点のスナップショット) | 高(読み手はブロックされない) |
| **READ COMMITTED SNAPSHOT**(RCSI) | ✅ 防ぐ | ❌ 起こる | ❌ 起こる | **行バージョン管理**(文の開始時点のスナップショット) | 高(読み手はブロックされない) |

覚え方:

- 上から下へ行くほど **安全だが遅く(待ちが増え)なる**。
- 下2つ(`SNAPSHOT` / RCSI)は **仕組みが違う**。ロックで待たせるのではなく、
  **変更前の値のコピー(行バージョン)を tempdb に取っておいて読ませる**方式です。
  そのため **読み手が書き手をブロックせず、書き手も読み手をブロックしません**。
- **RCSI は `READ COMMITTED` の置き換え**、**`SNAPSHOT` は `SERIALIZABLE` に近い強さ**、
  と対応づけると整理しやすいです。

### 8-2. SET TRANSACTION ISOLATION LEVEL の書き方

```sql
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;      -- 既定
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
```

> ⚠️ **`SET TRANSACTION ISOLATION LEVEL` は「そのトランザクションだけ」ではなく、
> 接続(セッション)が閉じるか、次に変更されるまで効き続けます。**
> 「一時的に上げたつもりが、以後のクエリすべてに効いていた」は非常によくある事故です。
> 実験や一時的な変更のあとは **必ず `READ COMMITTED` に戻す**習慣をつけましょう。

現在の分離レベルは次のように確認できます。

```sql
SELECT session_id,
       transaction_isolation_level,
       CASE transaction_isolation_level
            WHEN 0 THEN N'未指定'
            WHEN 1 THEN N'READ UNCOMMITTED'
            WHEN 2 THEN N'READ COMMITTED'
            WHEN 3 THEN N'REPEATABLE READ'
            WHEN 4 THEN N'SERIALIZABLE'
            WHEN 5 THEN N'SNAPSHOT'
       END AS 分離レベル
FROM   sys.dm_exec_sessions
WHERE  session_id = @@SPID;

-- DBCC でも確認できる(結果セットの "isolation level" 行)
DBCC USEROPTIONS;
```

### 8-3. SNAPSHOT 分離 — 読み手がブロックされない

`SNAPSHOT` を使うには、まずデータベース側で有効にします。

```sql
-- データベースオプションを有効にする(実行中のトランザクションの完了を待つ)
ALTER DATABASE SalesLearning SET ALLOW_SNAPSHOT_ISOLATION ON;

-- 現在の設定を確認
SELECT name,
       snapshot_isolation_state_desc,        -- ALLOW_SNAPSHOT_ISOLATION の状態
       is_read_committed_snapshot_on         -- RCSI の状態
FROM   sys.databases
WHERE  name = N'SalesLearning';
```

2セッションで効果を確かめます。

```sql
-- 【セッションA】手順1: 商品の単価を書き換え、コミットしないまま止める
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = 9999 WHERE ProductId = 2;
```

```sql
-- 【セッションB】手順2: まずは既定(READ COMMITTED)で読む
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
-- → 返ってこない(セッションAの排他ロック待ちでブロックされる)。いったんキャンセルする
```

```sql
-- 【セッションB】手順3: SNAPSHOT で読む
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
-- → 待たされずに即座に 2800(変更前の値)が返る。ダーティリードでもない
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

```sql
-- 【セッションA】手順4: 後片付け
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0 を確認
```

- `SNAPSHOT` トランザクションが見るのは **`BEGIN TRAN` した瞬間のデータベース全体の姿**です。
  他のセッションがその後どれだけコミットしても、見える内容は変わりません(=完全に再現可能)。
- 代償は **tempdb の消費**(バージョンストア)と、**更新競合**です。

> ⚠️ **SNAPSHOT の更新競合(エラー 3960)**
> `SNAPSHOT` トランザクションが読んだ行を、他のセッションが先にコミットして書き換えていた場合、
> こちらの `UPDATE` は失敗します(`Snapshot isolation transaction aborted due to update conflict.`)。
> `SNAPSHOT` で更新を行うアプリは、**このエラーを捕まえてリトライする**設計が必要です。

### 8-4. READ COMMITTED SNAPSHOT(RCSI)

RCSI は **データベース単位のスイッチ**です。ON にすると、
そのDBの `READ COMMITTED`(=既定)の動作が **ロックを取る方式から行バージョン方式に丸ごと変わります**。
アプリケーションのコードを1行も変えずに「読み手がブロックされない」状態にできるのが最大の魅力です。

```sql
-- 他の接続がすべて閉じている必要がある。WITH ROLLBACK IMMEDIATE で他接続を強制切断する
ALTER DATABASE SalesLearning SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;

SELECT name, is_read_committed_snapshot_on FROM sys.databases WHERE name = N'SalesLearning';

-- 学習が終わったら元に戻す
ALTER DATABASE SalesLearning SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
```

| | `SNAPSHOT` | RCSI |
|---|---|---|
| 指定方法 | `SET TRANSACTION ISOLATION LEVEL SNAPSHOT`(セッション単位) | データベースオプション(既定の `READ COMMITTED` を置き換え) |
| 見えるデータの基準時点 | **トランザクション**開始時点 | **文(ステートメント)** 開始時点 |
| ノンリピータブルリード | 防ぐ | 起こる |
| アプリ改修 | 必要(明示的に指定) | 不要 |

> ⚠️ RCSI / SNAPSHOT の共通の注意点
> - **tempdb に負荷がかかります**(バージョンストア)。tempdb の容量と配置を確認すること。
> - 長時間開きっぱなしのトランザクションがあると、**バージョンストアが肥大化**します。
> - `WITH ROLLBACK IMMEDIATE` は **他の接続を強制的に切断**します。本番では実行タイミングに注意。

## 9. NOLOCK ヒントの実害 — 「速くなるおまじない」ではない

`WITH (NOLOCK)` は **そのテーブルの読み取りだけを `READ UNCOMMITTED` にする**テーブルヒントです。

```sql
-- 実務でよく見かける書き方(そして、多くの場合は不適切)
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products WITH (NOLOCK);
```

「ロックを取らないから速い・ブロックされない」という理由で乱用されがちですが、
実際には次の被害が起こり得ます。

1. **ダーティリード** — ロールバックされて **存在しなかった値** を読む。
2. **行の重複読み取り** — 読んでいる最中に他セッションの更新でページ分割が起きると、
   移動した行を **2回読んでしまう**ことがある。
3. **行の読み飛ばし** — 同じ理由で、**まだ読んでいない行が読み終えた位置に移動**し、
   結果から **丸ごと抜け落ちる**ことがある。
4. **クエリが突然エラーになる** — スキャン中にデータが移動すると
   `エラー 601: NOLOCK が指定されているため、データ移動により NULL でスキャンを続行できませんでした` が発生する。
5. **集計が静かに狂う** — 2 と 3 は **エラーにならない**のが最悪の点です。
   合計金額が「たまに」合わないという、再現困難な障害になります。

> ⚠️ **2 と 3 は「未コミットのデータを読む」とは別の問題**であり、
> **更新中でなくても、他セッションの更新と同時に読むだけで起こり得ます**。
> 「どうせ古いデータでいいから `NOLOCK`」という理屈では正当化できません。

**使ってよい場面 / 代替案**

- ✅ 概算でよい監視用クエリ、行数のざっくり把握、開発環境での調査。
- ❌ 金額・在庫・残高など **整合性が要る集計**、他システムへの連携データ、
  その結果をもとに `UPDATE` する処理。
- **本当の解決策は分離レベルの変更ではなく、次のどれか**です。
  1. **RCSI を ON にする**(読み手がブロックされない。`NOLOCK` の目的をほぼ正しく達成できる)
  2. **インデックスを適切に張って、そもそもロックを取る時間を短くする**([18章](18_indexes_execution_plans.md))
  3. **トランザクションを短くする**(第12節)
  4. 分析用途なら **レプリカや別DBへ分離する**

## 10. ロックの基礎

### 10-1. 主なロックモード

| モード | 名前 | いつ取るか | 共存できるか |
|---|---|---|---|
| **S** | 共有ロック(Shared) | 読み取り時 | S 同士は共存できる。X とは共存できない |
| **X** | 排他ロック(Exclusive) | `INSERT`/`UPDATE`/`DELETE` 時 | **誰とも共存できない** |
| **U** | 更新ロック(Update) | 更新対象を探しながら読むとき | S とは共存可。U 同士は共存 **不可** |
| **IS / IX** | 意図ロック(Intent) | 上位の粒度(ページ・テーブル)に「下位で S/X を取る予定」と印を付ける | 粒度の異なるロックの衝突判定を速くするため |

**U(更新ロック)がなぜ要るのか**: 「読んでから更新する」処理で S ロックのまま2セッションが
待ち合うと **確実にデッドロック**します。U は同時に1つしか取れないため、
片方だけが更新に進めて **デッドロックを回避**できます。
明示的に取りたいときは `WITH (UPDLOCK)` ヒントを使います。

```sql
-- 「読んで、確認して、更新する」を安全に行う定番(1文にできない場合)
BEGIN TRAN;

    SELECT UnitPrice
    FROM   dbo.Products WITH (UPDLOCK, HOLDLOCK)   -- 更新ロック + トランザクション終了まで保持
    WHERE  ProductId = 2;

    UPDATE dbo.Products SET UnitPrice = UnitPrice * 0.9 WHERE ProductId = 2;

ROLLBACK;   -- 学習用
```

### 10-2. ロックの粒度

| 粒度 | リソース種別 | 特徴 |
|---|---|---|
| 行 | `KEY`(インデックス行) / `RID`(ヒープ行) | 同時実行性が高いがロック数が増える |
| ページ | `PAGE`(8KB) | 中間 |
| テーブル | `OBJECT` | ロック数は1つで済むが、そのテーブルは事実上専有される |

SQL Server は基本的に **行ロックから始め**、1つの文が同一オブジェクトに対して
**おおむね5000個を超えるロック**を取ると、**ロックエスカレーション**でテーブルロックに
まとめてしまいます(メモリ節約のため)。

> ⚠️ 「1回の `UPDATE` で大量の行を更新したら、テーブル全体がブロックされた」の正体が
> このロックエスカレーションです。**大量更新はバッチに分割する**(`TOP (1000)` を
> ループで回すなど)のが実務の定石です。

### 10-3. ブロッキングとは

**ブロッキング** = あるセッションが必要なロックを、別のセッションがすでに握っているため
**待たされている状態**です。デッドロックと違い **エラーにはならず、ただ待ち続けます**。
これが「クエリが返ってこない」の最も多い原因です。

```sql
-- 【セッションA】手順1: 排他ロックを握ったまま止める
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = 1 WHERE ProductId = 2;
```

```sql
-- 【セッションB】手順2: 同じ行を読もうとして待たされる
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
-- → 「実行中」のまま返ってこない
```

```sql
-- 【セッションC(観察用に3つ目のウィンドウを開く)】手順3: 誰が誰を待たせているか
EXEC sp_who2;
-- BlkBy 列に「待たせている側のSPID」が表示される

-- DMV で見るほうが情報量が多い
SELECT r.session_id            AS 待っているセッション,
       r.blocking_session_id   AS 待たせているセッション,
       r.wait_type             AS 待機種別,
       r.wait_time             AS 待機ミリ秒,
       r.wait_resource         AS 待機リソース,
       t.text                  AS 実行中のSQL
FROM   sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE  r.blocking_session_id <> 0;
```

```sql
-- 【セッションC】手順4: どんなロックを握っているかを見る(セッションAのSPIDを指定)
SELECT l.request_session_id                  AS セッションID,
       l.resource_type                       AS リソース種別,
       OBJECT_NAME(p.object_id)              AS オブジェクト,
       l.request_mode                        AS ロックモード,
       l.request_status                      AS 状態          -- GRANT(獲得済) / WAIT(待機中)
FROM   sys.dm_tran_locks AS l
LEFT   JOIN sys.partitions AS p
       ON p.hobt_id = l.resource_associated_entity_id
WHERE  l.resource_database_id = DB_ID(N'SalesLearning')
ORDER  BY l.request_session_id, l.resource_type;
```

```sql
-- 【セッションA】手順5: 解放する
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0 を確認
-- → セッションB の SELECT が即座に完了する
```

- `request_status` が **`WAIT`** の行が「待たされているロック要求」です。
- 開いているトランザクションの一覧は次でも確認できます。

```sql
SELECT st.session_id, at.name, at.transaction_begin_time, at.transaction_id
FROM   sys.dm_tran_session_transactions AS st
JOIN   sys.dm_tran_active_transactions  AS at ON at.transaction_id = st.transaction_id;
```

## 11. デッドロック

### 11-1. 何が起きているか

**デッドロック** = 2つ以上のセッションが **互いに相手の握っているロックを待ち合い、
永久に進めなくなる**状態です。原因のほとんどは **リソースを獲得する順序が違う**ことです。

```
セッションA: Employees を確保 → 次に Products が欲しい(Bが握っている)
セッションB: Products  を確保 → 次に Employees が欲しい(Aが握っている)
                    ↑ 互いに永久に待つ
```

### 11-2. 実際に起こしてみる

```sql
-- 【セッションA】手順1: Employees をロック
BEGIN TRAN;
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;
```

```sql
-- 【セッションB】手順2: Products をロック(順序が A と逆)
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
```

```sql
-- 【セッションA】手順3: 次に Products が欲しい → B に待たされる
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
```

```sql
-- 【セッションB】手順4: 次に Employees が欲しい → A に待たされる = デッドロック成立
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;
```

数秒後、**どちらか一方**に次のエラーが出て強制終了されます。

```
メッセージ 1205、レベル 13、状態 45
トランザクション (プロセス ID nn) が別のプロセスとロック リソースでデッドロック状態になったため、
このトランザクションはデッドロックの対象として選択されました。トランザクションを再実行してください。
```

```sql
-- 【セッションA】【セッションB】手順5: 両方で必ず後片付け
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0 を確認
```

- **犠牲者(deadlock victim)** に選ばれた側は **自動的に完全ロールバック**されます
  (生き残った側は何事もなかったように続行します)。
- 犠牲者は基本的に **ロールバックのコストが低いほう**(それまでの更新量が少ないほう)が選ばれます。
- `SET DEADLOCK_PRIORITY LOW;`(または `HIGH` / `-10`〜`10`)で優先度を明示すると、
  「この重要でないバッチのほうを犠牲にしてほしい」と指示できます。

### 11-3. 発生を調べる

デッドロックの詳細(デッドロックグラフ)は、既定で有効な拡張イベント
`system_health` セッションに記録されています。

```sql
-- system_health のリングバッファから直近のデッドロックレポートを取り出す
SELECT CAST(xet.target_data AS XML) AS レポート
FROM   sys.dm_xe_session_targets AS xet
JOIN   sys.dm_xe_sessions        AS xe ON xe.address = xet.event_session_address
WHERE  xe.name = N'system_health'
  AND  xet.target_name = N'ring_buffer';
```

返ってきた XML の中の `<deadlock>` 要素に、
**どのセッションが / どのオブジェクトの / どのロックを待って / どのSQLを実行していたか**、
そして **どちらが犠牲者になったか** が記録されています。
SSMS ではこの XML をクリックすると **デッドロックグラフの図** として表示できます。

### 11-4. 対策

| 対策 | 内容 |
|---|---|
| **アクセス順序を統一する** | **最も効果が大きい**。「必ず Employees → Products の順で触る」など、アプリ全体でリソースの獲得順序を決める |
| **トランザクションを短くする** | ロックを握っている時間が短いほど、鉢合わせる確率が下がる |
| **適切なインデックスを張る** | インデックスがないと **不要な行まで走査してロック**する。索引で対象を絞れば衝突が激減する([18章](18_indexes_execution_plans.md)) |
| **分離レベルを上げすぎない** | `REPEATABLE READ` / `SERIALIZABLE` はロック保持が長く、デッドロックが増える |
| **`UPDLOCK` を使う** | 「読んでから更新する」パターンは、読む時点で `WITH (UPDLOCK)` を取る |
| **RCSI / SNAPSHOT** | 読み手がロックを取らなくなるので、読み書き間のデッドロックが消える |
| **リトライを実装する** | デッドロックは **設計で 0 にはできない**。エラー 1205 を捕まえて再実行する作りにする |

デッドロックはアプリ側での **リトライ**が前提の障害です。ひな形:

```sql
DECLARE @試行 INT = 0;

WHILE @試行 < 3
BEGIN
    BEGIN TRY
        SET @試行 = @試行 + 1;

        BEGIN TRAN;
            UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
        ROLLBACK;   -- 学習用(本番は COMMIT)

        BREAK;      -- 成功したらループを抜ける
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        IF ERROR_NUMBER() = 1205 AND @試行 < 3
            CONTINUE;     -- デッドロックならリトライ
        ELSE
            THROW;        -- それ以外は呼び出し元へ
    END CATCH
END
```

## 12. 実務での指針

1. **トランザクションは短く、狭く。**
   `BEGIN TRAN` から `COMMIT` までに書くのは、**本当に不可分でなければならない DML だけ**にします。
2. **トランザクションの中でユーザー入力を待たない。**
   「確認ダイアログを出して OK を待つ」間もロックは握られたままです。
   人間のクリックを待つ数十秒が、全システムを止めます。
3. **トランザクションの中でネットワークI/O・外部API呼び出しをしない。**
   同じ理由です。外部呼び出しは `COMMIT` の前後に出します。
4. **`SET XACT_ABORT ON;` を書く。** エラー時に中途半端な状態が残らないようにします。
5. **`TRY...CATCH` + `XACT_STATE()` で必ずロールバックする。**
6. **リソースへのアクセス順序をアプリ全体で統一する。** デッドロック対策の本丸です。
7. **まずインデックスを疑う。** ブロッキングもデッドロックも、
   「不要な行までロックしている」=インデックス不足が原因であることが非常に多いです。
8. **`NOLOCK` を撒くのではなく RCSI を検討する。**
9. **分離レベルを変えたら必ず戻す。** セッションに効き続けます。
10. **`@@TRANCOUNT` を確認する癖をつける。** 開きっぱなしを作らないこと。

## 13. 実験後の後片付け(必ず実行)

```sql
-- 【セッションA】【セッションB】両方で実行し、0 であることを確認する
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 深さ = 0

-- 分離レベルを既定に戻す(両方のセッションで)
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- 実験用テーブルを破棄する
IF OBJECT_ID(N'tempdb..##IsoDemo') IS NOT NULL DROP TABLE ##IsoDemo;

-- データベースオプションを元に戻す(有効化した場合のみ)
ALTER DATABASE SalesLearning SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE SalesLearning SET ALLOW_SNAPSHOT_ISOLATION OFF;

-- 本物のテーブルが元のままか確認
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
SELECT EmployeeId, LastName, Salary      FROM dbo.Employees WHERE EmployeeId = 3;
-- ProductId=2 は 2800、3 は 9800、EmployeeId=3 の Salary は 480000 であること
```

## よくあるつまずき

- **内側の `COMMIT` で確定したつもりになる** → 確定するのは `@@TRANCOUNT` が 1→0 になる
  最外側の `COMMIT` だけ。内側の `COMMIT` はカウントを1減らすだけ。
- **`ROLLBACK` が最外側まで一気に戻ることを知らない** → 部分的に戻したいなら
  `SAVE TRANSACTION` + `ROLLBACK TRANSACTION セーブポイント名`。
- **`SET TRANSACTION ISOLATION LEVEL` を戻し忘れる** → セッションに効き続ける。実験後は `READ COMMITTED` へ。
- **1つのクエリウィンドウで異常を再現しようとする** → 同一セッション内では起こらない。必ず2接続で。
- **実験用トランザクションを開いたまま席を立つ** → 他の全作業がブロックされる。`@@TRANCOUNT` を確認する。
- **`NOLOCK` を「速くするおまじない」だと思っている** → 重複読み取り・読み飛ばしという
  **エラーにならない**被害がある。RCSI やインデックス改善で解決する。
- **デッドロックをエラーとして握りつぶす** → 1205 は **リトライすべき**エラー。設計で 0 にはできない。
- **ブロッキングとデッドロックの混同** → ブロッキングは「待つだけ(いつか解ける)」、
  デッドロックは「永久に解けないので SQL Server が片方を殺す」。
- **`SNAPSHOT` にすれば全部解決だと思う** → tempdb 負荷と更新競合(3960)のリトライが必要。

## この章のまとめ

- トランザクションには **自動コミット / 明示的 / 暗黙的** の3モード。実務で使うのは明示的。
- **ネストは見かけだけ**。内側 `COMMIT` は `@@TRANCOUNT` を減らすだけ、`ROLLBACK` は全部戻す。
  部分取り消しは **`SAVE TRANSACTION`**。
- **`SET XACT_ABORT ON` + `TRY...CATCH` + `XACT_STATE()`** がエラー処理の定型。
- 同時実行の異常は **ダーティリード / ノンリピータブルリード / ファントムリード** の3つ。
  防げる範囲が **分離レベル**(READ UNCOMMITTED → READ COMMITTED → REPEATABLE READ → SERIALIZABLE)で決まる。
  **SNAPSHOT / RCSI** は行バージョン管理という別方式で、**読み手をブロックしない**。
- **`NOLOCK` は危険**。ダーティリードに加えて **行の重複読み取り・読み飛ばし**が起こる。
  代替は **RCSI / インデックス改善 / 短いトランザクション**。
- ロックは **S / X / U** と **行・ページ・テーブル**の粒度。大量更新は **ロックエスカレーション**に注意。
- **ブロッキング**は `sp_who2` の `BlkBy` や `sys.dm_exec_requests.blocking_session_id`、
  `sys.dm_tran_locks` で追える。
- **デッドロック**は獲得順序の食い違いが原因。対策は **順序統一・短いトランザクション・
  適切なインデックス**、そして **1205 のリトライ**。
- 実務の鉄則: **トランザクションは短く、中でユーザー入力や外部呼び出しを待たない**。

➡ 演習: [exercises/19_transactions_isolation.md](../exercises/19_transactions_isolation.md)
