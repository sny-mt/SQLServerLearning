# 32 インメモリOLTP

> **このトピックのゴール**: インメモリOLTP(コードネーム **Hekaton**)が
> 「テーブルをメモリに置く機能」**ではない**ことを理解する。
> その本質は **ロックもラッチも取らない楽観的マルチバージョン同時実行制御(MVCC)** であり、
> [19章](19_transactions_isolation.md) で散々苦しんだ **ブロッキングそのものを消す**技術である、
> という一点を腹に落とす。
> そのうえで、メモリ最適化テーブル / ハッシュインデックス / ネイティブコンパイル プロシージャ /
> メモリ最適化テーブル変数を **実際に作って計測** し、
> **更新競合とリトライ**という設計上の代償と、**採用してよいワークロード / いけないワークロード** を
> 自分で判断できるようになる。
>
> **前提**: [31 パーティショニング](31_partitioning.md) までを済ませていること。
> とくに [19 トランザクションと分離レベル](19_transactions_isolation.md) の
> ロック・ブロッキング・SNAPSHOT の内容と、
> [15 一時テーブルとテーブル変数](15_temp_tables.md) のテーブル変数の性質は
> 本章の前提知識としてそのまま使います。

---

## ⚠️ 【最重要】この章だけは `SalesLearning` を使いません

インメモリOLTP を使うには、データベースに
**`MEMORY_OPTIMIZED_DATA` ファイルグループ**を追加する必要があります。そして —

> ⚠️ **メモリ最適化ファイルグループは、一度追加すると二度と削除できません。**
> `ALTER DATABASE ... REMOVE FILEGROUP` はエラーになります。
> テーブルを全部消しても、コンテナのファイルを消しても、**ファイルグループは残り続けます**。
> 元に戻す唯一の方法は **データベースごと捨てる**ことです。
>
> 副作用も残ります。
> - バックアップ / 復元の対象にコンテナが常に含まれる。
> - `DBCC CHECKDB` の挙動が変わる(メモリ最適化テーブルは検査対象外)。
> - `AUTO_CLOSE` が使えなくなる、`ALTER DATABASE ... SET ONLINE` の時間が伸びる、など。

そこで本章では、**専用の検証用データベース `SalesLearningIM` を新規に作り、
そこだけで実験し、最後に `DROP DATABASE` で丸ごと捨てます**。
`SalesLearning` 本体には **一切変更を加えません**。演習・解答もすべてこの方針で統一しています。

```sql
-- この章のすべての作業は SalesLearningIM の中で行う。
-- SalesLearning に対して ALTER DATABASE ... ADD FILEGROUP を実行してはいけない。
```

> ⚠️ **業務用のデータベースで気軽に試さないこと。**
> 「とりあえずメモリ最適化ファイルグループだけ足してみよう」は **取り返しがつきません**。
> 検証は必ず使い捨てのデータベースで行ってください。これは実務でも同じ原則です。

---

## 1. インメモリOLTP とは何か —「メモリに置くだけ」ではない

### 1-1. 19章の世界の限界

[19章](19_transactions_isolation.md) で見たとおり、通常の(ディスクベースの)テーブルでは
SQL Server は **ロック**と**ラッチ**という2種類の待ち合わせ機構を使っています。

| 機構 | 守っているもの | 保持期間 | 典型的な待機 |
|---|---|---|---|
| **ロック**(Lock) | **論理的な**データの一貫性(行・キー範囲・テーブル) | **トランザクションの間** | `LCK_M_X` / `LCK_M_S` = ブロッキング |
| **ラッチ**(Latch) | **物理的な**メモリ構造(バッファ上の 8KB ページ)の整合性 | **ごく短時間**(数マイクロ秒) | `PAGELATCH_EX` / `PAGELATCH_SH` |

ワークロードの同時実行数を上げていくと、どこかで必ずこの2つが壁になります。

- **ロック競合** — 同じ行を奪い合ってブロッキング。19章で見たとおり、
  待つ側は「ただ待つ」しかありません。
- **ラッチ競合** — 有名なのが **ラストページ挿入競合**です。
  `OrderId` のような単調増加のキーでクラスタ化インデックスを作ると、
  `INSERT` は **常に同じ最終ページ**に集中します。
  ロックは行単位で衝突していないのに、**ページのラッチ**を全員が奪い合い、
  `PAGELATCH_EX` の待機でスループットが頭打ちになります。
- **ログ書き込み** — `COMMIT` のたびにログを同期書き込みするため `WRITELOG` が積み上がります。

インデックスを直しても、分離レベルを下げても、この3つは消えません。
**アーキテクチャに起因する上限**だからです。

### 1-2. Hekaton の答え — 待たせる仕組みを丸ごと持たない

インメモリOLTP は「メモリに載せて速くする」機能ではありません。
**ロックとラッチを一切使わないデータ構造とトランザクション処理を、ゼロから作り直したもの**です。

| | ディスクベーステーブル | **メモリ最適化テーブル** |
|---|---|---|
| データの単位 | **8KB ページ** | **行そのもの**(ページという概念がない) |
| 行の場所 | バッファプール(必要なら再読み込み) | **常に全行がメモリ常駐** |
| 同時実行制御 | **ロック**(悲観的) | **行バージョン + 楽観的検証**(MVCC) |
| 構造の保護 | **ラッチ** | **ラッチフリー**(比較交換命令によるロックフリーアルゴリズム) |
| 読み手と書き手 | 互いにブロックしうる | **絶対にブロックしない** |
| 書き手同士 | 後から来たほうが**待つ** | 後から来たほうが**即座にエラー**(更新競合) |
| インデックス | ディスクに永続化され、ログにも書かれる | **メモリ上にのみ存在**。再起動時に再構築される |
| アクセス経路 | インタープリタ実行のクエリプロセッサ | 同上 + **ネイティブコンパイル(DLL)** |

キーになる考え方が3つあります。

1. **行は決して上書きされない(マルチバージョン)**
   `UPDATE` は「古い行の終了タイムスタンプを打ち、新しい行を追加する」操作です。
   古いバージョンは、それを見る必要があるトランザクションがいなくなるまで残ります。
   → **読み手は自分の時点のバージョンを読むだけなので、誰もロックを取らない**。
2. **競合は「起きてから」検出する(楽観的)**
   衝突しないように事前にロックで守るのではなく、**とりあえず走らせて、
   コミット時(または書き込み時)に矛盾がないか検証**します。
   矛盾していたら **そのトランザクションを失敗させる**。
   → **待ちは無くなるが、失敗は増える**。これが最大の設計上の代償です(第8節)。
3. **ラッチを使わないデータ構造**
   ハッシュインデックスと **Bw-tree**(ラッチフリーな B木の変種)は、
   ポインタの **アトミックな比較交換(CAS)** だけで更新されます。
   ページラッチという概念自体が存在しないので、`PAGELATCH` 競合は原理的に起きません。

> ⚠️ **「メモリに載せるだけ」なら、それはバッファプールが既にやっています。**
> 通常のテーブルでも、アクセスされたページはバッファプールに載ります。
> メモリが潤沢なら物理I/Oはほとんど発生していません。
> **にもかかわらず遅い**とき、その原因はロック・ラッチ・ログです。
> インメモリOLTP が解くのは **そこ**です。この理解が無いまま導入すると、まず失敗します。

### 1-3. バージョンの歴史(必ず押さえる)

| バージョン | 状況 |
|---|---|
| **2014** | 導入。**制限が厳しすぎて実用は困難**。`ALTER TABLE` 不可(作り直し)、外部キー不可、`CHECK` 不可、照合順序の制限、Enterprise のみ、推奨上限 256GB |
| **2016** | **実用レベルに到達**。`ALTER TABLE` / `ALTER PROCEDURE` 可、外部キー・`CHECK`・`UNIQUE` 制約可、LOB / 行外列可、並列プラン可、`SERIALIZABLE` の検証改善 |
| **2016 SP1** | **Standard / Web / Express でも利用可能に**(ただしエディションごとにメモリ上限あり。Standard は DB あたり 32GB) |
| **2017** | 計算列、`CASE`、`TOP` + `ORDER BY`、ネイティブモジュール内の構文がさらに拡充。`sp_spaceused` 対応 |
| **2019** | **tempdb メタデータのメモリ最適化**(`MEMORY_OPTIMIZED TEMPDB_METADATA`)。tempdb のシステムテーブル競合を解消する機能で、インメモリOLTP の技術が SQL Server 本体に転用された例(→ [33 SQL Serverアーキテクチャ](33_architecture.md)) |
| **2022** | 上記の安定化。基本機能は 2016〜2019 の枠組みのまま |

**本章は SQL Server 2016 以降**を前提に書きます。2014 の環境では動かない構文が多数あります。

```sql
-- まずバージョンとエディションを確認する
SELECT SERVERPROPERTY('ProductVersion')  AS バージョン,
       SERVERPROPERTY('ProductLevel')    AS レベル,
       SERVERPROPERTY('Edition')         AS エディション,
       SERVERPROPERTY('IsXTPSupported')  AS インメモリOLTP対応;   -- 1 なら使える
```

`IsXTPSupported` が `0` の場合、本章の実習は実行できません(読み物として進めてください)。

---

## 2. 検証用データベース `SalesLearningIM` を作る

### 2-1. データベースとメモリ最適化ファイルグループ

メモリ最適化テーブルには **`MEMORY_OPTIMIZED_DATA` ファイルグループ**と、
その中の **コンテナ(=ディレクトリ)** が必要です。

```sql
USE master;
GO

-- 前回の残骸があれば捨てる(この章専用のDBなので遠慮なく捨ててよい)
IF DB_ID(N'SalesLearningIM') IS NOT NULL
BEGIN
    ALTER DATABASE SalesLearningIM SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SalesLearningIM;
END
GO

CREATE DATABASE SalesLearningIM;
GO

-- ① メモリ最適化ファイルグループを追加する(1 DB につき 1 つだけ)
ALTER DATABASE SalesLearningIM
    ADD FILEGROUP IM_fg CONTAINS MEMORY_OPTIMIZED_DATA;
GO
```

② コンテナ(ファイル)の追加です。**`FILENAME` に指定するのはファイルではなく
「これから SQL Server が作るディレクトリのパス」** で、
**既に存在するディレクトリを指定するとエラー**になります。
環境ごとにパスが違うので、既定のデータパスから組み立てます
(動的SQLは → [20 動的SQL](20_dynamic_sql.md))。

```sql
DECLARE @コンテナ NVARCHAR(400) =
        CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(300)) + N'SalesLearningIM_mod';

SELECT @コンテナ AS これから作られるコンテナのパス;

DECLARE @sql NVARCHAR(MAX) =
    N'ALTER DATABASE SalesLearningIM ADD FILE (NAME = N''SalesLearningIM_mod'', FILENAME = N'''
    + @コンテナ + N''') TO FILEGROUP IM_fg;';

EXEC sys.sp_executesql @sql;
GO
```

確認します。

```sql
USE SalesLearningIM;
GO

SELECT fg.name                AS ファイルグループ,
       fg.type_desc           AS 種別,          -- MEMORY_OPTIMIZED_DATA_FILEGROUP
       df.name                AS 論理名,
       df.physical_name       AS コンテナのパス
FROM   sys.filegroups AS fg
LEFT   JOIN sys.database_files AS df ON df.data_space_id = fg.data_space_id
ORDER  BY fg.data_space_id;
```

> ⚠️ **コンテナはディスクを消費します。**
> `SCHEMA_AND_DATA` のテーブルは、耐久性のために **チェックポイントファイルペア**を
> このコンテナに書き出します。しかも「削除された行の分」もマージされるまで残るため、
> **実データの数倍のディスクを使うことがあります**。
> 学習用の小さなデータでも数百MB〜数GBの空きを見ておいてください。
> ファイルグループを複数のコンテナ(できれば別ドライブ)に分けると、
> 復旧時の並列読み込みが効きます。

### 2-2. 実験用の元データを持ち込む(クロスDB制約の実演)

`SalesLearning` から `SalesLearningIM` へデータを持ってきます。
ここで **インメモリOLTP の重要な制約**に最初にぶつかります。

> ⚠️ **メモリ最適化テーブルは、クロスデータベーストランザクションに参加できません。**
> `INSERT INTO 【メモリ最適化テーブル】 SELECT ... FROM SalesLearning.dbo.Orders`
> のように **他のデータベースを参照しながらメモリ最適化テーブルを触る**と、
> `メモリ最適化テーブルまたはネイティブ コンパイル モジュールへのアクセスは、
> 複数のデータベースにまたがるトランザクションではサポートされていません。`
> というエラーになります(`tempdb` と `master` の読み取りだけが例外)。

したがって **2段階**にします。① 他DBからディスクベースの作業表へ → ② 同一DB内でメモリ最適化テーブルへ。

```sql
-- ① 【ディスクベース】SalesLearning から作業表へコピー(ここはクロスDBでOK)
DROP TABLE IF EXISTS dbo.OrdersStage;

SELECT o.OrderId,
       o.CustomerId,
       o.EmployeeId,
       o.OrderDate,
       CAST(SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS DECIMAL(12, 0)) AS Amount
INTO   dbo.OrdersStage
FROM   SalesLearning.dbo.Orders       AS o
JOIN   SalesLearning.dbo.OrderDetails AS od ON od.OrderId = o.OrderId
GROUP  BY o.OrderId, o.CustomerId, o.EmployeeId, o.OrderDate;

-- 商品・顧客・社員のマスタもローカルに複製しておく(以降の結合で使う)
DROP TABLE IF EXISTS dbo.Customers;
SELECT * INTO dbo.Customers FROM SalesLearning.dbo.Customers;

DROP TABLE IF EXISTS dbo.Employees;
SELECT * INTO dbo.Employees FROM SalesLearning.dbo.Employees;

SELECT COUNT(*) AS 作業表の行数 FROM dbo.OrdersStage;   -- 20 行
```

20行では同時実行の実験になりません。**10万行**の合成データも用意します。

```sql
-- 【ディスクベース】10万行の合成注文を作る(タリーテーブルで連番を作る)
DROP TABLE IF EXISTS dbo.OrdersStageBig;

WITH N AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n)),
Tally AS (
    SELECT TOP (100000)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS 連番
    FROM   N AS a, N AS b, N AS c, N AS d, N AS e
)
SELECT CAST(連番 AS INT)                                        AS OrderId,
       CAST(連番 % 12 + 1 AS INT)                               AS CustomerId,
       CAST(連番 % 13 + 1 AS INT)                               AS EmployeeId,
       CAST(DATEADD(DAY, 連番 % 3650, '2015-01-01') AS DATE)     AS OrderDate,
       CAST(連番 % 90000 + 1000 AS DECIMAL(12, 0))              AS Amount
INTO   dbo.OrdersStageBig
FROM   Tally;

SELECT COUNT(*) AS 合成データ行数 FROM dbo.OrdersStageBig;   -- 100000
```

---

## 3. メモリ最適化テーブル

### 3-1. 基本形

```sql
DROP TABLE IF EXISTS dbo.OrderQueue;
GO

CREATE TABLE dbo.OrderQueue
(
    OrderId    INT            NOT NULL,
    CustomerId INT            NOT NULL,
    EmployeeId INT            NOT NULL,
    OrderDate  DATE           NOT NULL,
    Amount     DECIMAL(12, 0) NOT NULL,
    受付時刻    DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME(),

    -- ① 主キーは必ず「非クラスター化」。クラスタ化インデックスは存在しない
    CONSTRAINT PK_OrderQueue PRIMARY KEY NONCLUSTERED HASH (OrderId)
        WITH (BUCKET_COUNT = 262144),          -- ② ハッシュ索引はバケット数を自分で決める

    -- ③ 範囲検索用の非クラスター化インデックス(テーブル定義の中でしか作れない)
    INDEX IX_OrderQueue_OrderDate NONCLUSTERED (OrderDate)
)
WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);   -- ④ ここが本体
GO
```

押さえるべき点:

- **`MEMORY_OPTIMIZED = ON`** がメモリ最適化テーブルの宣言です。
- **クラスタ化インデックスは作れません**。メモリ最適化テーブルに「ページ」が無いため、
  「行をキー順に並べて格納する」という概念自体がありません。
  主キーは必ず **`PRIMARY KEY NONCLUSTERED`** です。
- **`SCHEMA_AND_DATA` の耐久テーブルには主キーが必須**です。
  `SCHEMA_ONLY` では省略できますが、実際には検索のために最低1つのインデックスが要ります。
- **インデックスは `CREATE TABLE` の中でしか定義できません**
  (`CREATE INDEX` は使えない。追加・削除は `ALTER TABLE ... ADD/DROP INDEX`)。
- SQL Server 2016 では **1テーブルあたりインデックス8個**まで、2017 以降は緩和されています。

作られたテーブルの属性を確認します。

```sql
SELECT t.name                       AS テーブル,
       t.is_memory_optimized        AS メモリ最適化,
       t.durability_desc            AS 耐久性,
       i.name                       AS インデックス,
       i.type_desc                  AS 索引種別      -- NONCLUSTERED HASH / NONCLUSTERED
FROM   sys.tables  AS t
LEFT   JOIN sys.indexes AS i ON i.object_id = t.object_id
WHERE  t.is_memory_optimized = 1
ORDER  BY t.name, i.index_id;
```

データを投入します(**同一DB内**なので問題ありません)。

```sql
INSERT INTO dbo.OrderQueue (OrderId, CustomerId, EmployeeId, OrderDate, Amount)
SELECT OrderId, CustomerId, EmployeeId, OrderDate, Amount
FROM   dbo.OrdersStageBig;

SELECT COUNT(*) AS 行数 FROM dbo.OrderQueue;   -- 100000
```

### 3-2. `SCHEMA_AND_DATA` と `SCHEMA_ONLY` の違い

`DURABILITY` は **2択**です。ここは必ず理解してください。

| | `SCHEMA_AND_DATA`(既定) | `SCHEMA_ONLY` |
|---|---|---|
| トランザクションログ | **書く** | **書かない** |
| チェックポイントファイル | **書く**(コンテナを消費) | **書かない** |
| SQL Server 再起動後 | データは **復旧される** | **テーブル定義だけ残り、データは空になる** |
| フェールオーバー後 | データは残る | **データは消える** |
| 速度 | 速い | **さらに速い**(ログI/Oがゼロ) |
| 用途 | 業務データ | **セッション状態 / ETLステージング / 一時的な集計** |

```sql
DROP TABLE IF EXISTS dbo.SessionState;
GO

-- セッション状態のような「消えても再作成できる」データに最適
CREATE TABLE dbo.SessionState
(
    SessionId  UNIQUEIDENTIFIER NOT NULL
        PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 65536),
    EmployeeId INT              NOT NULL,
    最終アクセス DATETIME2(3)     NOT NULL,
    状態JSON    NVARCHAR(MAX)    NULL
)
WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);
GO

INSERT INTO dbo.SessionState (SessionId, EmployeeId, 最終アクセス, 状態JSON)
SELECT NEWID(), EmployeeId, SYSDATETIME(), N'{"画面":"受注入力"}'
FROM   dbo.Employees;

SELECT COUNT(*) AS セッション数 FROM dbo.SessionState;

-- 耐久性の設定を確認
SELECT name, durability_desc FROM sys.tables WHERE is_memory_optimized = 1;
```

> ⚠️ **`SCHEMA_ONLY` は「速いテーブル」ではなく「消えるテーブル」です。**
> 再起動・フェールオーバー・`ALTER DATABASE ... SET OFFLINE` のいずれでもデータは失われます。
> **失われても業務が続けられるデータ**にしか使ってはいけません。
> 逆に言えば、そういうデータ(セッション、キャッシュ、ステージング)に対しては
> **ログI/Oを完全にゼロにできる**という、他に代えがたい価値があります。

> ⚠️ `SCHEMA_ONLY` テーブルは **バックアップにデータが含まれません**(定義だけ)。
> 「バックアップから戻したのに中身が空」は仕様どおりの挙動です。

---

## 4. インデックス — ハッシュか、範囲か

メモリ最適化テーブルのインデックスは **メモリ上にしか存在せず、ログにも書かれません**。
起動時にデータから **再構築**されます(だから起動が遅くなることがあります)。
種類は2つだけです。

### 4-1. ハッシュインデックス — 等値検索専用

```sql
    CONSTRAINT PK_OrderQueue PRIMARY KEY NONCLUSTERED HASH (OrderId)
        WITH (BUCKET_COUNT = 262144)
```

- キーの値をハッシュ関数にかけ、**バケット配列**の位置を求めます。
  同じバケットに入った行は **連結リスト(チェーン)** でつながります。
- **`WHERE OrderId = 12345` のような完全一致は O(1) で最速**。
- **範囲検索(`>`, `<`, `BETWEEN`)には一切使えません。**
  ハッシュ値には順序が無いためです。→ **テーブル全体のスキャンになります**。
- **複合キーの場合、すべての列を等値指定しないと使えません。**
  `HASH (A, B)` のインデックスは `WHERE A = 1 AND B = 2` にしか効きません。
  `WHERE A = 1` だけではスキャンになります(ディスクベースの複合インデックスとの
  決定的な違い。→ [18 インデックスと実行プラン](18_indexes_execution_plans.md))。
- **`ORDER BY` にも使えません**(順序が無いため)。

### 4-2. `BUCKET_COUNT` の決め方(最頻出の落とし穴)

**目安: 「そのキーの一意な値の個数」の 1〜2 倍**。
指定した値は内部で **2 のべき乗に切り上げ**られます(例: 100,000 → 131,072)。

| 状態 | 何が起きるか | 症状 |
|---|---|---|
| **少なすぎる** | 1つのバケットに多数の行がぶら下がる(**チェーンが伸びる**) | 等値検索が O(1) でなくなり、**線形探索**に劣化。挿入も遅くなる |
| **多すぎる** | 空バケットがメモリを食う(1バケット8バイト) | **メモリの無駄** + **フルスキャンが遅くなる**(空バケットも全部走査するため) |

**計測方法** — `sys.dm_db_xtp_hash_index_stats` を見ます。

```sql
SELECT OBJECT_NAME(h.object_id)                          AS テーブル,
       i.name                                            AS インデックス,
       h.total_bucket_count                              AS 総バケット数,
       h.empty_bucket_count                              AS 空バケット数,
       CAST(100.0 * h.empty_bucket_count
            / NULLIF(h.total_bucket_count, 0) AS DECIMAL(5, 1)) AS 空バケット率,
       h.avg_chain_length                                AS 平均チェーン長,
       h.max_chain_length                                AS 最大チェーン長
FROM   sys.dm_db_xtp_hash_index_stats AS h
JOIN   sys.indexes AS i
       ON i.object_id = h.object_id AND i.index_id = h.index_id
ORDER  BY テーブル, インデックス;
```

**判断基準(この数字がこうなったら何を疑うか)**

| 指標 | 健全な値 | 外れたときに疑うこと |
|---|---|---|
| **空バケット率** | **33% 以上** | 33% を下回る → **バケット数が足りない**。増やす |
| **平均チェーン長** | **1〜2** | 10 を超える → バケット不足、または **キーの重複が多い** |
| **最大チェーン長** | 平均に近い | 平均が小さいのに最大だけ大きい → **値の偏り**(特定の値に集中) |

> ⚠️ **平均チェーン長が長い原因は2つあり、対処が正反対です。**
> - **バケット不足** → `BUCKET_COUNT` を増やす。
> - **キーの重複が多い**(例: 顧客IDが12種類しかないのに10万行) → **バケットを増やしても無駄**。
>   同じ値は必ず同じバケットに入るからです。この場合は
>   **ハッシュではなく非クラスター化(範囲)インデックスを使う**のが正解です。
>
> 「一意な値が少ない列にハッシュインデックスを張る」は典型的な設計ミスです。

`BUCKET_COUNT` は後から変更できます(SQL Server 2016 以降)。ただし **テーブル全体の作り直し**です。

```sql
-- バケット数の変更 = インデックスの再構築(オフライン。行数ぶんの時間とメモリを食う)
ALTER TABLE dbo.OrderQueue
    ALTER INDEX PK_OrderQueue REBUILD WITH (BUCKET_COUNT = 131072);
```

### 4-3. 非クラスター化インデックス(範囲インデックス / Bw-tree)

```sql
    INDEX IX_OrderQueue_OrderDate NONCLUSTERED (OrderDate)
```

- 実体は **Bw-tree** という **ラッチフリーな B木**です。
- **範囲検索・不等号・`ORDER BY`・先頭列だけの検索**が使えます。
  ディスクベースの非クラスター化インデックスに近い感覚で使えます。
- **`BUCKET_COUNT` は不要**(自動で管理される)。
- **単方向**です。インデックスを `(OrderDate)` で作った場合、
  `ORDER BY OrderDate DESC` は **インデックスで解決できません**(逆順スキャンができない)。
  降順で取りたければ `INDEX IX_... NONCLUSTERED (OrderDate DESC)` と定義します。

### 4-4. どちらを選ぶか

| 条件 | 選ぶもの |
|---|---|
| 完全一致検索のみ + **一意な値が多い**(主キーなど) | **ハッシュ** |
| 範囲検索・`ORDER BY`・`BETWEEN` を使う | **非クラスター化(範囲)** |
| 先頭列だけで検索することがある | **非クラスター化(範囲)** |
| **一意な値が少ない**(区分・ステータス列など) | **非クラスター化(範囲)** |
| 迷ったら | **非クラスター化(範囲)**。ハッシュより汎用で、事故が少ない |

### 4-5. 実際に確かめる

```sql
SET STATISTICS TIME ON;

-- (A) ハッシュインデックスが効く: 完全一致
SELECT OrderId, CustomerId, Amount
FROM   dbo.OrderQueue
WHERE  OrderId = 54321;
-- → 実行プランは「Index Seek (NonClustered Hash)」

-- (B) ハッシュインデックスが効かない: 範囲検索
SELECT COUNT(*)
FROM   dbo.OrderQueue
WHERE  OrderId BETWEEN 50000 AND 50100;
-- → 実行プランは「Index Scan (NonClustered Hash)」= 10万行の全走査

-- (C) 範囲インデックスなら範囲検索が効く
SELECT COUNT(*)
FROM   dbo.OrderQueue
WHERE  OrderDate BETWEEN '2016-01-01' AND '2016-01-31';
-- → 実行プランは「Index Seek (NonClustered)」

SET STATISTICS TIME OFF;
```

> ⚠️ メモリ最適化テーブルでは **`SET STATISTICS IO` の論理読み取りが 0 と表示されます**。
> ページを読んでいないので当然です。18章までの主指標だった論理読み取りが使えないため、
> **本章の計測は CPU 時間・経過時間・実行プランの演算子(Seek か Scan か)** で行います。
> ここは判断のよりどころが変わる、重要な違いです。

---

## 5. なぜロックが要らないのか — 行バージョンの仕組み

メモリ最適化テーブルの各行は、**開始タイムスタンプ**と**終了タイムスタンプ**を持ちます。

```
時刻 →   10        20        30        40
行A     [========== v1 ==========)                 ← 開始10 / 終了30
行A                            [====== v2 ======   ← 開始30 / 終了∞
```

- **`INSERT`** … 新しい行を作り、開始タイムスタンプに自分のコミット時刻を書く。
- **`UPDATE`** … 元の行の **終了タイムスタンプ**を打ち、**新しいバージョンの行を追加**する
  (**元の行は書き換えない**)。
- **`DELETE`** … 終了タイムスタンプを打つだけ。
- **`SELECT`** … 自分のトランザクション開始時刻 `T` に対して
  **`開始 <= T < 終了`** を満たすバージョンだけを読む。

この結果:

- **読み手は、他のトランザクションが何をしていても、自分の時点の一貫したデータを見られます。**
  ロックを取る理由がありません。19章の `SNAPSHOT` と同じ考え方ですが、
  **バージョンを tempdb ではなくメモリ上の行そのものとして持つ**点が決定的に違います
  (→ `SNAPSHOT` の tempdb 負荷問題が発生しない)。
- **不要になった古いバージョンは、ガベージコレクション(GC)が回収します。**
  「これ以上古いバージョンを見るトランザクションはいない」と判断された時点で解放されます。

> ⚠️ **長時間開きっぱなしのトランザクションは、ここでも致命的です。**
> 古いトランザクションが1つ生き残っているだけで、**GC が進まず古いバージョンがメモリに滞留**します。
> 19章の「バージョンストアの肥大化」と同じ構図が、今度は **メモリ上で**起こります。
> メモリが尽きればエラー 41805 / 41823(メモリクォータ超過)になり、
> **書き込みが一切できなくなります**。「トランザクションは短く」は、ここでも鉄則です。

---

## 6. ネイティブコンパイル ストアドプロシージャ

### 6-1. 何が違うのか

通常の T-SQL は、実行のたびに **クエリプランを1演算子ずつ解釈(インタープリト)** しています。
1行の `INSERT` でも、この解釈のオーバーヘッドがそれなりに乗ります。

**ネイティブコンパイル ストアドプロシージャ**は、
作成時に **C言語のコードに変換され、コンパイルされて DLL になり**、
SQL Server のプロセスにロードされます。実行時は **機械語を直接呼ぶ**だけです。

- CPU 命令数がおおむね **数分の1〜数十分の1**に減ります。
- 効果が大きいのは **「短い処理を大量に繰り返す」ワークロード**(1件登録を毎秒数万回、など)。
- **1回で大量行を処理するバッチには、ほとんど効きません**(元々解釈コストの比率が小さいため)。

### 6-2. 書き方

```sql
DROP PROCEDURE IF EXISTS dbo.usp_受注登録;
GO

CREATE PROCEDURE dbo.usp_受注登録
(
    @OrderId    INT,
    @CustomerId INT,
    @EmployeeId INT,
    @Amount     DECIMAL(12, 0)
)
WITH NATIVE_COMPILATION,      -- ① ネイティブコンパイルする
     SCHEMABINDING,           -- ② 参照するオブジェクトを固定する(必須)
     EXECUTE AS OWNER         -- ③ 実行コンテキストを固定する
AS
BEGIN ATOMIC WITH             -- ④ 本体は必ず ATOMIC ブロック
(
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,   -- 必須
    LANGUAGE = N'Japanese'                    -- 必須
)
    INSERT INTO dbo.OrderQueue (OrderId, CustomerId, EmployeeId, OrderDate, Amount)
    VALUES (@OrderId, @CustomerId, @EmployeeId, CAST(SYSDATETIME() AS DATE), @Amount);
END;
GO

EXEC dbo.usp_受注登録 @OrderId = 900001, @CustomerId = 1, @EmployeeId = 2, @Amount = 50000;

SELECT * FROM dbo.OrderQueue WHERE OrderId = 900001;
```

各句の意味:

- **`NATIVE_COMPILATION`** … DLL にコンパイルする指定。
- **`SCHEMABINDING`** … 必須。参照テーブルを **DROP できなくなる**代わりに、
  コンパイル済みコードが指すオブジェクトが消えないことを保証します。
  **テーブル名は必ず `dbo.` 付きの2部名**で書く必要があります。
- **`EXECUTE AS OWNER`**(または `SELF` / `'ユーザー名'`)… 実行コンテキストの固定。
  SQL Server 2016 以降は `EXECUTE AS CALLER` も使えますが、
  従来どおり `OWNER` を明示するのが定番です。
- **`BEGIN ATOMIC WITH (...)`** … ネイティブモジュールの本体は必ずこの形です。
  - **必須オプション**: `TRANSACTION ISOLATION LEVEL` と `LANGUAGE`。
  - 任意: `DATEFIRST` / `DATEFORMAT` / `DELAYED_DURABILITY`。
  - **ATOMIC ブロックは「全部成功か、全部取り消しか」を保証**します。
    呼び出し元にトランザクションが無ければ **自分で開始**し、
    既にあれば **セーブポイントを作って参加**します。
    ブロック内でエラーが起きると、**ブロックが行った変更だけがロールバック**されます。

### 6-3. DLL になっていることを確認する

```sql
-- ロードされているネイティブモジュールの DLL 一覧
SELECT OBJECT_NAME(m.object_id)  AS モジュール,
       m.type_desc               AS 種別,
       l.name                    AS DLLのパス,
       l.description             AS 説明          -- XTP Native DLL
FROM   sys.dm_os_loaded_modules AS l
JOIN   sys.sql_modules          AS m
       ON l.name LIKE N'%\_' + CAST(m.object_id AS NVARCHAR(20)) + N'.dll' ESCAPE N'\'
WHERE  l.description = N'XTP Native DLL';

-- ネイティブコンパイルされたモジュールの一覧
SELECT o.name,
       o.type_desc,
       m.uses_native_compilation
FROM   sys.sql_modules AS m
JOIN   sys.objects     AS o ON o.object_id = m.object_id
WHERE  m.uses_native_compilation = 1;
```

`sys.dm_os_loaded_modules` に `xtp_p_<dbid>_<objectid>.dll` のようなファイルが並んでいれば、
**本当に DLL が生成されてプロセスにロードされている**ことが確認できます。

### 6-4. 【必読】使える T-SQL に厳しい制限がある

ネイティブコンパイル モジュールの中で使える構文は、**通常の T-SQL の一部でしかありません**。
ここを知らずに設計すると、実装の途中で行き詰まります。

**代表的に使えないもの**(SQL Server 2016〜2022 共通)

| 使えないもの | 代替 |
|---|---|
| **ディスクベーステーブルへのアクセス** | **最大の制約**。参照できるのは **メモリ最適化テーブルだけ** |
| **CTE(`WITH ...`)** | 派生テーブル / 分割した処理に書き換える |
| **カーソル** | `WHILE` ループ + キーによる順次取得 |
| **動的SQL**(`EXEC` / `sp_executesql`) | 使えない。通常のプロシージャから呼び分ける |
| **一時テーブル `#t`** | **メモリ最適化テーブル変数**(第7節) |
| **`SELECT ... INTO`** | 事前に定義したテーブルへ `INSERT ... SELECT` |
| **`MERGE`** | `UPDATE` + `INSERT` に分解する |
| **`PIVOT` / `UNPIVOT`** | `CASE` による手動ピボット(→ [10章](10_pivot_unpivot.md)) |
| **`CROSS APPLY` / `OUTER APPLY`** | 結合に書き換える |
| **DDL(`CREATE` / `ALTER` / `DROP`)** | 通常のプロシージャで実行する |
| **クロスデータベースクエリ** | 使えない |
| **多くの組み込み関数** | サポート対象はドキュメントで要確認 |

> ⚠️ **「ネイティブコンパイルにすれば速くなる」と考えて既存プロシージャを移植しようとすると、
> ほぼ確実に構文の壁にぶつかります。**
> ネイティブコンパイルは **最初からその制約の中で設計された、小さく単純な処理**にだけ使うものです。
> 「メモリ最適化テーブルを使う = ネイティブコンパイルが必須」ではありません。
> **通常の T-SQL(インタープリタ実行)からメモリ最適化テーブルを触ることは普通にできます**し、
> 効果の大半(ロックフリー・ラッチフリー)はそちらでも得られます。

制限に引っかかる例を実際に見ておきましょう。

```sql
-- ✗ ネイティブコンパイルでは CTE が使えない → 作成時にエラーになる
CREATE PROCEDURE dbo.usp_ダメな例
WITH NATIVE_COMPILATION, SCHEMABINDING, EXECUTE AS OWNER
AS
BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = SNAPSHOT, LANGUAGE = N'Japanese')
    WITH X AS (SELECT CustomerId, SUM(Amount) AS 合計 FROM dbo.OrderQueue GROUP BY CustomerId)
    SELECT * FROM X;
END;
GO
```

> ⚠️ **エラーは「実行時」ではなく「作成時」に出ます。**
> ネイティブコンパイルは `CREATE PROCEDURE` の瞬間に C コードへ変換してコンパイルするためです。
> これは長所でもあります(実行してみるまで分からない、ということがない)。

### 6-5. ネイティブコンパイル スカラーUDF(SQL Server 2016+)

プロシージャだけでなく、**スカラー関数**もネイティブコンパイルできます。

```sql
DROP FUNCTION IF EXISTS dbo.fn_税込金額;
GO

CREATE FUNCTION dbo.fn_税込金額 (@金額 DECIMAL(12, 0))
RETURNS DECIMAL(12, 0)
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = SNAPSHOT, LANGUAGE = N'Japanese')
    RETURN CAST(@金額 * 1.1 AS DECIMAL(12, 0));
END;
GO

SELECT TOP (5) OrderId, Amount, dbo.fn_税込金額(Amount) AS 税込
FROM   dbo.OrderQueue
ORDER  BY OrderId;
```

---

## 7. メモリ最適化テーブル変数 — tempdb 競合の現実的な回避策

### 7-1. なぜこれが実務で効くのか

[15章](15_temp_tables.md) で見たとおり、一時テーブル `#t` もテーブル変数 `@t` も
**実体は tempdb** にあります。同時実行数が高い環境では、これが問題になります。

- 大量のセッションが同時に一時オブジェクトを作ると、
  **tempdb のシステムテーブル(メタデータ)への競合**が起きます。
  待機タイプは `PAGELATCH_*`、待機リソースは `2:1:103` のようなシステムテーブルのページです。
- 割り当てページ(GAM / SGAM / PFS)への競合も起きます。
  → [33 SQL Serverアーキテクチャ](33_architecture.md)、[23 待機統計](23_wait_statistics.md)。

**メモリ最適化テーブル変数は tempdb を一切使いません。** ログにも書かれません。
そのため **tempdb 競合の回避策として、極めて現実的**です。

### 7-2. 作り方 — 必ず「型」を先に作る

インラインの `DECLARE @t TABLE (...) WITH (MEMORY_OPTIMIZED = ON)` という書き方は **できません**。
必ず **メモリ最適化テーブル型**を先に作ります。

```sql
DROP TYPE IF EXISTS dbo.受注明細型;
GO

CREATE TYPE dbo.受注明細型 AS TABLE
(
    OrderId    INT            NOT NULL,
    CustomerId INT            NOT NULL,
    Amount     DECIMAL(12, 0) NOT NULL,

    PRIMARY KEY NONCLUSTERED HASH (OrderId) WITH (BUCKET_COUNT = 1024)
)
WITH (MEMORY_OPTIMIZED = ON);     -- ← ここ。DURABILITY は指定しない(常に SCHEMA_ONLY 相当)
GO

-- 使い方は普通のテーブル変数とまったく同じ
DECLARE @明細 dbo.受注明細型;

INSERT INTO @明細 (OrderId, CustomerId, Amount)
SELECT TOP (1000) OrderId, CustomerId, Amount
FROM   dbo.OrderQueue
ORDER  BY OrderId;

SELECT c.CustomerName, COUNT(*) AS 件数, SUM(m.Amount) AS 合計
FROM   @明細 AS m
JOIN   dbo.Customers AS c ON c.CustomerId = m.CustomerId
GROUP  BY c.CustomerName
ORDER  BY 合計 DESC;
```

### 7-3. メモリ最適化 TVP(テーブル値パラメータ)

同じ型を **TVP** として使えば、アプリケーションから一括で行を渡す経路も tempdb を使いません
(TVP の基礎は → [17 ユーザー定義型とテーブル値パラメータ](17_user_defined_types.md))。

```sql
DROP PROCEDURE IF EXISTS dbo.usp_受注一括登録;
GO

CREATE PROCEDURE dbo.usp_受注一括登録
(
    @明細 dbo.受注明細型 READONLY      -- TVP は常に READONLY
)
WITH NATIVE_COMPILATION, SCHEMABINDING, EXECUTE AS OWNER
AS
BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = SNAPSHOT, LANGUAGE = N'Japanese')
    INSERT INTO dbo.OrderQueue (OrderId, CustomerId, EmployeeId, OrderDate, Amount)
    SELECT m.OrderId, m.CustomerId, 1, CAST(SYSDATETIME() AS DATE), m.Amount
    FROM   @明細 AS m;
END;
GO

DECLARE @入力 dbo.受注明細型;
INSERT INTO @入力 (OrderId, CustomerId, Amount)
VALUES (900101, 1, 12000), (900102, 3, 8000), (900103, 5, 30000);

EXEC dbo.usp_受注一括登録 @明細 = @入力;

SELECT * FROM dbo.OrderQueue WHERE OrderId BETWEEN 900101 AND 900103;
```

### 7-4. 実務での現実的な使いどころと注意点

| 使いどころ | 理由 |
|---|---|
| **高頻度で呼ばれるプロシージャの中間結果** | tempdb のメタデータ競合を回避できる |
| **TVP で大量行を受け取る API** | tempdb への書き込みとログが消える |
| **ネイティブコンパイル プロシージャ内の作業表** | そもそも `#t` が使えないので**唯一の選択肢** |

> ⚠️ **万能ではありません。次の点は通常のテーブル変数と同じか、むしろ厳しくなります。**
> - **統計情報を持ちません**(→ 大量行では見積もりが外れる。[15章](15_temp_tables.md) と同じ問題)。
>   ただし SQL Server 2019+ / 互換性レベル 150 の **テーブル変数の遅延コンパイル**は効きます。
> - **メモリを消費します**。tempdb ではなく **サーバーのメモリ**を使うので、
>   大量行を入れるとメモリ圧迫の原因になります。**数万行を超えるなら一時テーブルのほうが安全**です。
> - **`ROLLBACK` の影響を受けません**(通常のテーブル変数と同じ)。
> - メモリ最適化テーブル型を作るには、**そのデータベースにメモリ最適化ファイルグループが必要**です。
>   「テーブル変数のためだけに、業務DBに二度と消せないファイルグループを足す」判断になります。
>   **ここが実務での最大の意思決定ポイント**です。

---

## 8. 同時実行の挙動 — 待たない代わりに失敗する

ここが本章でもっとも重要な節です。

### 8-1. サポートされる分離レベル

メモリ最適化テーブルは **楽観的**なので、**19章のロックベースの分離レベルとは対応が違います**。

| 分離レベル | メモリ最適化テーブルで | 保証する内容 |
|---|---|---|
| `READ UNCOMMITTED` | **使えない**(エラー) | — |
| `READ COMMITTED` | **自動コミット(単文)のときだけ**使える | 明示的トランザクション内では不可 |
| **`SNAPSHOT`** | ✅ 使える(**実質の既定**) | トランザクション開始時点の一貫した姿を見る |
| **`REPEATABLE READ`** | ✅ 使える | 読んだ行が、コミット時点でも変わっていないことを**検証**する |
| **`SERIALIZABLE`** | ✅ 使える | 上記 + **ファントムが無かったこと**をコミット時点で**検証**する |

> ⚠️ **19章との決定的な違い**: ロックベースの `REPEATABLE READ` / `SERIALIZABLE` は
> **他のセッションを待たせて**異常を防ぎました。
> メモリ最適化テーブルの `REPEATABLE READ` / `SERIALIZABLE` は **誰も待たせません**。
> 代わりに **コミットの瞬間に「本当に一貫していたか」を検証し、
> 違反していたらトランザクションを失敗させます**。
> **防ぐ**のではなく **後から検出して殺す**。これが楽観的並行制御です。

### 8-2. 更新競合を実際に起こす

19章のブロッキングの実験と **同じ手順で、結果がまったく違う**ことを体感してください。

```sql
-- 【セッションA】手順1: 行を更新して、コミットせずに止める
USE SalesLearningIM;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
UPDATE dbo.OrderQueue SET Amount = 111111 WHERE OrderId = 50000;
-- ここで止める
```

```sql
-- 【セッションB】手順2: 同じ行を更新しようとする
USE SalesLearningIM;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
UPDATE dbo.OrderQueue SET Amount = 222222 WHERE OrderId = 50000;
```

19章のディスクベーステーブルなら、セッションBは **黙って待ち続けました**。
メモリ最適化テーブルでは **待たずに、即座にエラーになります**。

```
メッセージ 41302、レベル 16、状態 110
現在のトランザクションでは、このトランザクションの開始後に更新されたレコードを
更新しようとしました。トランザクションは中止されました。
```

```sql
-- 【セッションB】手順3: トランザクションは既に「doomed」なのでロールバックする
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT XACT_STATE() AS 状態, @@TRANCOUNT AS 深さ;
```

```sql
-- 【セッションA】手順4: 後片付け
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0
```

- **待たない** → スループットが落ちない、デッドロックが起きない。
- **失敗する** → **アプリケーションが必ず再試行しなければならない**。

### 8-3. 覚えておくべきエラー番号

| 番号 | 意味 | 起きる条件 |
|---|---|---|
| **41302** | **更新競合**(write-write conflict) | 自分が読んだ/更新しようとした行を、他のトランザクションが先に更新した |
| **41305** | **`REPEATABLE READ` の検証失敗** | 読んだ行がコミットまでに変更された |
| **41325** | **`SERIALIZABLE` の検証失敗** | 読んだ範囲に他のトランザクションが行を挿入した(ファントム) |
| **41301** | **コミット依存関係の失敗** | 依存していた他のトランザクションがコミットに失敗した |
| **41823 / 41805** | **メモリクォータ超過** | メモリ最適化データがリソースプールの上限に達した |
| **41332** | **分離レベルの組み合わせ違反** | ディスクテーブルを `SNAPSHOT` で開いたトランザクションからメモリ最適化テーブルに触った |

### 8-4. 【必須】リトライロジック

> ⚠️ **リトライを実装しないインメモリOLTP は、単に壊れやすいだけのシステムです。**
> デッドロック(1205)のリトライが「あったほうがよい」だったのに対し、
> **41302 系のリトライは「無ければ動かない」**と考えてください。

19章のデッドロックリトライと同じ形ですが、**捕まえるエラー番号が違います**。

```sql
DECLARE @試行 INT = 0, @最大試行 INT = 5;

WHILE @試行 < @最大試行
BEGIN
    BEGIN TRY
        SET @試行 = @試行 + 1;

        SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
        BEGIN TRAN;
            UPDATE dbo.OrderQueue
            SET    Amount = Amount + 1
            WHERE  OrderId = 50000;
        COMMIT;

        BREAK;                       -- 成功したら抜ける
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        -- インメモリOLTP の再試行可能なエラー
        IF ERROR_NUMBER() IN (41302, 41305, 41325, 41301) AND @試行 < @最大試行
        BEGIN
            -- ⚠ 実務では指数バックオフ(待ち時間を少しずつ延ばす)を入れる
            WAITFOR DELAY '00:00:00.010';
            CONTINUE;
        END
        ELSE
            THROW;
    END CATCH
END

SELECT @試行 AS 試行回数, Amount FROM dbo.OrderQueue WHERE OrderId = 50000;
```

実務での指針:

1. **リトライはアプリケーション層に置くのが原則**です。
   ネイティブコンパイル プロシージャの **ATOMIC ブロックの中にリトライは書けません**
   (ブロック全体がロールバックされるため)。
   ラッパーとなる **通常の T-SQL プロシージャ**か、アプリのコードに置きます。
2. **最大試行回数を必ず設ける**(無限リトライは障害を増幅させます)。
3. **指数バックオフ + ジッター**を入れる。全員が同時に再試行すると競合が再現します。
4. **リトライ回数を計測する**。回数が増えているなら、
   **設計上のホットスポット**(全員が同じ1行を更新している)を疑ってください。
   インメモリOLTP は「衝突の待ち時間」は消せますが、**衝突そのもの**は消せません。

### 8-5. ディスクテーブルとの混在(cross-container transaction)

1つのトランザクションで **ディスクベーステーブルとメモリ最適化テーブルの両方**を触ると、
**クロスコンテナトランザクション**になります。SQL Server の内部では
**2つのトランザクション(ディスク側 / メモリ側)が連携して**動いています。

```sql
-- ✗ 明示的トランザクション内で分離レベルを指定しないとエラーになる
BEGIN TRAN;
    SELECT COUNT(*) FROM dbo.OrdersStage;      -- ディスクベース(READ COMMITTED)
    SELECT COUNT(*) FROM dbo.OrderQueue;       -- メモリ最適化 → エラー 41368
ROLLBACK;
```

```
メッセージ 41368
メモリ最適化テーブルへの READ COMMITTED 分離レベルでのアクセスは、
自動コミット トランザクションでのみサポートされています。
```

**解決策は3つ**あります。

```sql
-- (A) テーブルヒントで、そのテーブルだけ分離レベルを指定する
BEGIN TRAN;
    SELECT COUNT(*) FROM dbo.OrdersStage;
    SELECT COUNT(*) FROM dbo.OrderQueue WITH (SNAPSHOT);   -- ← ヒント
ROLLBACK;
```

```sql
-- (B) データベースオプションで、既定を SNAPSHOT に昇格させる(実務ではこれが定番)
ALTER DATABASE SalesLearningIM SET MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT = ON;

SELECT name, is_memory_optimized_elevate_to_snapshot_on
FROM   sys.databases WHERE name = N'SalesLearningIM';

BEGIN TRAN;
    SELECT COUNT(*) FROM dbo.OrdersStage;
    SELECT COUNT(*) FROM dbo.OrderQueue;    -- ヒント無しで通る
ROLLBACK;
```

```sql
-- (C) セッションの分離レベルを SNAPSHOT / REPEATABLE READ / SERIALIZABLE にする
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
-- ただし「ディスクテーブルも SNAPSHOT」になる点に注意(次の ⚠ を参照)
```

**分離レベルの組み合わせ制約**(頻出のハマりどころ)

| ディスクテーブル側 | メモリ最適化テーブル側に指定できるもの |
|---|---|
| `READ COMMITTED`(既定) | `SNAPSHOT` / `REPEATABLE READ` / `SERIALIZABLE` |
| `REPEATABLE READ` / `SERIALIZABLE` | **`SNAPSHOT` のみ** |
| **`SNAPSHOT`** | **不可(エラー 41332)** |

> ⚠️ **「ディスクテーブルを `SNAPSHOT` で読むトランザクションからは、
> メモリ最適化テーブルに一切アクセスできません。」**
> 19章で RCSI / `SNAPSHOT` を有効にしている本番DBにメモリ最適化テーブルを足すと、
> ここで既存コードが壊れることがあります。**導入前に必ず確認すべき点**です。
> (`READ_COMMITTED_SNAPSHOT` は既定が `READ COMMITTED` 扱いなので影響しません。
>  問題になるのは明示的な `SET TRANSACTION ISOLATION LEVEL SNAPSHOT` です。)

---

## 9. メモリ使用量を計測する

「メモリに全部載せる」以上、**メモリ使用量の監視は運用の必須項目**です。

### 9-1. テーブル単位 — `sys.dm_db_xtp_table_memory_stats`

```sql
SELECT CASE WHEN ms.object_id > 0 THEN OBJECT_NAME(ms.object_id)
            ELSE N'(内部システムテーブル)' END               AS テーブル,
       ms.memory_allocated_for_table_kb   / 1024.0          AS テーブル確保MB,
       ms.memory_used_by_table_kb         / 1024.0          AS テーブル使用MB,
       ms.memory_allocated_for_indexes_kb / 1024.0          AS 索引確保MB,
       ms.memory_used_by_indexes_kb       / 1024.0          AS 索引使用MB,
       (ms.memory_allocated_for_table_kb
      + ms.memory_allocated_for_indexes_kb) / 1024.0        AS 合計確保MB
FROM   sys.dm_db_xtp_table_memory_stats AS ms
ORDER  BY 合計確保MB DESC;
```

**読み方 / 判断基準**

- **`object_id` が負の値**の行は、SQL Server が内部で使っているシステムテーブルです。
  ユーザーテーブルだけ見たいなら `WHERE ms.object_id > 0` を付けます。
- **確保(allocated)と使用(used)の差** = **まだ回収されていない古い行バージョン**
  や断片です。差が大きく開き続けるなら、**長時間トランザクションで GC が止まっている**
  ことを疑います(第5節)。
- **索引確保MB が異常に大きい** → **`BUCKET_COUNT` が過大**な可能性が高い。
  `sys.dm_db_xtp_hash_index_stats` の空バケット率を確認します(第4節)。

### 9-2. データベース全体 / インスタンス全体

```sql
-- データベース全体のメモリ消費者(内訳)
SELECT mc.memory_consumer_type_desc  AS 消費者種別,
       mc.memory_consumer_desc       AS 説明,
       SUM(mc.allocated_bytes)  / 1024.0 / 1024 AS 確保MB,
       SUM(mc.used_bytes)       / 1024.0 / 1024 AS 使用MB
FROM   sys.dm_db_xtp_memory_consumers AS mc
GROUP  BY mc.memory_consumer_type_desc, mc.memory_consumer_desc
ORDER  BY 確保MB DESC;

-- インスタンス全体で XTP エンジンが使っているメモリ
SELECT type                            AS メモリクラーク,
       pages_kb / 1024.0               AS MB
FROM   sys.dm_os_memory_clerks
WHERE  type LIKE N'%XTP%'
ORDER  BY MB DESC;

-- チェックポイントファイル(コンテナのディスク使用状況)
SELECT container_id,
       state_desc,
       file_type_desc,
       COUNT(*)                        AS ファイル数,
       SUM(file_size_in_bytes) / 1024.0 / 1024 AS 合計MB
FROM   sys.dm_db_xtp_checkpoint_files
GROUP  BY container_id, state_desc, file_type_desc
ORDER  BY 合計MB DESC;
```

### 9-3. メモリの上限を設ける(実務では必須)

既定では、メモリ最適化テーブルは **インスタンスのメモリを上限なく使おうとします**。
本番では **リソースプールにバインドして上限を設ける**のが定石です。

```sql
-- (参考) 上限 40% のプールを作り、DB をバインドする
-- CREATE RESOURCE POOL IM_pool WITH (MAX_MEMORY_PERCENT = 40);
-- ALTER RESOURCE GOVERNOR RECONFIGURE;
-- EXEC sys.sp_xtp_bind_db_resource_pool N'SalesLearningIM', N'IM_pool';
-- ※ バインドを有効にするには、DB を一度 OFFLINE → ONLINE にする必要がある
```

> ⚠️ この章の学習環境では **実行しないでください**(サーバー全体の設定になります)。
> 実施する場合は `sp_xtp_unbind_db_resource_pool` と `DROP RESOURCE POOL` で
> **必ず元に戻す手順**をセットで用意すること。

---

## 10. 制約と現実 —「銀の弾丸」ではない

### 10-1. 使えない機能

| 分類 | 制約 |
|---|---|
| **パーティショニング** | **できません**([31章](31_partitioning.md) の手法は使えない) |
| **`TRUNCATE TABLE`** | 使えない(`DELETE` で消す) |
| **`MERGE` のターゲット** | 使えない |
| **クロスDBトランザクション** | 使えない(第2節) |
| **`DBCC CHECKTABLE` / `CHECKDB`** | メモリ最適化テーブルは **検査対象外**(整合性検証の手段が変わる) |
| **レプリケーション** | パブリッシャ側にはできない(サブスクライバ側は可) |
| **`ALTER TABLE` の一部** | 可能だが **オフライン**かつ全行の作り直し |
| **`IDENTITY`** | `IDENTITY(1, 1)` のみ。シード/増分は変更不可 |
| **`FOREIGN KEY`** | **メモリ最適化テーブル同士**のみ(ディスクテーブルは参照できない) |
| **計算列** | SQL Server **2017 以降**のみ |
| **列ストア** | メモリ最適化テーブルにクラスター化列ストア索引を作れる(2016+)が、制約あり([30章](30_columnstore.md)) |

### 10-2. メモリ容量が上限になる

- **`SCHEMA_AND_DATA` のテーブルは、全行が常にメモリ上にあります。**
  「使われない古いデータはディスクに置いておく」ということが **できません**。
  10億行の履歴テーブルをメモリ最適化テーブルにすることは、現実的ではありません。
- **必要なメモリは実データサイズより大きい**のが普通です。
  行バージョン、インデックス、ハッシュのバケット配列がすべて上乗せされます。
  **目安として「テーブルサイズの2倍以上」**を確保してください。
- **エディションの上限**に注意。SQL Server 2016 SP1 以降は Standard でも使えますが、
  **DBあたり 32GB** のようなメモリ上限があります(バージョンとエディションで異なるため要確認)。
- メモリが尽きると **書き込みが止まります**(41805 / 41823)。
  読み取りは続けられますが、業務としては停止と同じです。

### 10-3. スキーマ変更のコスト

```sql
-- 列を1つ足すだけでも「テーブル全体の作り直し」になる
ALTER TABLE dbo.OrderQueue ADD 備考 NVARCHAR(200) NULL;
```

- SQL Server 2016 以降 `ALTER TABLE` は可能になりましたが、**オフライン操作**です。
  実行中はそのテーブルにアクセスできません。
- **内部的には新しいテーブルを作って全行をコピー**します。そのため
  **一時的に既存テーブルと同じだけのメモリが追加で必要**になります
  (10GB のテーブルなら、変更中は 20GB 必要)。
- `BUCKET_COUNT` の変更も同じコストです。
  → **「あとで直せばいい」が通用しません。設計時にバケット数を詰めておく必要があります。**
- ネイティブコンパイル プロシージャは、参照するテーブルが `ALTER` されると
  **次回実行時に自動的に再コンパイル**されます。

### 10-4. 【結論】採用を検討すべきワークロード

インメモリOLTP が効くのは **「ロック・ラッチ・ログがボトルネックになっている」場合だけ**です。
まず [23 待機統計](23_wait_statistics.md) で **何を待っているか**を確認してください。

**✅ 効く可能性が高い**

| ワークロード | 効く理由 | 推奨構成 |
|---|---|---|
| **高頻度 INSERT**(IoT・ログ・注文取り込み) | **ラストページ挿入競合(`PAGELATCH_EX`)が原理的に消える** | `SCHEMA_AND_DATA` + ハッシュPK |
| **セッション状態管理**(Webのセッション、一時的な画面状態) | ログI/Oがゼロ。消えても再作成できる | **`SCHEMA_ONLY`** |
| **ETL のステージング表** | ログを書かないので取り込みが劇的に速い。失敗したら再実行すればよい | **`SCHEMA_ONLY`** |
| **tempdb 競合(`PAGELATCH` on tempdb)** | 一時オブジェクトの作成競合を回避 | **メモリ最適化テーブル変数 / TVP** |
| **少数の行への超高頻度な更新**(在庫カウンタ等) | 待ち行列が消える。ただし**リトライ必須** | ハッシュPK + リトライ実装 |

**❌ 効かない / 逆効果**

| ワークロード | 理由 |
|---|---|
| **物理I/O がボトルネック**(`PAGEIOLATCH_*` 待ち) | メモリを増やすかインデックスを直すのが正解。18章へ戻る |
| **大規模な集計・分析クエリ** | それは **列ストア + バッチモード**の領分([30章](30_columnstore.md)) |
| **巨大な履歴テーブル** | メモリに載らない。**パーティショニング**([31章](31_partitioning.md))の領分 |
| **競合していないが単に遅いクエリ** | 原因はインデックスか統計。まず [18章](18_indexes_execution_plans.md) / [27章](27_statistics_cardinality.md) |
| **既存の複雑なストアドを高速化したい** | ネイティブコンパイルの構文制限で移植できない |
| **リトライを実装できないアプリ** | **導入してはいけません**。更新競合で業務が止まります |

> ⚠️ **導入判断の順序**
> 1. [23 待機統計](23_wait_statistics.md) で**上位の待機**を確認する。
>    `PAGELATCH_*`(tempdb や最終ページ)や `LCK_M_*` が支配的か?
> 2. そうでないなら、**インメモリOLTP は解決策ではありません**。
> 3. そうであっても、まず **RCSI / インデックス改善 / トランザクションの短縮**
>    ([19章](19_transactions_isolation.md))で解決しないか検討する。
> 4. それでも足りず、**アプリ側にリトライを実装できる**なら、
>    **限定した表だけ**をメモリ最適化テーブルにする。
>
> 「全テーブルをメモリ最適化テーブルにする」は、ほぼ確実に失敗する計画です。

---

## 11. 後片付け — データベースごと捨てる

**必ず実行してください。** これが「ファイルグループを消せない」問題への唯一の解です。

```sql
USE master;
GO

-- 実験用データベースを丸ごと破棄する(ファイルグループもコンテナもまとめて消える)
IF DB_ID(N'SalesLearningIM') IS NOT NULL
BEGIN
    ALTER DATABASE SalesLearningIM SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SalesLearningIM;
END
GO

-- 消えたことを確認
SELECT name FROM sys.databases WHERE name = N'SalesLearningIM';   -- 0 行

-- SalesLearning が無傷であることを確認(メモリ最適化ファイルグループが無いこと)
USE SalesLearning;
GO
SELECT fg.name, fg.type_desc
FROM   sys.filegroups AS fg;
-- → ROWS_FILEGROUP(PRIMARY)だけであること。
--    MEMORY_OPTIMIZED_DATA_FILEGROUP が出てきたら、誤って SalesLearning を変更している
```

> ⚠️ `DROP DATABASE` してもコンテナのディレクトリが残ることがあります。
> `sys.database_files` で確認していたパスを OS 側で確認し、
> 残っていたら手動で削除してください(ディスクを占有し続けます)。

---

## よくあるつまずき

- **「メモリに置けば速い」と思って導入する** → バッファプールが既にメモリに載せている。
  インメモリOLTP が解くのは **ロック・ラッチ・ログ**。まず待機統計を見ること。
- **業務DBにメモリ最適化ファイルグループを足してしまった** → **元に戻せません**。
  検証は必ず使い捨てのDBで。
- **`CREATE INDEX` でエラー** → メモリ最適化テーブルのインデックスは
  `CREATE TABLE` の中か `ALTER TABLE ... ADD INDEX` でしか作れない。
- **クラスタ化主キーを書いてエラー** → `PRIMARY KEY NONCLUSTERED` にする。
- **範囲検索が遅い** → ハッシュインデックスは範囲に使えない。**非クラスター化(範囲)索引**にする。
- **`BUCKET_COUNT` を適当に決めた** → 空バケット率 33% 未満なら不足、
  平均チェーン長が長いのに一意な値が少ないなら **そもそもハッシュが不適切**。
- **`ORDER BY ... DESC` が Sort 演算子になる** → 範囲索引は単方向。
  索引を `(列 DESC)` で定義する。
- **`SCHEMA_ONLY` にしたらデータが消えた** → 仕様どおり。再起動で消える。
  バックアップにも含まれない。
- **他DBを参照する `INSERT` がエラー** → メモリ最適化テーブルは
  クロスDBトランザクション不可。同一DBの作業表を経由する。
- **明示的トランザクションでエラー 41368** → `WITH (SNAPSHOT)` ヒントか
  `MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT = ON`。
- **`SET TRANSACTION ISOLATION LEVEL SNAPSHOT` にしたらエラー 41332** →
  ディスクテーブルを `SNAPSHOT` で読むトランザクションからはメモリ最適化テーブルに触れない。
- **41302 が出て処理が落ちる** → 仕様。**リトライが必須**。設計上の前提です。
- **リトライしているのに落ち続ける** → 全員が同じ行を更新している(ホットスポット)。
  インメモリOLTP でも **論理的な競合そのものは消せません**。
- **ネイティブコンパイルで既存プロシージャが移植できない** → CTE・動的SQL・`#t`・
  ディスクテーブル参照が使えない。**設計から作り直す**もの。
- **`SET STATISTICS IO` が 0 になる** → ページを読んでいないので当然。
  計測は CPU 時間 / 経過時間 / 実行プランで行う。
- **メモリが枯渇して書き込めない(41823/41805)** → リソースプールで上限を設ける。
  長時間トランザクションで GC が止まっていないかも確認する。

## この章のまとめ

- インメモリOLTP(**Hekaton**)は「メモリに置く機能」ではなく、
  **ロックもラッチも使わない楽観的 MVCC** によって
  **19章のブロッキングというボトルネックそのものを消す**技術。
- **SQL Server 2014 で導入、2016 で実用レベル**(`ALTER TABLE` 可・外部キー可)、
  **2016 SP1 から Standard でも利用可**。
- **`MEMORY_OPTIMIZED_DATA` ファイルグループは一度追加すると削除できない**。
  検証は必ず **使い捨てのデータベース**で行い、最後に `DROP DATABASE` する。
- **メモリ最適化テーブル**は `WITH (MEMORY_OPTIMIZED = ON, DURABILITY = ...)`。
  **`SCHEMA_AND_DATA`**(耐久)と **`SCHEMA_ONLY`**(再起動で消える。
  セッション状態・ステージングに最適)。
- **インデックスは2種類**。**ハッシュ**は等値専用で `BUCKET_COUNT` の見積もりが命
  (空バケット率 33% 以上・平均チェーン長 1〜2 が目安)。
  **非クラスター化(Bw-tree)** は範囲検索可・単方向。迷ったら範囲索引。
- **ネイティブコンパイル プロシージャ**は `WITH NATIVE_COMPILATION, SCHEMABINDING,
  EXECUTE AS OWNER` + `BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = ..., LANGUAGE = ...)`。
  **DLL にコンパイルされる**が、**使える T-SQL に厳しい制限がある**
  (CTE・動的SQL・`#t`・ディスクテーブル参照が不可)。
- **メモリ最適化テーブル変数 / TVP** は **tempdb を使わない**ため、
  tempdb 競合の現実的な回避策になる([15章](15_temp_tables.md) / [33章](33_architecture.md))。
  ただし統計情報は無く、メモリを消費する。
- **楽観的並行制御の代償は「待たない代わりに失敗する」**こと。
  **41302 / 41305 / 41325 / 41301 を捕まえるリトライロジックは必須**。
  サポート分離レベルは **`SNAPSHOT` / `REPEATABLE READ` / `SERIALIZABLE`**。
  ディスクテーブルとの混在は `WITH (SNAPSHOT)` か
  `MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT = ON`。
- **計測**は `sys.dm_db_xtp_table_memory_stats`(メモリ)、
  `sys.dm_db_xtp_hash_index_stats`(バケット)、`sys.dm_os_loaded_modules`(DLL)。
  **`SET STATISTICS IO` は使えない**。
- **銀の弾丸ではない**。パーティショニング不可、メモリ容量が上限、スキーマ変更が高コスト。
  効くのは **高頻度INSERT / ラッチ競合 / セッション状態 / ETLステージング / tempdb競合**。
  **まず待機統計を見て、原因がロックとラッチであることを確認してから**採用を検討すること。

➡ 演習: [exercises/32_in_memory_oltp.md](../exercises/32_in_memory_oltp.md)
