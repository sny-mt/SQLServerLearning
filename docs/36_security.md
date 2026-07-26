# 36 セキュリティ機能

> **このトピックのゴール**: **クエリを書く人が知っておくべき** SQL Server のセキュリティ機能を、
> 「誰から・何を・どう守るのか」という **脅威モデル** とセットで理解する。
> 権限(ログイン/ユーザー/ロール/`GRANT`・`DENY`・`REVOKE`)と所有権の連鎖を土台に、
> **行レベルセキュリティ (RLS)**・**動的データマスク (DDM)**・**Always Encrypted**・
> **TDE**・**SQL Server Audit** の守備範囲と **限界** を切り分けられるようになる。
>
> **前提**: [35 データモデリングと物理設計](35_data_modeling.md) までを済ませ、
> [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) と
> [20 動的SQL](20_dynamic_sql.md) の内容を理解していること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

この章が扱うのは **T-SQL で操作できる範囲** です。ファイアウォール・OS の権限・パッチ適用・
ネットワーク暗号化(TLS)といったインフラ運用は対象外とします。
ただし「T-SQL の機能だけでは守れないもの」がどこかは、はっきり示します。

> ⚠️ **この章はサーバーを汚さないための約束**
> - **ログインの作成やサーバーレベルの権限操作は行いません。** 学習環境ごと影響が残るためです。
>   代わりに **`CREATE USER ... WITHOUT LOGIN`**(データベースユーザーのみ)と
>   **`EXECUTE AS USER = ...` / `REVERT`** で権限の検証を完結させます。
> - 既存の業務テーブル(`dbo.Customers` など)には **マスクもポリシーも直接付けません**。
>   必ず **専用のコピー表** を作り、章の最後に `DROP` します。
> - 作ったユーザー・ロール・スキーマ・述語関数・セキュリティポリシー・マスクは
>   **必ず後片付け**します(11節にチェックリストがあります)。

---

## 1. まず脅威モデルを決める

セキュリティ機能は「便利そうだから付ける」ものではありません。
**「誰から」「何を」守るのかを決めてから機能を選びます。** 逆順にすると必ず穴が空きます。

| 守る相手(脅威) | 有効な機能 | 効かない機能 |
|---|---|---|
| 権限のあるアプリ利用者が、**他人の担当データ**を見る | **RLS**、ビュー/プロシージャ経由の設計 | TDE(素通し)、DDM(推測可能) |
| 画面共有・スクリーンショットでの **偶発的な目視流出** | **DDM** | TDE、Always Encrypted(復号後は見える) |
| **DBA・クラウド運用者**など高権限者に平文を見せたくない | **Always Encrypted** | RLS / DDM / TDE(いずれも高権限者には無力) |
| **バックアップファイルやデータファイルの盗難**(物理媒体) | **TDE**、バックアップ暗号化 | RLS / DDM / Always Encrypted 単体では対象外 |
| 「誰がいつ何を見たか」を **後から証明**する必要 | **SQL Server Audit** | 上記すべて(記録は残らない) |
| アプリの脆弱性経由の **SQLインジェクション** | パラメータ化([20章](20_dynamic_sql.md))+ **最小権限** | 暗号化系すべて(正規の権限で実行されるため) |

この表の縦の並びが、そのままこの章の構成です。
**すべての機能は、最小権限という土台の上に載って初めて意味を持ちます。** そこから始めます。

## 2. 認証と承認 — ログインとユーザーは別物

SQL Server のアクセス制御は **2階建て** です。ここを混同すると権限エラーの切り分けができません。

| | 認証(誰であるか) | 承認(何ができるか) |
|---|---|---|
| **サーバーレベル** | **ログイン**(`CREATE LOGIN`)<br>Windows 認証 / SQL 認証 | サーバーロール、サーバー権限<br>(`VIEW SERVER STATE` など) |
| **データベースレベル** | **ユーザー**(`CREATE USER`)<br>通常はログインに紐づく | データベースロール、オブジェクト権限<br>(`SELECT ON dbo.Customers` など) |

- **ログイン**は「サーバーの玄関を通れるか」、**ユーザー**は「その DB の中で何ができるか」。
- 両者は `SID` で紐づきます。バックアップを別サーバーへ復元したときに
  「ユーザーはいるがログインが無い」状態になるのが有名な **孤立ユーザー(orphaned user)** です
  (`ALTER USER ... WITH LOGIN = ...` で再紐づけ)。
- **包含データベース(contained database)** ではユーザーが DB 内で認証まで完結します。
- 現在の自分を確認する関数は目的別に分かれています。

```sql
SELECT SUSER_SNAME()     AS ログイン名,      -- サーバーレベルの現在のログイン
       ORIGINAL_LOGIN()  AS 元のログイン,    -- EXECUTE AS で切り替えても変わらない(監査向き)
       USER_NAME()       AS DBユーザー名,    -- データベースレベルの現在のユーザー
       DB_NAME()         AS データベース,
       SCHEMA_NAME()     AS 既定スキーマ;
```

> ⚠️ **`ORIGINAL_LOGIN()` は `EXECUTE AS` で切り替えても変わりません。**
> 「実際に誰が操作したか」を記録したい監査ログでは、`SUSER_SNAME()` ではなく
> **`ORIGINAL_LOGIN()`** を使うのが鉄則です。

### この章で使う「ログインなしユーザー」

学習環境を汚さずに権限を検証するための定石が **`WITHOUT LOGIN`** です。

```sql
-- ログインを一切作らずに、DB 内だけに存在するユーザーを作る
CREATE USER sec_rep_suzuki WITHOUT LOGIN;

-- 権限を与えて、その人になりすまして動作確認する
GRANT SELECT ON dbo.Customers TO sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT USER_NAME() AS 現在のユーザー, ORIGINAL_LOGIN() AS 本当の私;
    SELECT COUNT(*) AS 見える顧客数 FROM dbo.Customers;
REVERT;                                   -- ★ 必ず戻す

SELECT USER_NAME() AS 戻ったか;           -- dbo に戻っていることを確認

-- 後片付け
REVOKE SELECT ON dbo.Customers FROM sec_rep_suzuki;
DROP USER IF EXISTS sec_rep_suzuki;
```

- `WITHOUT LOGIN` ユーザーは **接続に使えません**。`EXECUTE AS` でのなりすまし専用です。
- 既定で **サンドボックス化**され、そのユーザーのコンテキストからは
  他の DB やサーバーリソースへ出られません。学習・テストに最適です。
- **`REVERT` を忘れると、以降の文がすべてそのユーザーとして実行されます。**
  怪しいと思ったら `SELECT USER_NAME();` で現在地を確認してください。

## 3. スキーマとロール — 権限を個人に付けない

### スキーマは「権限をまとめる箱」

`dbo.Customers` の `dbo` はスキーマでした([01章](01_select_basics.md))。
スキーマは名前空間であると同時に、**権限付与の単位** であり **所有権の単位** でもあります。

```sql
-- スキーマ単位でまとめて権限を与えられる(表が増えても付与し直さなくてよい)
-- GRANT SELECT ON SCHEMA::dbo TO SalesReaders;

-- スキーマの所有者を確認する(所有権の連鎖の話につながる)
SELECT s.name AS スキーマ, dp.name AS 所有者
FROM   sys.schemas AS s
JOIN   sys.database_principals AS dp ON dp.principal_id = s.principal_id
WHERE  s.name NOT IN (N'sys', N'INFORMATION_SCHEMA');
```

実務では「参照系は `rpt` スキーマ、内部処理用は `int` スキーマ」のように分け、
**スキーマ単位で権限を設計**すると、テーブルが増えても権限管理が破綻しません。

### ロールに権限を、ユーザーをロールに

権限は **個人(ユーザー)ではなくロールに付ける** のが原則です。
人事異動のたびに `GRANT` を書き直す運用は必ず破綻します。

| 種類 | 例 | 用途 |
|---|---|---|
| **固定サーバーロール** | `sysadmin` / `securityadmin` / `serveradmin` / `dbcreator` | サーバー全体の管理。**安易に配らない** |
| **固定データベースロール** | `db_owner` / `db_datareader` / `db_datawriter` / `db_ddladmin` / `db_securityadmin` / `db_denydatareader` | DB 単位の粗い権限 |
| **ユーザー定義ロール** | `SalesReaders` / `SalesManagers` | **実務の主役**。業務上の役割に合わせて自分で作る |

```sql
CREATE ROLE SalesReaders AUTHORIZATION dbo;      -- 所有者を dbo にそろえる(連鎖のため)

GRANT SELECT ON dbo.Customers TO SalesReaders;   -- 権限はロールへ
ALTER ROLE SalesReaders ADD MEMBER sec_rep_suzuki;   -- 人はロールへ入れるだけ

-- 後片付けの順序: メンバーを外してからロールを削除する
-- ALTER ROLE SalesReaders DROP MEMBER sec_rep_suzuki;
-- DROP ROLE IF EXISTS SalesReaders;
```

> ⚠️ **`db_datareader` は「全テーブル読み取り」です。** 便利なので多用されがちですが、
> 後から追加されたテーブルも自動的に読めてしまいます。
> 最小権限を守るなら、**ユーザー定義ロール + 必要なオブジェクトへの `GRANT`** にしてください。

## 4. GRANT / DENY / REVOKE と「DENY 最優先」の原則

```sql
GRANT  SELECT ON dbo.Customers TO SalesReaders;      -- 許可する
DENY   SELECT ON dbo.Customers TO sec_rep_suzuki;    -- 明示的に拒否する
REVOKE SELECT ON dbo.Customers FROM sec_rep_suzuki;  -- 許可/拒否の指定そのものを消す
```

3つの関係を正確に押さえます。

| 文 | 意味 | 実行後の状態 |
|---|---|---|
| `GRANT` | 許可を与える | 許可エントリが残る |
| `DENY` | **拒否を与える** | 拒否エントリが残る |
| `REVOKE` | **`GRANT` も `DENY` も取り消す**(中立に戻す) | エントリが消える |

**`REVOKE` は「拒否」ではありません。** 「指定を消して何も言っていない状態に戻す」操作です。
他のロール経由で許可が残っていれば、`REVOKE` 後もアクセスできます。ここが最頻出の誤解です。

### 原則: DENY が最優先

ユーザーは複数のロールに属せます。権限が衝突したとき、**`DENY` が常に勝ちます**。

```sql
-- ① ロールには許可を与える
CREATE ROLE SalesReaders AUTHORIZATION dbo;
GRANT SELECT ON dbo.Customers TO SalesReaders;
ALTER ROLE SalesReaders ADD MEMBER sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT COUNT(*) AS 読める件数 FROM dbo.Customers;   -- ○ 12 件(ロール経由で許可)
REVERT;

-- ② 個人に拒否を与える → ロールの許可より DENY が勝つ
DENY SELECT ON dbo.Customers TO sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    BEGIN TRY
        SELECT COUNT(*) FROM dbo.Customers;
    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;  -- Msg 229
    END CATCH;
REVERT;

-- ③ DENY を REVOKE すると、ロールの許可が復活する
REVOKE SELECT ON dbo.Customers FROM sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT COUNT(*) AS 復活した件数 FROM dbo.Customers;   -- ○ 再び 12 件
REVERT;
```

この ①→②→③ の流れは、**権限設計を検証する基本パターン**として体に入れてください。

> ⚠️ **`DENY` が効かない相手がいます。**
> - **`sysadmin` 固定サーバーロールのメンバー**(権限チェックを通りません)
> - **オブジェクトの所有者**、および `db_owner`
> これは RLS や DDM でも同じで、「高権限者から守る」用途に権限機能は使えません。
> そこが Always Encrypted の出番です(8節)。

> ⚠️ **例外がひとつあります。** 列レベルの `GRANT` は、テーブルレベルの `DENY` を
> 上書きすることが知られています(後方互換のために残っている挙動)。
> **この例外に依存した設計をしないこと。** 正確な優先順位は公式ドキュメントの
> 「Permissions Hierarchy(権限の階層)」で必ず確認してください。

### 現在の権限を調べる

```sql
-- ① 誰にどの権限が設定されているか(state_desc が GRANT / DENY)
SELECT USER_NAME(dp.grantee_principal_id) AS 対象,
       dp.class_desc                      AS 種別,
       OBJECT_NAME(dp.major_id)           AS オブジェクト,
       dp.permission_name                 AS 権限,
       dp.state_desc                      AS 状態
FROM   sys.database_permissions AS dp
WHERE  dp.grantee_principal_id > 4          -- 組み込みプリンシパルを除く
ORDER  BY 対象, オブジェクト;

-- ② 「今の自分」が特定のオブジェクトに何をできるか
SELECT * FROM sys.fn_my_permissions(N'dbo.Customers', N'OBJECT');

-- ③ ピンポイント判定(1 = 権限あり)
SELECT HAS_PERMS_BY_NAME(N'dbo.Customers', N'OBJECT', N'SELECT') AS 読めるか;

-- ④ ロールのメンバーか
SELECT IS_ROLEMEMBER(N'SalesReaders') AS ロール所属;   -- 1 / 0 / NULL(ロールが無い)
```

②〜④は **`EXECUTE AS` の中で実行**すると、そのユーザー視点の答えが返ります。
権限のトラブルシューティングは、この4本で 9 割片が付きます。

### 最小権限の原則

- **既定は「何も与えない」。** 必要になった権限だけを、必要な期間だけ与える。
- 個人ではなく **ロール** に与える。
- テーブルへの直接権限ではなく、**ビュー / ストアドプロシージャ経由**にする(次節)。
- アプリの接続ユーザーに `db_owner` を与えない。これだけで
  SQLインジェクションが成立したときの被害が桁違いに変わります。

## 5. 所有権の連鎖 — ビュー/プロシージャ経由で見せる

**所有権の連鎖(ownership chaining)** は、権限設計の要になる仕組みです。

> ビューやプロシージャと、それが参照するテーブルの **所有者が同じ** なら、
> 呼び出し元ユーザーは **参照先テーブルの権限チェックを免除される**。

```sql
-- 顧客の要約ビュー(基表は dbo.Customers / dbo.Orders / dbo.OrderDetails)
CREATE VIEW dbo.vw_CustomerSalesSummary
AS
SELECT c.CustomerId,
       c.CustomerName,
       c.Region,
       COUNT(DISTINCT o.OrderId)                                   AS 注文件数,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))          AS 売上合計
FROM   dbo.Customers    AS c
LEFT   JOIN dbo.Orders  AS o  ON o.CustomerId = c.CustomerId
LEFT   JOIN dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY c.CustomerId, c.CustomerName, c.Region;
GO

-- ビューにだけ SELECT を与える(基表には一切与えない)
GRANT SELECT ON dbo.vw_CustomerSalesSummary TO sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT TOP (3) * FROM dbo.vw_CustomerSalesSummary ORDER BY 売上合計 DESC;  -- ○ 読める
    -- SELECT * FROM dbo.Customers;   -- ✗ Msg 229: 基表には権限が無い
REVERT;
```

- これが「**テーブルは隠し、必要な形だけをビュー/プロシージャで見せる**」設計の技術的根拠です。
- 同じ理屈がストアドプロシージャにも効きます([16章](16_stored_procedures.md))。
  `EXECUTE` 権限だけ渡せば、内部の `INSERT`/`UPDATE` は動きます。

### 連鎖が切れる3つのケース

| ケース | 理由 | 対処 |
|---|---|---|
| **動的SQL**([20章](20_dynamic_sql.md)) | 別バッチとして実行され、連鎖が途切れる | `WITH EXECUTE AS OWNER` / モジュール署名 |
| **所有者が異なる**(別スキーマ・別ユーザー所有) | 連鎖の条件を満たさない | 所有者をそろえる / 署名 |
| **データベースをまたぐ参照** | 既定では DB 間の連鎖は無効 | 原則そのまま(DB 間連鎖の有効化は非推奨) |

```sql
-- 動的SQL を含むプロシージャは連鎖が切れる
CREATE PROCEDURE dbo.usp_SecDynamicCount
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_executesql N'SELECT COUNT(*) AS 顧客数 FROM dbo.Customers;';
END;
GO
GRANT EXECUTE ON dbo.usp_SecDynamicCount TO sec_rep_suzuki;

EXECUTE AS USER = N'sec_rep_suzuki';
    BEGIN TRY
        EXEC dbo.usp_SecDynamicCount;      -- ✗ 基表権限が無いのでエラー
    END TRY
    BEGIN CATCH
        SELECT ERROR_MESSAGE() AS 連鎖が切れた;
    END CATCH;
REVERT;
```

## 6. EXECUTE AS による実行コンテキストの切り替え

`EXECUTE AS` には **2つの使い方** があります。混同しないでください。

### (a) 文としての `EXECUTE AS` — テスト・検証用

```sql
EXECUTE AS USER = N'sec_rep_suzuki';   -- DB ユーザーになりすます
    -- ここでの実行はすべて sec_rep_suzuki の権限で行われる
REVERT;                                 -- 元に戻す(スタック構造。入れ子も可能)
```

- `EXECUTE AS LOGIN = ...` はサーバーレベル。**この章では使いません。**
- **`WITH NO REVERT` は使わないこと。** 接続を切るまで戻れなくなります。
- 入れ子にした場合、`REVERT` は 1 段ずつ戻ります。

### (b) モジュール定義としての `EXECUTE AS` — 設計用

プロシージャ・関数・トリガーの定義に付けると、**実行時の権限コンテキスト**を固定できます。

| 指定 | 実行される権限 | 使いどころ |
|---|---|---|
| `CALLER`(既定) | 呼び出したユーザー | 通常。所有権の連鎖が効く範囲で十分なとき |
| **`OWNER`** | モジュールの所有者 | **動的SQLで連鎖が切れるとき**の第一候補 |
| `SELF` | 作成/変更した本人 | 作成者権限で固定したいとき |
| `'ユーザー名'` | 指定ユーザー | 専用の低権限ユーザーを用意して絞りたいとき |

```sql
-- 5節で失敗したプロシージャを EXECUTE AS OWNER で作り直す
CREATE OR ALTER PROCEDURE dbo.usp_SecDynamicCount
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ORIGINAL_LOGIN() AS 実際の呼び出し元,   -- ← 監査はこちらを記録する
           USER_NAME()      AS 実行コンテキスト;    -- ← dbo になっている
    EXEC sys.sp_executesql N'SELECT COUNT(*) AS 顧客数 FROM dbo.Customers;';
END;
GO

EXECUTE AS USER = N'sec_rep_suzuki';
    EXEC dbo.usp_SecDynamicCount;      -- ○ 今度は成功する
REVERT;
```

> ⚠️ **`EXECUTE AS OWNER` は「権限の昇格装置」です。**
> そのプロシージャの中身に少しでもインジェクションの穴があれば、
> 攻撃者は所有者(多くは `dbo`)の権限で任意の SQL を実行できます。
> **`EXECUTE AS OWNER` を付けたモジュールほど、[20章](20_dynamic_sql.md) の
> パラメータ化と `QUOTENAME` + ホワイトリスト検証を厳密に守ってください。**

より安全なのは **モジュール署名(module signing)** です。証明書でモジュールに署名し、
その証明書から作ったユーザーにだけ必要最小限の権限を与えます
(`CREATE CERTIFICATE` → `ADD SIGNATURE TO ... BY CERTIFICATE`)。
`EXECUTE AS OWNER` のような広い昇格を避けられるため、**本番設計ではこちらが本命**です。
キーワードだけ覚えておき、必要になったら公式ドキュメントを引いてください。

## 7. 行レベルセキュリティ (RLS) — SQL Server 2016 以降

**RLS(Row-Level Security)** は「**どの行が見えるか**」をデータベース側で強制する機能です。
アプリ側の `WHERE` 句に頼らないので、**アプリを迂回した接続にも同じルールが適用されます**。

構成要素は2つだけです。

1. **述語関数** … インラインテーブル値関数(TVF)。`WITH SCHEMABINDING` 必須。
   「アクセスしてよい行なら 1 行返す」関数を書く。
2. **セキュリティポリシー** … 述語関数をテーブルの列に結び付ける。

### 実例: 営業担当は自分の担当顧客だけ見える

`dbo.Customers` の `SalesRepId`(担当営業の `EmployeeId`)を使います。
**業務テーブルには直接付けず、コピー表で試します。**

```sql
-- ① セキュリティ用オブジェクトは専用スキーマにまとめるのが定石
CREATE SCHEMA sec AUTHORIZATION dbo;
GO

-- ② 検証用のコピー表(業務テーブルは触らない)
SELECT * INTO dbo.CustomersRls FROM dbo.Customers;
ALTER TABLE dbo.CustomersRls ADD CONSTRAINT PK_CustomersRls PRIMARY KEY (CustomerId);
GO

-- ③ DB ユーザー → 担当営業(EmployeeId)の対応表
CREATE TABLE dbo.SalesRepUserMap
(
    UserName   SYSNAME NOT NULL CONSTRAINT PK_SalesRepUserMap PRIMARY KEY,
    EmployeeId INT     NOT NULL
);
INSERT INTO dbo.SalesRepUserMap (UserName, EmployeeId)
VALUES (N'sec_rep_suzuki', 2),        -- 鈴木花子 → 顧客 1, 2, 7
       (N'sec_rep_takahashi', 3);     -- 高橋一郎 → 顧客 3, 5, 8, 12
GO

-- ④ 述語関数: アクセス可なら1行返す
CREATE FUNCTION sec.fn_CustomerAccess(@SalesRepId AS INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS fn_access
    WHERE  DATABASE_PRINCIPAL_ID() = DATABASE_PRINCIPAL_ID(N'dbo')   -- 管理者は全件
       OR  IS_ROLEMEMBER(N'SalesManagers') = 1                        -- 管理職は全件
       OR  EXISTS (SELECT 1
                   FROM   dbo.SalesRepUserMap AS m
                   WHERE  m.UserName   = USER_NAME()
                     AND  m.EmployeeId = @SalesRepId);                -- 自分の担当だけ
GO

-- ⑤ ポリシーで結び付ける
CREATE SECURITY POLICY sec.CustomerAccessPolicy
    ADD FILTER PREDICATE sec.fn_CustomerAccess(SalesRepId) ON dbo.CustomersRls
WITH (STATE = ON, SCHEMABINDING = ON);
GO
```

動作確認します。

```sql
CREATE USER sec_rep_suzuki    WITHOUT LOGIN;
CREATE USER sec_rep_takahashi WITHOUT LOGIN;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.CustomersRls TO sec_rep_suzuki, sec_rep_takahashi;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT CustomerId, CustomerName, SalesRepId FROM dbo.CustomersRls;
    -- → 顧客 1(アルファ商事), 2(ベータ工業), 7(イータ建設) の3件だけ
REVERT;

EXECUTE AS USER = N'sec_rep_takahashi';
    SELECT COUNT(*) AS 見える件数 FROM dbo.CustomersRls;   -- → 4 件(顧客 3, 5, 8, 12)
REVERT;
```

- 述語関数の引数に渡すのは **列名**(`SalesRepId`)です。ポリシーが行ごとに値を渡します。
- **`SalesRepId` が NULL の顧客(9 イオタ商会・11 ラムダソフト)は誰にも見えません。**
  `NULL = 2` は真にならないためです([11章](11_conditional_null.md))。
  「担当未設定の行を誰が見るのか」は業務要件として必ず決めてください。
- 呼び出し側ユーザーには、**述語関数や対応表への権限は不要**です(所有権の連鎖が働きます)。

> ⚠️ **`dbo`(db_owner)や `sysadmin` も RLS の対象です。** 上の例で
> `DATABASE_PRINCIPAL_ID() = DATABASE_PRINCIPAL_ID(N'dbo')` を入れているのはそのためで、
> これを書き忘れると **管理者自身が自分のデータを見られなくなります**。
> 逆に、高権限者はポリシー自体を `STATE = OFF` にできるので、**RLS は高権限者対策にはなりません**。

### FILTER PREDICATE と BLOCK PREDICATE の違い

| | FILTER PREDICATE | BLOCK PREDICATE |
|---|---|---|
| 効果 | 条件に合わない行を **無かったことにする** | 条件に合わない **書き込みをエラーにする** |
| 対象 | `SELECT` / `UPDATE` / `DELETE` の**読み取り側** | `INSERT` / `UPDATE` / `DELETE` |
| 挙動 | 静かに 0 行になる(エラーにならない) | **エラー(Msg 33504)** になる |
| 指定 | `ADD FILTER PREDICATE ...` | `ADD BLOCK PREDICATE ... AFTER INSERT` など |

**FILTER だけでは書き込みを守れません。** 重要な穴が1つあります。

```sql
-- FILTER PREDICATE だけの状態で…
EXECUTE AS USER = N'sec_rep_suzuki';
    INSERT INTO dbo.CustomersRls (CustomerId, CustomerName, City, Region, SalesRepId)
    VALUES (101, N'テスト商事', N'東京', N'関東', 4);   -- ← 他人(担当4)の行を作れてしまう
    SELECT * FROM dbo.CustomersRls WHERE CustomerId = 101;   -- しかも自分には見えない
REVERT;
```

これを塞ぐのが **BLOCK PREDICATE** です。

```sql
ALTER SECURITY POLICY sec.CustomerAccessPolicy
    ADD BLOCK PREDICATE sec.fn_CustomerAccess(SalesRepId) ON dbo.CustomersRls AFTER INSERT;

EXECUTE AS USER = N'sec_rep_suzuki';
    BEGIN TRY
        INSERT INTO dbo.CustomersRls (CustomerId, CustomerName, City, Region, SalesRepId)
        VALUES (102, N'ブロック確認', N'東京', N'関東', 4);
    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS 番号, ERROR_MESSAGE() AS メッセージ;   -- Msg 33504
    END CATCH;
REVERT;
```

BLOCK は 4 種類を指定できます。**「変更後の行」を見るか「変更前の行」を見るか**の違いです。

| 指定 | 意味 |
|---|---|
| `AFTER INSERT` | 挿入後の行が述語を満たさなければ拒否(他人の行を作らせない) |
| `AFTER UPDATE` | 更新後の行が述語を満たさなければ拒否(他人へ付け替えさせない) |
| `BEFORE UPDATE` | 更新前の行が述語を満たさなければ拒否 |
| `BEFORE DELETE` | 削除対象の行が述語を満たさなければ拒否 |

> ⚠️ `BEFORE UPDATE` / `BEFORE DELETE` は、FILTER PREDICATE を併用していれば
> 多くの場合すでに 0 行に絞られています(見えない行は更新も削除もできない)。
> **エラーで気付かせたい**のか、**静かに 0 行にしたい**のかで選び分けてください。

### 中間層アプリのパターン: SESSION_CONTEXT

Web アプリは通常、**1つの接続ユーザー**で全エンドユーザーの処理を行います。
この場合は DB ユーザー名ではなく **`SESSION_CONTEXT`**(2016 以降)に利用者情報を載せます。

```sql
-- アプリが接続直後に実行する(read_only = 1 で以後の書き換えを禁止できる)
EXEC sys.sp_set_session_context @key = N'SalesRepId', @value = 2, @read_only = 1;

SELECT CAST(SESSION_CONTEXT(N'SalesRepId') AS INT) AS 現在の担当;
```

```sql
-- 述語関数はセッション値と比較するだけ。対応表への結合が消えるので速い
-- CREATE FUNCTION sec.fn_CustomerAccessBySession(@SalesRepId INT)
-- RETURNS TABLE WITH SCHEMABINDING
-- AS RETURN
--     SELECT 1 AS fn_access
--     WHERE  @SalesRepId = CAST(SESSION_CONTEXT(N'SalesRepId') AS INT)
--        OR  DATABASE_PRINCIPAL_ID() = DATABASE_PRINCIPAL_ID(N'dbo');
```

- **`@read_only = 1` は必須級**です。これを付けないと、アプリ経由で任意の SQL を
  実行できる攻撃者が自分で `SalesRepId` を書き換えられます。
- 接続プールで接続が再利用されると `SESSION_CONTEXT` は **リセットされます**
  (`sp_reset_connection` が走るため)。アプリ側は毎回セットする実装にします。

### 性能への影響 — 述語はすべてのクエリに付く

RLS の述語関数は、**そのテーブルを触るすべてのクエリに追加**されます。
インライン TVF なのでプランに展開され、実質「隠れた `WHERE` 句」として振る舞います。

**測り方**(推測せず必ず計測してください):

```sql
SET STATISTICS IO, TIME ON;

EXECUTE AS USER = N'sec_rep_suzuki';
    SELECT COUNT(*) FROM dbo.CustomersRls;
REVERT;

SET STATISTICS IO, TIME OFF;
-- 実際の実行プランを表示して、述語が Seek の述語(Seek Predicates)として
-- 使われているか、それとも Filter 演算子として後付けされているかを見る
```

**判断基準**:

| 観察 | 疑うこと | 対処 |
|---|---|---|
| 論理読み取りがポリシー適用前より **大幅に増えた** | 述語が SARGable でなく、全件読んでから絞っている | 述語を「列 = 値」の素直な形に直す |
| プランに **Filter 演算子** が現れ、その手前で行数が多い | インデックスシークに落ちていない | 述語で使う列にインデックスを作る |
| プランに **Nested Loops + 対応表のスキャン** | 述語関数内の結合が毎回走っている | `SESSION_CONTEXT` 方式に変える / 対応表に PK を張る |

**述語関数を書くときの鉄則**:

- **述語列に関数を掛けない。** `WHERE @SalesRepId = CAST(SESSION_CONTEXT(...) AS INT)` は
  引数側だけを変換しているので SARGable ですが、
  `WHERE CAST(@SalesRepId AS NVARCHAR(10)) = ...` と書くと **インデックスが使えません**
  ([18章](18_indexes_execution_plans.md))。
- **述語関数の中で複数テーブルを結合しない。** どうしても必要なら結合先に PK/インデックスを張る。
- 述語で使う列(この例では `SalesRepId`)には **インデックスを検討**する。
- 述語関数は **インライン TVF のみ**。スカラー関数やマルチステートメント TVF は使えません
  (使えたとしても性能上あり得ません)。

### RLS の限界 — サイドチャネルによる情報漏洩

正直に書きます。**RLS は「見せない」機能であって、「推測させない」機能ではありません。**

任意の T-SQL を書ける利用者は、**エラーやタイミングを手がかりに、見えないはずの行の存在や値を
推測できる**ことがあります。代表的な手口が **除算エラー** を使った探索です。

```sql
-- 概念例: 見えないはずの行に対して、条件を満たすときだけ 0 除算を起こさせる
-- SELECT * FROM dbo.CustomersRls WHERE CustomerId = 5 AND 1 / (SalesRepId - 3) = 1;
--   → エラーが出るか出ないかで「CustomerId=5 の SalesRepId が 3 かどうか」が分かってしまう
```

なぜ起きるかというと、**セキュリティ述語とユーザーの述語の評価順序はオプティマイザ次第**であり、
ユーザーが書いた式が先に評価されることがあるからです。
公式ドキュメントも「巧妙に作られたクエリによって情報が漏れる可能性がある」と明記しています。

したがって:

- RLS は **アプリ経由の正規アクセスに対する強力なガードレール**として使う。
- **任意の T-SQL を実行できる相手**(アドホッククエリを許した BI ツールや分析者)に対しては、
  RLS を「絶対的な壁」と考えない。その場合は **ビュー/プロシージャに限定した権限**を併用する。
- 本当に見せてはいけない値は、そもそも **その接続から到達できない場所**に置く
  (別 DB・別サーバー・Always Encrypted)。

## 8. 動的データマスク (DDM) — SQL Server 2016 以降

**DDM(Dynamic Data Masking)** は、権限のないユーザーに対して **列の値を伏せて表示** する機能です。
`UNMASK` 権限を持たないユーザーの **クエリ結果だけ** が書き換わります。データ自体は平文のままです。

```sql
-- 検証用のコピー表(業務テーブルにはマスクを付けない)
SELECT EmployeeId, FirstName, LastName, Email, Salary, DepartmentId
INTO   dbo.EmployeesMasked
FROM   dbo.Employees;
ALTER TABLE dbo.EmployeesMasked ADD CONSTRAINT PK_EmployeesMasked PRIMARY KEY (EmployeeId);
GO

ALTER TABLE dbo.EmployeesMasked ALTER COLUMN Email    ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE dbo.EmployeesMasked ALTER COLUMN Salary   ADD MASKED WITH (FUNCTION = 'random(1, 999999)');
ALTER TABLE dbo.EmployeesMasked ALTER COLUMN LastName ADD MASKED WITH (FUNCTION = 'partial(1, "***", 0)');
GO
```

### マスク関数の種類

| 関数 | 効果 | 例 |
|---|---|---|
| `default()` | 型に応じた既定値。文字列は `xxxx`、数値は `0`、日付は `1900-01-01` | `xxxx` |
| `email()` | 先頭1文字 + `XXX@XXXX.com` | `sXXX@XXXX.com` |
| `partial(前,"補填",後)` | 前後の指定文字数だけ残し、中間を補填文字列に置換 | `partial(1,"***",0)` → `佐***` |
| `random(下限, 下限)` | 指定範囲の乱数(**数値型専用**。実行のたびに値が変わる) | `418273` |

### 挙動の確認

```sql
CREATE USER sec_masked WITHOUT LOGIN;
GRANT SELECT ON dbo.EmployeesMasked TO sec_masked;

EXECUTE AS USER = N'sec_masked';
    SELECT EmployeeId, LastName, Email, Salary FROM dbo.EmployeesMasked;   -- マスクされて見える
REVERT;

-- UNMASK を与えると平文が見える(2016〜2019 はデータベース単位の権限)
GRANT UNMASK TO sec_masked;

EXECUTE AS USER = N'sec_masked';
    SELECT EmployeeId, LastName, Email, Salary FROM dbo.EmployeesMasked;   -- 平文
REVERT;

REVOKE UNMASK FROM sec_masked;

-- マスクが付いている列の一覧
SELECT OBJECT_NAME(mc.object_id) AS テーブル, mc.name AS 列, mc.masking_function AS マスク関数
FROM   sys.masked_columns AS mc;
```

- **SQL Server 2022 以降**は `GRANT UNMASK ON dbo.EmployeesMasked(Email) TO ...` のように
  **列・テーブル・スキーマ単位の粒度**で `UNMASK` を与えられます。
  2016〜2019 では **データベース全体で ON/OFF** しかできない点に注意してください。
- マスクの解除は `ALTER TABLE ... ALTER COLUMN 列 DROP MASKED;` です。

### 限界 — DDM は本質的な防御ではない

**これは必ず理解してください。DDM は「表示上の目隠し」であって、アクセス制御ではありません。**

```sql
EXECUTE AS USER = N'sec_masked';       -- UNMASK 権限なし
    -- 値は見えないのに、条件には使える → 二分探索で特定できてしまう
    SELECT COUNT(*) AS 高給者数 FROM dbo.EmployeesMasked WHERE Salary > 900000;   -- 1
    SELECT COUNT(*) AS 佐藤の数 FROM dbo.EmployeesMasked WHERE LastName = N'佐藤'; -- 1
    -- 並べ替えも効くので、順位から相対関係も分かる
    SELECT EmployeeId FROM dbo.EmployeesMasked ORDER BY Salary DESC;
REVERT;
```

- **`WHERE` / `ORDER BY` / `JOIN` はマスク**されません**。値を知らなくても特定できます。**
- `SELECT ... INTO` で別テーブルへコピーすると、`UNMASK` を持たないユーザーがコピーした場合は
  **マスク後の値が実データとして書き込まれます**(元に戻せません)。
- したがって DDM が有効なのは、**「権限はあるが、うっかり画面に出したくない」** 場面
  (コールセンターの画面、開発者の調査クエリ、スクリーンショット)に限られます。
- **秘匿が要件なら、DDM ではなく権限(列を見せない)・RLS・暗号化を使ってください。**

> ⚠️ 「DDM を掛けたから個人情報対策は済んだ」は **誤り**です。
> DDM は多層防御の一枚目であり、単独の対策として数えてはいけません。

## 9. Always Encrypted — サーバーに平文を見せない

**Always Encrypted**(2016 以降)は、これまでの機能とは思想が根本的に違います。

> **暗号化と復号は「クライアント側のドライバ」が行う。**
> SQL Server は暗号化されたバイト列しか受け取らず、**平文を一度も見ない**。

つまり、守る相手は **DBA・クラウド事業者・サーバーを掌握した攻撃者** です。
権限機能(4〜8節)がまったく歯が立たなかった「高権限者」に対する唯一の答えがこれです。

### 鍵の二段構え

| 鍵 | 置き場所 | 役割 |
|---|---|---|
| **列マスターキー (CMK)** | **SQL Server の外**(Windows 証明書ストア、Azure Key Vault、HSM) | CEK を暗号化する鍵 |
| **列暗号化キー (CEK)** | データベース内(**CMK で暗号化された状態**で格納) | 実際に列データを暗号化する鍵 |

SQL Server が持っているのは「CMK の**場所を示すメタデータ**」と「暗号化済みの CEK」だけです。
CMK 本体を持たないため、**サーバー単独では絶対に復号できません**。

```sql
-- 概念のみ(この学習環境では実行しません。鍵ストアの準備が必要です)
-- CREATE COLUMN MASTER KEY CMK_Demo
--     WITH (KEY_STORE_PROVIDER_NAME = N'MSSQL_CERTIFICATE_STORE',
--           KEY_PATH = N'CurrentUser/My/<証明書のサムプリント>');
--
-- CREATE COLUMN ENCRYPTION KEY CEK_Demo
--     WITH VALUES (COLUMN_MASTER_KEY = CMK_Demo,
--                  ALGORITHM = 'RSA_OAEP',
--                  ENCRYPTED_VALUE = 0x016E...);
--
-- CREATE TABLE dbo.EmployeeSecure
-- (
--     EmployeeId INT PRIMARY KEY,
--     MyNumber   NVARCHAR(20) COLLATE Latin1_General_BIN2
--         ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = CEK_Demo,
--                         ENCRYPTION_TYPE = DETERMINISTIC,
--                         ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256')
-- );

-- 現在の状態は、カタログビューで確認できます(実行可能)
SELECT * FROM sys.column_master_keys;
SELECT * FROM sys.column_encryption_keys;

SELECT OBJECT_NAME(c.object_id) AS テーブル, c.name AS 列,
       c.encryption_type_desc   AS 暗号化方式,
       c.encryption_algorithm_name AS アルゴリズム
FROM   sys.columns AS c
WHERE  c.encryption_type IS NOT NULL;      -- 未設定なら 0 行
```

### 決定的 vs ランダム化 — 必ず出るトレードオフ

| | **決定的 (DETERMINISTIC)** | **ランダム化 (RANDOMIZED)** |
|---|---|---|
| 同じ平文 → 同じ暗号文 | **なる** | ならない(毎回異なる) |
| 等値検索 `=` / `IN` | **できる** | **できない** |
| 等値結合・`GROUP BY`・`DISTINCT` | できる | できない |
| インデックスのシーク | できる | できない |
| 範囲検索 `>` `<` / `LIKE` | **できない** | できない |
| 安全性 | **低い**(頻度分析でパターンを推測されうる) | **高い** |

**決定的暗号化の危険性**を具体的に言うと、性別や都道府県のような **値の種類が少ない列** では、
暗号文の出現頻度から「一番多いこの暗号文は『東京』だろう」と推測できてしまいます。
**カーディナリティの低い列に決定的暗号化を使ってはいけません。**

選び方の指針:

- **検索キーにする列** → 決定的(かつカーディナリティが高いこと。例: マイナンバー、口座番号)
- **表示するだけの列** → ランダム化(例: 備考、住所)
- 決定的にする文字列列は **`_BIN2` 照合順序が必須**です(比較がバイト単位になるため)。

### T-SQL だけでは完結しない

**ここがこの機能の最重要ポイントです。**

- 暗号化・復号は **クライアントドライバ**が行います。接続文字列に
  `Column Encryption Setting = Enabled` を指定し、CMK にアクセスできる必要があります。
  (.NET / JDBC / ODBC / Python など、対応ドライバが必要)
- SSMS でも、接続オプションで Always Encrypted を有効にしないと **暗号文しか見えません**。
- 暗号化列への `INSERT` / 検索では、**パラメータ化された SQL が必須**です。
  リテラルを直接書いた文はドライバが暗号化できず、エラーになります。
  ([20章](20_dynamic_sql.md) のパラメータ化が、ここでも必須要件として効いてきます)
- そのほかの主な制約:
  - 暗号化列に対する **算術演算・関数・`LIKE`・範囲比較はサーバー側でできない**
  - 計算列・既定値・トリガー・全文検索などで大きな制限がある
  - `SELECT` の結果を DB 内で加工する処理(集計・ソート)は基本的に不可

**この章では「概念と制約の理解」までにとどめます。** 実際に導入するときは、
アプリケーション側の改修範囲を先に見積もることが成否を分けます。

### セキュア エンクレーブ(SQL Server 2019 以降)

「ランダム化だと何も検索できない」という最大の弱点を緩和する仕組みが
**Always Encrypted with secure enclaves** です。

- サーバー内に、**OS からも DBA からも中身を覗けない保護領域(エンクレーブ)** を用意し、
  クライアントから安全に鍵を渡して、その中でだけ平文を扱います。
- **SQL Server 2019** で、ランダム化暗号化列に対する **範囲比較・`LIKE`** と、
  列の**インプレース暗号化**(データを持ち出さずに暗号化方式を変更)が可能になりました。
- **SQL Server 2022** では、エンクレーブ対応列に対する **`JOIN` / `GROUP BY` / `ORDER BY`** に拡大されました。
- 代償として、VBS(仮想化ベースのセキュリティ)対応のハードウェア構成と、
  エンクレーブの正当性を検証する **構成証明(attestation)** の準備が必要です。

## 10. TDE と監査 — 保存データと「記録」

### 透過的データ暗号化 (TDE)

**TDE(Transparent Data Encryption)** は、**データファイル・ログファイル・バックアップを
ディスク上で暗号化**する機能です。「透過的」の名のとおり、アプリからは何も変わって見えません。

```sql
-- 概念のみ(サーバー全体に影響するため、この学習環境では実行しません)
-- USE master;
-- CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'…';
-- CREATE CERTIFICATE TDECert WITH SUBJECT = N'TDE Certificate';
-- -- ★ 証明書のバックアップを取らないと、復元不能になります(最重要)
-- BACKUP CERTIFICATE TDECert TO FILE = N'…' WITH PRIVATE KEY (FILE = N'…', ENCRYPTION BY PASSWORD = N'…');
--
-- USE SalesLearning;
-- CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE TDECert;
-- ALTER DATABASE SalesLearning SET ENCRYPTION ON;

-- 暗号化状態の確認(実行可能)
SELECT DB_NAME(database_id) AS データベース, encryption_state_desc, percent_complete
FROM   sys.dm_database_encryption_keys;
```

- **SQL Server 2019 以降は Standard Edition でも利用可能**になりました(それ以前は Enterprise のみ)。
- CPU オーバーヘッドは一般に数%程度ですが、**環境により前後します**。必ず自環境で計測してください。
- **証明書のバックアップは必須**です。これを失うと **暗号化されたバックアップを二度と復元できません**。

### TDE と Always Encrypted の違い(脅威モデルの対比)

同じ「暗号化」でも守る相手がまったく違います。**ここが試験にも実務にも出る勘所です。**

| | **TDE** | **Always Encrypted** |
|---|---|---|
| 暗号化される場所 | **ディスク上のファイル**(データ/ログ/バックアップ) | **列の値そのもの**(クライアントで暗号化) |
| 守る相手 | **物理媒体を持ち出した人**(盗まれたバックアップ、退役ディスク) | **DBA・クラウド運用者・サーバー侵入者** |
| メモリ上 / クエリ結果 | **平文**(SQL Server は普通に読める) | **暗号文**(サーバーは最後まで平文を見ない) |
| `SELECT` した結果 | 平文が返る | 復号できるクライアントでのみ平文になる |
| アプリ改修 | **不要**(完全に透過的) | **必要**(ドライバ設定・パラメータ化・機能制限) |
| 検索・集計 | 制限なし | **大きな制限あり**(9節) |

覚え方は「**TDE はディスクを守る。Always Encrypted は DBA から守る。**」です。
**両者は排他ではなく、併用します。** そして、どちらも「権限のある利用者が
自分の権限で見る」ことは止められません。それは RLS と権限設計の仕事です。

### SQL Server Audit

「誰が・いつ・何に・どうアクセスしたか」を **改ざんされにくい形で記録**する仕組みです。
構成は 2 階建てです。

1. **サーバー監査 (`CREATE SERVER AUDIT`)** … 出力先(ファイル / Windows イベントログ)を決める
2. **監査仕様** … 何を記録するかを決める
   - **サーバー監査仕様 (`CREATE SERVER AUDIT SPECIFICATION`)** … ログイン失敗、権限変更など
   - **データベース監査仕様 (`CREATE DATABASE AUDIT SPECIFICATION`)** … 特定テーブルの `SELECT` など

```sql
-- 概念のみ(サーバー監査の作成には CONTROL SERVER 権限が必要。
--            共有環境では実行せず、専用の検証環境でのみ試してください)
-- USE master;
-- CREATE SERVER AUDIT Audit_SalesLearning
--     TO FILE (FILEPATH = N'C:\SQLAudit\', MAXSIZE = 100 MB)
--     WITH (ON_FAILURE = CONTINUE);
-- ALTER SERVER AUDIT Audit_SalesLearning WITH (STATE = ON);
--
-- USE SalesLearning;
-- CREATE DATABASE AUDIT SPECIFICATION AuditSpec_Employees
--     FOR SERVER AUDIT Audit_SalesLearning
--     ADD (SELECT, UPDATE ON dbo.Employees BY public)
--     WITH (STATE = ON);
--
-- -- 読み取り
-- SELECT event_time, server_principal_name, database_principal_name, statement
-- FROM   sys.fn_get_audit_file(N'C:\SQLAudit\*.sqlaudit', DEFAULT, DEFAULT);
--
-- -- 後片付け(STATE = OFF にしてから DROP する)
-- ALTER DATABASE AUDIT SPECIFICATION AuditSpec_Employees WITH (STATE = OFF);
-- DROP DATABASE AUDIT SPECIFICATION AuditSpec_Employees;
-- ALTER SERVER AUDIT Audit_SalesLearning WITH (STATE = OFF);
-- DROP SERVER AUDIT Audit_SalesLearning;

-- 現在の監査の状態は読み取り専用で確認できます
SELECT name, status_desc, audit_file_path FROM sys.dm_server_audit_status;
SELECT name, is_state_enabled FROM sys.server_audits;
```

- `BY public` と書くと「全ユーザー」が対象です。特定ロールだけに絞ることもできます。
- `ON_FAILURE = CONTINUE` は「監査に書けなくても処理を続ける」。
  規制要件が厳しい場合は `SHUTDOWN` や `FAIL_OPERATION` を選びます(**運用影響が大きい**ので慎重に)。
- **`ORIGINAL_LOGIN()` に相当する情報が記録される**ため、`EXECUTE AS` で切り替えても
  「本当に操作した人」を追跡できます。

### 拡張イベント([25章](25_extended_events.md))との関係

SQL Server Audit は **内部的に拡張イベント (Extended Events) の上に実装**されています。
では使い分けはどうするか。

| | **SQL Server Audit** | **拡張イベント (XE)** |
|---|---|---|
| 目的 | **コンプライアンス・証跡** | **トラブルシューティング・性能調査** |
| 出力の性質 | 改ざん耐性を意識した専用ファイル形式 | 自由度の高いターゲット(ファイル/リングバッファ等) |
| 設定の粒度 | 監査アクショングループという定型 | イベント/アクション/述語を細かく指定 |
| 運用 | 常時稼働させる前提 | **必要なときに仕掛けて外す** |
| 対象 | 「誰が何をしたか」 | 「なぜ遅いか」「何が起きているか」 |

**「証拠として残す」なら Audit、「原因を突き止める」なら XE。** 目的が違うので、
XE で監査を代用しないでください(オーバーヘッドと保全性の両面で不適切です)。

## 11. SQLインジェクションと多層防御

**SQLインジェクションの対策そのものは [20章 動的SQL](20_dynamic_sql.md) で扱いました。**
ここでは繰り返しません。復習が必要なら 20 章 4〜5 節に戻ってください。要点だけ再掲します。

- 対策は **パラメータ化(`sys.sp_executesql`)ただ一つ**。入力のフィルタリングは対策にならない。
- 識別子は連結せざるを得ないので **`QUOTENAME()` + ホワイトリスト検証**。

### この章で足すべき視点: DB 側でも守る

アプリの入力検証は **必ずいつか破られます**。新機能の実装漏れ、ライブラリの脆弱性、
別チームが書いた管理画面 —— 穴の入り口は無数にあります。
だからこそ **「破られた後にどこまで被害が広がるか」を DB 側で決めておく**のが多層防御です。

| 層 | 対策 | 破られたときに残る防御 |
|---|---|---|
| アプリ | 入力検証、ORM、パラメータ化 | ← ここが破られる前提で以下を積む |
| **接続ユーザーの権限** | `db_owner` を与えない。必要なオブジェクトだけ `GRANT` | **テーブル削除・他テーブル参照ができない** |
| **アクセス経路** | テーブル直参照を禁止し、ビュー/プロシージャだけに `EXECUTE` | **想定外のクエリが書けない** |
| **RLS** | 行単位のフィルタをサーバー側で強制 | **アプリの `WHERE` を迂回しても他人の行は返らない** |
| **Always Encrypted** | 機微列はサーバーに平文を置かない | **抜かれても暗号文** |
| **監査** | Audit で証跡を残す | **被害範囲を後から特定できる** |

具体的に効く設計判断を挙げます。

- **アプリの接続ユーザーに `db_owner` / `sysadmin` を与えない。**
  これだけで `DROP TABLE` も他 DB へのアクセスも成立しなくなります。
- **プロシージャに `EXECUTE` 権限だけを与え、テーブル権限は与えない**(5節)。
  攻撃者は `UNION SELECT` で他テーブルを覗けません。
- **`EXECUTE AS OWNER` を付けたモジュールは特に厳重に。** 昇格された権限で
  インジェクションが成立すると、最小権限の努力が一瞬で無効になります(6節)。
- **エラーメッセージをそのまま画面に返さない。** テーブル名・列名・行数は攻撃者への情報提供です。
- 読み取り専用の分析ユーザーには、**RLS + ビュー限定の権限**を組み合わせる(7節の限界を踏まえて)。

## 12. 後片付けチェックリスト

セキュリティ機能を試したあとは、**依存関係の順序どおり**に片付けます。
順序を間違えると `DROP` が失敗します。

```sql
-- ① セキュリティポリシー(先に消さないと述語関数を消せない)
DROP SECURITY POLICY IF EXISTS sec.CustomerAccessPolicy;

-- ② 述語関数
DROP FUNCTION IF EXISTS sec.fn_CustomerAccess;

-- ③ マスクの解除(テーブルごと消すなら不要だが、業務表に付けた場合は必須)
-- ALTER TABLE dbo.EmployeesMasked ALTER COLUMN Email    DROP MASKED;
-- ALTER TABLE dbo.EmployeesMasked ALTER COLUMN Salary   DROP MASKED;
-- ALTER TABLE dbo.EmployeesMasked ALTER COLUMN LastName DROP MASKED;

-- ④ 検証用テーブル
DROP TABLE IF EXISTS dbo.CustomersRls;
DROP TABLE IF EXISTS dbo.EmployeesMasked;
DROP TABLE IF EXISTS dbo.SalesRepUserMap;

-- ⑤ ビュー・プロシージャ
DROP VIEW      IF EXISTS dbo.vw_CustomerSalesSummary;
DROP PROCEDURE IF EXISTS dbo.usp_SecDynamicCount;

-- ⑥ ロールはメンバーを外してから削除
-- ALTER ROLE SalesReaders DROP MEMBER sec_rep_suzuki;
DROP ROLE IF EXISTS SalesReaders;
DROP ROLE IF EXISTS SalesManagers;

-- ⑦ ユーザー(なりすまし中は消せないので、必ず REVERT 済みであること)
DROP USER IF EXISTS sec_rep_suzuki;
DROP USER IF EXISTS sec_rep_takahashi;
DROP USER IF EXISTS sec_masked;

-- ⑧ 空になったスキーマ
DROP SCHEMA IF EXISTS sec;
```

**残っていないことの検証まで行うのが、セキュリティを扱う人の作法です。**

```sql
SELECT name FROM sys.database_principals
WHERE  name LIKE N'sec[_]%' OR name IN (N'SalesReaders', N'SalesManagers');   -- 0 行
SELECT name FROM sys.security_policies;                                       -- 0 行
SELECT OBJECT_NAME(object_id) AS テーブル, name AS 列 FROM sys.masked_columns; -- 0 行
SELECT name FROM sys.schemas WHERE name = N'sec';                             -- 0 行
```

> ⚠️ `DROP USER` が「データベース プリンシパルはスキーマを所有しています」で失敗したら、
> そのユーザーが所有するスキーマの所有者を先に付け替えます
> (`ALTER AUTHORIZATION ON SCHEMA::sec TO dbo;`)。

## よくあるつまずき

- **`REVERT` を忘れて以降のクエリが全部エラー** → `SELECT USER_NAME();` で現在地を確認。
  なりすまし中は `DROP USER` もできない。
- **`REVOKE` すれば拒否になると思っている** → `REVOKE` は中立化。
  他のロール経由の許可が残っていればアクセスできる。拒否したいなら `DENY`。
- **`GRANT` したのに `DENY` が消えない** → 同じ権限に `DENY` があると常にそちらが勝つ。
  先に `REVOKE` で拒否を外す。
- **管理者が RLS で自分のデータを見られなくなる** → 述語関数に `dbo` / 管理ロールの
  例外条件を入れ忘れている。ポリシーは `ALTER SECURITY POLICY ... WITH (STATE = OFF)` で一時停止できる。
- **RLS を付けたら急に遅くなった** → 述語関数が SARGable でない、または内部で結合している。
  `SET STATISTICS IO` と実行プランで確認する。
- **RLS で行は隠したのに他人の行を作られた** → FILTER PREDICATE だけでは `INSERT` を止められない。
  **`BLOCK PREDICATE ... AFTER INSERT`** を追加する。
- **DDM を掛けたのに値を特定された** → DDM は表示上のマスク。`WHERE` / `ORDER BY` は素通し。
  秘匿要件には使わない。
- **`SELECT INTO` したらマスク後の値が保存された** → `UNMASK` の無いユーザーがコピーすると
  マスク値が実データになる。元には戻せない。
- **Always Encrypted 列が SSMS で暗号文のまま** → 接続時に Always Encrypted を有効にしていない。
  そもそも T-SQL だけでは復号できない。
- **Always Encrypted 列で `LIKE` や範囲検索がエラー** → 仕様。決定的でも等値のみ。
  範囲が必要ならセキュア エンクレーブ(2019+)。
- **決定的暗号化にしたら値を推測された** → カーディナリティの低い列に決定的は使わない。
- **`DROP FUNCTION` が「スキーマ バインドされています」で失敗** → 先に
  `DROP SECURITY POLICY` を実行する(依存関係の順序)。

## この章のまとめ

- セキュリティ機能は **脅威モデル(誰から何を守るか)から選ぶ**。
  RLS は他の利用者から、DDM は目視から、TDE は媒体の盗難から、
  Always Encrypted は **DBA を含む高権限者**から守る。目的が違うので代用にならない。
- **ログイン(サーバー)とユーザー(データベース)は別物**。
  権限は **個人ではなくロール** に、テーブル直参照ではなく
  **ビュー/プロシージャ経由**で与える(所有権の連鎖)。
- **`DENY` が最優先**。`REVOKE` は「拒否」ではなく「中立化」。
  ただし `sysadmin` と所有者には `DENY` が効かない。
- **動的SQLでは所有権の連鎖が切れる**。`WITH EXECUTE AS OWNER` は解決策だが
  **権限昇格装置**でもあるため、パラメータ化を厳守する。本命はモジュール署名。
- **RLS**(2016+)は 述語関数(インライン TVF・`SCHEMABINDING` 必須)+ セキュリティポリシー。
  **FILTER は見せない / BLOCK は書かせない**。FILTER だけでは他人の行を作られる。
  述語は全クエリに付くので **SARGable に書き、必ず計測**する。
  巧妙なクエリによる **サイドチャネル漏洩の可能性**という限界も理解しておく。
- **DDM**(2016+)は **表示上のマスクにすぎない**。`WHERE` / `ORDER BY` で値を推測できる。
  秘匿要件には使わない。列単位の `UNMASK` は 2022 以降。
- **Always Encrypted**(2016+)は **クライアント側で暗号化**するため SQL Server が平文を見ない。
  CMK / CEK の二段構え。**決定的=検索可だがパターン推測リスク / ランダム化=安全だが検索不可**。
  **T-SQL だけでは完結せず、ドライバ設定とアプリ改修が必要**。
  セキュア エンクレーブ(2019+、2022 で拡張)で範囲検索などが可能になる。
- **TDE は「ディスクを守る」、Always Encrypted は「DBA から守る」**。併用するもの。
  TDE の **証明書バックアップは必須**。
- **SQL Server Audit** は証跡、**拡張イベント**([25章](25_extended_events.md))は原因調査。
  内部実装は同じでも目的が違う。
- **SQLインジェクション対策は [20章](20_dynamic_sql.md)** のパラメータ化。
  加えて DB 側でも **最小権限・経路の限定・RLS・監査** を積む **多層防御**にする。
- 検証に使ったユーザー・ロール・ポリシー・関数・マスクは、
  **依存関係の順序どおりに片付け、残っていないことを検証する**。

---

## おわりに — ここから先へ

これで **00〜36 の全トピック** が終わりです。基礎の `SELECT` から始まり、
実行プラン・待機統計・Query Store・列ストア・インメモリ OLTP・物理設計、
そしてセキュリティまで一巡しました。

ただし、**ここまでは「地図」です。** 実際の力は次の2つでしか伸びません。

1. **公式ドキュメント(Microsoft Learn)を一次情報として引く習慣。**
   この教材で出てきた DMV 名・オプション名・機能名は、そのまま検索キーワードになります。
   バージョンによる差異は必ず一次情報で確認してください。
2. **自分の環境で測る習慣。** 「速いはず」「効くはず」は、`SET STATISTICS IO/TIME`、
   実行プラン、待機統計、Query Store の前ではすべて仮説にすぎません。
   **推測せず計測する** —— 第3弾で繰り返してきたこの一点が、最後まで効き続けます。

➡ 演習: [exercises/36_security.md](../exercises/36_security.md)

⬅ 前のトピック: [35 データモデリングと物理設計](35_data_modeling.md)

🏠 [README](../README.md) / 🗺 [ROADMAP](../ROADMAP.md) に戻る
