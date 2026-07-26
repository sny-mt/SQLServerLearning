# 31 パーティショニング

> **このトピックのゴール**: パーティショニングを **「速くするための機能」ではなく
> 「大きな表を運用可能なサイズの塊に切り分けるための機能」** として正しく理解する。
> **パーティション関数 / スキーム / アラインメント** の役割分担を説明でき、
> **SWITCH による一瞬のデータ入替・削除** と **スライディングウィンドウ運用** を自分で組めるようになる。
> あわせて **パーティション除外が効く条件と効かない条件** を実行プランで判定できるようになる。
>
> **前提**: [30 列ストアインデックスとバッチモード](30_columnstore.md) までを済ませていること。
> **さらに、この章は `sample-db/04_analytics_data.sql` を実行して
> `dbo.SalesFact`(1000万行)を作成済みであることが前提** です。まだなら先に実行してください
> (1〜3分ほどかかります。重い環境ではスクリプト内の `@Total` を 2000000 に減らして構いません)。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

```sql
-- 準備確認: 1000万行・2015〜2024年であることを確かめる
SELECT COUNT_BIG(*)  AS 行数,
       MIN(SaleDate) AS 最古,
       MAX(SaleDate) AS 最新
FROM   dbo.SalesFact;
```

`dbo.SalesFact` の構成(再掲):

| 列 | 型 | 内容 |
|---|---|---|
| `SaleId` | BIGINT | **クラスタ化主キー**。1〜10,000,000 の連番 |
| `SaleDate` | DATE | 2015-01-01〜2024-12-31。**`SaleId` にほぼ比例した日付順**で格納 |
| `CustomerId` | INT | 1〜1000(合成。`dbo.Customers` とは無関係なので結合しない) |
| `ProductId` | INT | 1〜20(`dbo.Products` と結合可能) |
| `EmployeeId` | INT | 1〜13(`dbo.Employees` と結合可能) |
| `RegionId` | INT | 1〜8 |
| `Quantity` / `UnitPrice` / `Discount` / `Amount` | 数値 | 金額系 |

> **エディションとバージョン**: テーブルパーティショニングは
> **SQL Server 2016 SP1 以降はすべてのエディション**(Standard / Web / Express を含む)で使えます。
> 2016 RTM 以前は Enterprise / Developer 専用でした。
> パーティション数の上限は **SQL Server 2012 以降 15,000**(それ以前は 1,000)。

---

## 1. 何のためにやるのか(この章で一番大事な節)

### 1-1. よくある誤解

> ⚠️ **「表が大きくて遅いからパーティショニングする」は、ほとんどの場合まちがいです。**

現場で最も多い誤解がこれです。1000万行のテーブルが遅いとき、まず疑うべきなのは
[18 インデックスと実行プラン](18_indexes_execution_plans.md) で学んだ
**インデックス設計・SARGability・統計情報** であり、分析系のスキャンが重いなら
[30 列ストアインデックスとバッチモード](30_columnstore.md) です。
**パーティショニングは性能改善の道具としては、これらより後ろに置くべき手段**です。

理由は単純で、パーティショニングは **B木の段数をほとんど減らさない** からです。

- 1000万行のクラスタ化インデックスは、B木の深さがせいぜい 4 段程度。
- これを 10 分割しても、各パーティションのB木は 3 段程度にしかなりません。
- つまり **1行を Seek するコストは「4回の読み取り」が「3回」になる程度**。桁は変わりません。

むしろ、**分割したことで遅くなる**ケースすらあります(後述の 8-3・13章)。

### 1-2. では本当の目的は何か

**大規模データの「運用性」** です。具体的には次の3つ。

| 目的 | パーティショニングなし | パーティショニングあり |
|---|---|---|
| **古いデータの削除(アーカイブ)** | `DELETE` で1000万行 → ログ肥大・長時間ロック | **`SWITCH` で一瞬**(メタデータ操作のみ) |
| **大量データの投入** | `INSERT` で数千万行 → 本番表を長時間ロック | ステージング表に静かに作って **`SWITCH` で一瞬**接続 |
| **保守作業(索引再構築・統計更新・圧縮)** | 表全体を一度に処理するしかない | **変化した区画だけ**処理できる |

さらに副次的に:

- **バックアップ/リストアの粒度**を分けられる(区画ごとに別ファイルグループへ置けば、
  古い区画を読み取り専用ファイルグループにして、以後バックアップ対象から外せる)。
- **ロックエスカレーションを区画単位**にできる(`LOCK_ESCALATION = AUTO`)。

### 1-3. 性能はどう位置づけるか

**パーティション除外(partition elimination)** によって性能が改善する「ことはあります」。
ただしそれは、

- **`WHERE` にパーティション列が含まれているときだけ**効く、
- しかも **同じ列に普通のインデックスを貼れば同等以上に効く**ことが多い、

という条件付きの効果です。**「性能はおまけ、主目的は運用性」** と覚えてください。

> ⚠️ 意思決定の順番:
> ① クエリの書き換え(SARGable 化)→ ② インデックス設計 → ③ 列ストア →
> ④ それでも「毎月の削除に何時間もかかる」「投入が本番を止める」なら **パーティショニング**。

**逆に、運用要件から出発したなら迷わず採用してよい**のもポイントです。
「7年より古いデータを毎月末に落とす」「毎日1億行を無停止で足す」といった要件は、
パーティショニング以外に現実的な答えがありません。

---

## 2. 全体像 — 3つの部品

パーティショニングは **3層** でできています。この分離が最初の関門なので、
先に地図を頭に入れてください。

```
  ① パーティション関数 (CREATE PARTITION FUNCTION)
        「値をどこで区切るか」だけを決める。表もファイルグループも知らない。
                    ↓  ON で結び付ける
  ② パーティションスキーム (CREATE PARTITION SCHEME)
        「①で区切ったN個の区画を、どのファイルグループに置くか」を決める。
                    ↓  CREATE TABLE ... ON スキーム名(列名)
  ③ パーティション表 / パーティションインデックス
        「①②を、どの表のどの列に適用するか」を決める。
```

- **関数は「論理的な区切り」、スキームは「物理的な配置」** と覚えます。
- 1つの関数を複数のスキームが使えますし、1つのスキームを複数の表が使えます
  (実務では **ファクト表とその関連表を同じ関数/スキームで分割**して、
  結合時にパーティションが揃うようにするのが定石)。
- この3層構造こそが、後片付けの順序(**表 → スキーム → 関数**)の理由になります(14章)。

---

## 3. パーティション関数 — `RANGE LEFT` と `RANGE RIGHT`

### 3-1. 基本形

```sql
CREATE PARTITION FUNCTION pf_SalesByYear (DATE)
AS RANGE RIGHT
FOR VALUES ('2015-01-01', '2016-01-01', '2017-01-01', '2018-01-01', '2019-01-01',
            '2020-01-01', '2021-01-01', '2022-01-01', '2023-01-01', '2024-01-01',
            '2025-01-01');
```

- 括弧内の `(DATE)` は **パーティション列のデータ型**。表の列名ではありません
  (関数はまだどの表にも紐づいていないため)。
- `FOR VALUES` に **境界値を N 個** 書くと、**区画は N+1 個** できます。
  上の例は境界 11 個 → **12 区画**。
- 境界値は昇順で書きます(順不同でも受け付けられますが、可読性のため必ず昇順で)。

### 3-2. `RANGE LEFT` / `RANGE RIGHT` の違い

違いはただ1点、**「境界値そのものが、左右どちらの区画に入るか」** です。

境界値 `'2016-01-01'` に対して:

| 指定 | 意味 | `'2016-01-01'` の行はどこへ |
|---|---|---|
| `RANGE LEFT` | 各区画は **「境界値 **以下**」** = `<=` | **左**(前の区画)の最後の値になる |
| `RANGE RIGHT` | 各区画は **「境界値 **以上**」** = `>=` | **右**(次の区画)の最初の値になる |

境界を `b1 < b2 < ... < bn` としたときの区画の範囲は次のとおりです。

- **`RANGE LEFT`**: 区画1 = `col <= b1`、区画2 = `b1 < col <= b2`、… 区画 n+1 = `bn < col`
- **`RANGE RIGHT`**: 区画1 = `col < b1`、区画2 = `b1 <= col < b2`、… 区画 n+1 = `bn <= col`

### 3-3. 日付では `RANGE RIGHT` が定石

理由は2つあります。

**① 境界値を「期間の始まり」として自然に書けるから。**

```sql
-- RANGE RIGHT: '2016-01-01' = 「2016年はここから始まる」。読んでそのまま。
FOR VALUES ('2016-01-01', '2017-01-01', ...)

-- RANGE LEFT で同じ区切りにしたいなら「期間の終わり」を書くことになる
FOR VALUES ('2015-12-31', '2016-12-31', ...)
```

**② `DATETIME` 系だと `RANGE LEFT` は事故のもとだから。**

列が `DATE` なら `'2015-12-31'` で問題ありませんが、`DATETIME` だと
`2015-12-31 09:00:00` の行は境界 `'2015-12-31'`(= `2015-12-31 00:00:00`)より大きいので
**翌年の区画に落ちます**。これを避けるには `'2015-12-31 23:59:59.997'` のような
**型の精度に依存した境界値** を書くしかなく、`DATETIME2(7)` に型を変えた瞬間に壊れます。

> ⚠️ **日付・時刻でパーティション分割するときは常に `RANGE RIGHT`、
> 境界値は「その期間の始まり」の 00:00:00 を書く。** これを鉄則にしてください。
> 18章で学んだ `WHERE 列 >= 開始 AND 列 < 翌期間の開始` という書き方と、
> まったく同じ思想(**半開区間**)です。

### 3-4. 両端を空にしておく(重要なテクニック)

3-1 の例をよく見ると、データは 2015-01-01 からなのに境界値に `'2015-01-01'` を、
データは 2024-12-31 までなのに `'2025-01-01'` を入れています。結果、

| 区画 | 範囲 | 中身 |
|---|---|---|
| 1 | `SaleDate < '2015-01-01'` | **常に空** |
| 2 | `'2015-01-01' <= SaleDate < '2016-01-01'` | 2015年 |
| … | … | … |
| 11 | `'2024-01-01' <= SaleDate < '2025-01-01'` | 2024年 |
| 12 | `SaleDate >= '2025-01-01'` | **常に空** |

**両端の区画をわざと空にしておく**のは定石です。理由は 10章のスライディングウィンドウで分かりますが、
先取りすると:

- **末尾が空** → `SPLIT` で来年の区画を足すとき、**データ移動ゼロ**で一瞬で終わる。
- **先頭が空** → 最古の区画を `SWITCH` で外したあと `MERGE` するとき、やはりデータ移動が起きない。

もし末尾の区画にデータが入っている状態で `SPLIT` すると、**その区画の全行が物理的に書き直され**、
その間ずっとロックが掛かります。1億行の区画でこれをやると本番が止まります。

### 3-5. `NULL` はどこへ行くか

パーティション列が NULL 許容の場合、**NULL は常に最も左の区画** に入ります。
`RANGE RIGHT` で第1境界が NULL の場合だけ例外的に2番目の区画になりますが、
**そもそもパーティション列は `NOT NULL` にしておく**のが実務の正解です
(`dbo.SalesFact.SaleDate` も `NOT NULL`)。

### 3-6. 作った関数を確認する

```sql
SELECT pf.name          AS 関数名,
       pf.type_desc     AS 種別,
       pf.boundary_value_on_right AS 右境界か,   -- 1 = RANGE RIGHT
       pf.fanout        AS 区画数,
       prv.boundary_id  AS 境界番号,
       prv.value        AS 境界値
FROM   sys.partition_functions AS pf
LEFT   JOIN sys.partition_range_values AS prv
       ON prv.function_id = pf.function_id
WHERE  pf.name = 'pf_SalesByYear'
ORDER  BY prv.boundary_id;
```

- **`sys.partition_functions`** … 関数そのもの(`fanout` = 区画数)。
- **`sys.partition_range_values`** … 境界値の一覧。

---

## 4. パーティションスキーム — ファイルグループへの割り当て

### 4-1. 簡易版: 全部を `PRIMARY` に置く

```sql
CREATE PARTITION SCHEME ps_SalesByYear
AS PARTITION pf_SalesByYear
ALL TO ([PRIMARY]);
```

- `ALL TO (...)` は「**全区画を1つのファイルグループに置く**」の意味。
- 学習・検証や、**ファイルグループを分ける運用上の理由がない場合**はこれで十分です。
  「区画ごとにファイルグループを分けないとパーティショニングの意味がない」というのは誤りで、
  **`SWITCH` の恩恵は `PRIMARY` 1つでも完全に受けられます**。

### 4-2. 本格版: 区画ごとにファイルグループを分ける

```sql
-- ① ファイルグループを作る(区画数ぶん + 予備1つ)
ALTER DATABASE SalesLearning ADD FILEGROUP FG_Sales_Old;
ALTER DATABASE SalesLearning ADD FILEGROUP FG_Sales_2023;
ALTER DATABASE SalesLearning ADD FILEGROUP FG_Sales_2024;
-- …(必要なだけ)

-- ② それぞれにデータファイルを追加する(FILENAME は自分の環境のパスに直すこと)
ALTER DATABASE SalesLearning
ADD FILE (NAME = N'SalesLearning_2024',
          FILENAME = N'C:\SQLData\SalesLearning_2024.ndf',
          SIZE = 64MB, FILEGROWTH = 64MB)
TO FILEGROUP FG_Sales_2024;

-- ③ 区画を「左から順に」ファイルグループへ割り当てる(区画数と個数を一致させる)
CREATE PARTITION SCHEME ps_SalesByYear
AS PARTITION pf_SalesByYear
TO (FG_Sales_Old, FG_Sales_Old, ..., FG_Sales_2023, FG_Sales_2024, FG_Sales_2024);
```

ファイルグループを分ける **本当の理由** は次のとおりです。単に「分散すると速い」ではありません。

- **古い区画を読み取り専用にできる**
  `ALTER DATABASE ... MODIFY FILEGROUP FG_Sales_Old READONLY;`
  → 以後は差分バックアップの対象から実質外れ、破損リスクも下がる。
- **ファイルグループ単位のリストア**(部分復元)が可能になる。
  「直近1年だけ先に復旧して業務再開、古い年は後から」という段取りが取れる。
- **ストレージ階層を分けられる**(直近は SSD、古い年は安価なディスク)。

> ⚠️ ファイルグループを増やすと **バックアップ/リストア手順とディスク管理が確実に複雑になります**。
> 上記のメリットが具体的に必要でないなら **`ALL TO ([PRIMARY])` で始めてください**。
>
> 元に戻す手順(検証後の後片付け):
> ```sql
> ALTER DATABASE SalesLearning REMOVE FILE  SalesLearning_2024;   -- 先にファイル
> ALTER DATABASE SalesLearning REMOVE FILEGROUP FG_Sales_2024;    -- 次にファイルグループ
> ```
> ファイルグループが空(どのオブジェクトも使っていない)でないと削除できません。

### 4-3. スキームと割り当てを確認する

```sql
SELECT ps.name           AS スキーム名,
       pf.name           AS 関数名,
       dds.destination_id AS 区画番号,
       fg.name           AS ファイルグループ
FROM   sys.partition_schemes AS ps
JOIN   sys.partition_functions AS pf
       ON pf.function_id = ps.function_id
JOIN   sys.destination_data_spaces AS dds
       ON dds.partition_scheme_id = ps.data_space_id
JOIN   sys.filegroups AS fg
       ON fg.data_space_id = dds.data_space_id
WHERE  ps.name = 'ps_SalesByYear'
ORDER  BY dds.destination_id;
```

- **`sys.partition_schemes`** / **`sys.destination_data_spaces`** / **`sys.filegroups`** がセットです。

---

## 5. パーティション表の作り方

### 5-1. 新規に作る

普段 `ON [PRIMARY]` と書く位置に、**スキーム名(パーティション列)** を書くだけです。

```sql
CREATE TABLE dbo.SalesFactPartitioned
(
    SaleId     BIGINT         NOT NULL,
    SaleDate   DATE           NOT NULL,
    CustomerId INT            NOT NULL,
    ProductId  INT            NOT NULL,
    EmployeeId INT            NOT NULL,
    RegionId   INT            NOT NULL,
    Quantity   INT            NOT NULL,
    UnitPrice  DECIMAL(10, 0) NOT NULL,
    Discount   DECIMAL(4, 2)  NOT NULL,
    Amount     DECIMAL(14, 2) NOT NULL,
    CONSTRAINT PK_SalesFactPartitioned
        PRIMARY KEY CLUSTERED (SaleId, SaleDate)   -- ★ パーティション列を含める
)
ON ps_SalesByYear (SaleDate);                      -- ★ ここがスキーム
```

- 表を「パーティション化する」というのは、正確には
  **クラスタ化インデックス(=表本体)をパーティションスキーム上に作る** ということです。
- ヒープ(クラスタ化インデックスなし)もパーティション化できます。
  その場合は `CREATE TABLE (...) ON ps_SalesByYear(SaleDate);` だけで、主キーは非クラスタ化になります。

### 5-2. 既存表をパーティション化する

既存表を後からパーティション化する方法は **「クラスタ化インデックスをスキーム上に作り直す」** です。
`ALTER TABLE ... PARTITION BY` のような構文は SQL Server にはありません。

**パターンA: クラスタ化インデックスが制約(PK/UQ)に紐づいていない場合**

```sql
CREATE CLUSTERED INDEX CIX_MyTable
    ON dbo.MyTable (SaleId, SaleDate)
    WITH (DROP_EXISTING = ON)
    ON ps_SalesByYear (SaleDate);
```

`DROP_EXISTING = ON` は「同名のインデックスを落として作り直す」オプションで、
**落として作るより1回のソートで済む**ぶん速く、非クラスタ化インデックスの
無駄な作り直しも避けられます。

**パターンB: クラスタ化主キーの場合(`dbo.SalesFact` はこちら)**

主キーにパーティション列を足す必要があるため、いったん制約を落とします。
このとき **`WITH (MOVE TO スキーム(列))`** を付けると、
制約を落とすのと同時に**ヒープをパーティションスキーム上へ移動**できます。

```sql
-- ① 主キーを落としつつ、本体をパーティションスキームへ移す
ALTER TABLE dbo.SalesFact
    DROP CONSTRAINT PK_SalesFact
    WITH (MOVE TO ps_SalesByYear (SaleDate));

-- ② パーティション列を含めた主キーを作り直す(アラインドになる)
ALTER TABLE dbo.SalesFact
    ADD CONSTRAINT PK_SalesFact
        PRIMARY KEY CLUSTERED (SaleId, SaleDate)
    ON ps_SalesByYear (SaleDate);
```

> ⚠️ **この演習ではこの手順を `dbo.SalesFact` に対して実行しないでください。**
> 他の章の題材が壊れます。**別表 `dbo.SalesFactPartitioned` を作ってコピーする**方式にします。
> なお、この操作は **全データを物理的に書き直す**ため、1000万行では数分〜数十分かかり、
> その間ずっと表がロックされます(`ONLINE = ON` は Enterprise のみ、かつ制限あり)。
> **本番では「新表を作って `SWITCH` で差し替える」ほうが安全**です。

### 5-3. データを投入する

パーティション表への投入は、**区画単位に分けて流す**のが定石です。

```sql
DECLARE @y INT = 2015;

WHILE @y <= 2024
BEGIN
    INSERT INTO dbo.SalesFactPartitioned WITH (TABLOCK)
        (SaleId, SaleDate, CustomerId, ProductId, EmployeeId,
         RegionId, Quantity, UnitPrice, Discount, Amount)
    SELECT SaleId, SaleDate, CustomerId, ProductId, EmployeeId,
           RegionId, Quantity, UnitPrice, Discount, Amount
    FROM   dbo.SalesFact
    WHERE  SaleDate >= DATEFROMPARTS(@y, 1, 1)
      AND  SaleDate <  DATEFROMPARTS(@y + 1, 1, 1);

    RAISERROR (N'  %d 年 投入完了', 0, 1, @y) WITH NOWAIT;
    SET @y += 1;
END;
```

- **1文で 1000万行を入れない**理由は `sample-db/04_analytics_data.sql` と同じで、
  トランザクションログが巨大化するためです。
- `WITH (TABLOCK)` は最小ログ記録を狙うためのヒント。
  復旧モデルが `SIMPLE` / `BULK_LOGGED` のとき効果があります
  (クラスタ化インデックスを持つ表への `INSERT ... SELECT` の最小ログ記録は **SQL Server 2016 以降**)。
- `DATEFROMPARTS` は **SQL Server 2012 以降**。

---

## 6. アラインメント — 「パーティション列は一意制約に必ず含める」

### 6-1. ルール

> ⚠️ **パーティション表に一意インデックス(主キー・一意制約・UNIQUE INDEX)を作るときは、
> パーティション列をキー列に含めなければなりません。**

含めないと、次のエラーになります。

```
Partition columns for a unique index must be a subset of the index key.
(一意インデックスのパーティション列は、インデックスキーのサブセットである必要があります)
```

**理由**: 一意性はB木をたどって確認します。パーティション表では区画ごとに独立したB木があるため、
**どの区画を見ればよいかが分からないと一意性を保証できません**。
`SaleDate` がキーに入っていれば、値からパーティション関数で区画番号を計算でき、
その1本のB木だけを見れば済みます。

そのため、パーティション表の主キーはほぼ必ず **複合キー** になります。

```sql
PRIMARY KEY CLUSTERED (SaleId, SaleDate)   -- ○
PRIMARY KEY CLUSTERED (SaleId)             -- ✗ エラー
```

### 6-2. 「業務上の一意性」が崩れることへの注意

`(SaleId, SaleDate)` の主キーが保証するのは
**「SaleId と SaleDate の組み合わせ」の一意性** であって、
**`SaleId` 単独の一意性ではありません**。
同じ `SaleId` が違う `SaleDate` で2件入っても、DB は止めてくれません。

これはパーティショニングを入れると必ず発生するトレードオフです。対処は次のいずれか。

- **サロゲートキーが日付から導出されている**なら実害なしとして受け入れる(多くのファクト表はこれ)。
- **どうしても単独一意性が要る**なら、**非アラインドな一意インデックス**を作る:
  ```sql
  CREATE UNIQUE NONCLUSTERED INDEX UQ_SalesFactPartitioned_SaleId
      ON dbo.SalesFactPartitioned (SaleId)
      ON [PRIMARY];        -- ★ スキームではなくファイルグループに置く = 非アラインド
  ```
  ただし **非アラインドなインデックスが1本でもあると `SWITCH` ができなくなります**(9-3)。
  つまり **パーティショニング最大の価値を捨てることになる**ので、慎重に。

### 6-3. アラインド / 非アラインド

- **アラインド(整列済み)インデックス** … 表と **同じパーティション関数** で分割されているインデックス。
  表と同じ区画境界を持つため、`SWITCH` の対象にできる。
- **非アラインドインデックス** … 分割されていない、あるいは違う関数で分割されているインデックス。

非クラスタ化インデックスを作るとき、`ON` を省略すると **自動的に表と同じスキームに作られる**
(= アラインドになる)ので、通常は何も意識しなくて構いません。

```sql
-- ON を省略 → ps_SalesByYear 上に作られ、自動的にアラインドになる
CREATE NONCLUSTERED INDEX IX_SalesFactPartitioned_ProductId
    ON dbo.SalesFactPartitioned (ProductId);
```

> 💡 アラインドな非クラスタ化インデックスには **パーティション列が暗黙で追加**されます
> (`sys.index_columns` で `partition_ordinal > 0` の行として見えます)。

確認クエリ:

```sql
SELECT i.name        AS インデックス名,
       i.type_desc   AS 種別,
       CASE WHEN ps.name IS NULL THEN N'非アラインド' ELSE N'アラインド' END AS 整列,
       ISNULL(ps.name, ds.name) AS 配置先
FROM   sys.indexes AS i
JOIN   sys.data_spaces AS ds
       ON ds.data_space_id = i.data_space_id
LEFT   JOIN sys.partition_schemes AS ps
       ON ps.data_space_id = i.data_space_id
WHERE  i.object_id = OBJECT_ID('dbo.SalesFactPartitioned')
  AND  i.index_id > 0;
```

---

## 7. 行がどの区画に入ったかを確認する

### 7-1. `$PARTITION` 関数

**`$PARTITION.関数名(式)`** は「その値がどの区画番号になるか」を返します。
表がなくても、値だけで試せます。

```sql
-- 単純に「この日付は何番の区画か」を調べる
SELECT $PARTITION.pf_SalesByYear('2015-01-01') AS p2015,
       $PARTITION.pf_SalesByYear('2018-07-15') AS p2018,
       $PARTITION.pf_SalesByYear('2024-12-31') AS p2024,
       $PARTITION.pf_SalesByYear('2030-01-01') AS p2030;
-- → 2, 5, 11, 12
```

**分布の確認**にはこう使います。実務で最初にやる健全性チェックです。

```sql
SELECT $PARTITION.pf_SalesByYear(SaleDate) AS 区画番号,
       MIN(SaleDate)  AS 最古,
       MAX(SaleDate)  AS 最新,
       COUNT_BIG(*)   AS 行数
FROM   dbo.SalesFactPartitioned
GROUP  BY $PARTITION.pf_SalesByYear(SaleDate)
ORDER  BY 区画番号;
```

> 💡 `WHERE $PARTITION.pf_SalesByYear(SaleDate) = 5` と書くと、
> **その区画だけを狙い撃ちで走査**できます(区画番号で直接絞れる唯一の書き方)。
> 保守スクリプトでは便利ですが、業務クエリでは日付範囲で書くほうが読みやすく、
> 除外も同じように効きます。

### 7-2. カタログビューで区画一覧を出す

`$PARTITION` は実際にデータを読むので、1000万行では時間がかかります。
**行数だけなら `sys.partitions` を見れば一瞬**です(メタデータから読むため)。

```sql
SELECT p.partition_number       AS 区画番号,
       lo.value                 AS 下限_以上,
       hi.value                 AS 上限_未満,
       p.rows                   AS 行数,
       fg.name                  AS ファイルグループ,
       p.data_compression_desc  AS 圧縮
FROM   sys.partitions AS p
JOIN   sys.indexes AS i
       ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN   sys.partition_schemes AS ps
       ON ps.data_space_id = i.data_space_id
JOIN   sys.partition_functions AS pf
       ON pf.function_id = ps.function_id
LEFT   JOIN sys.partition_range_values AS lo      -- RANGE RIGHT のときの下限
       ON lo.function_id = pf.function_id
      AND lo.boundary_id = p.partition_number - 1
LEFT   JOIN sys.partition_range_values AS hi      -- RANGE RIGHT のときの上限
       ON hi.function_id = pf.function_id
      AND hi.boundary_id = p.partition_number
JOIN   sys.destination_data_spaces AS dds
       ON dds.partition_scheme_id = ps.data_space_id
      AND dds.destination_id      = p.partition_number
JOIN   sys.filegroups AS fg
       ON fg.data_space_id = dds.data_space_id
WHERE  p.object_id = OBJECT_ID('dbo.SalesFactPartitioned')
  AND  p.index_id IN (0, 1)                        -- 0=ヒープ / 1=クラスタ化
ORDER  BY p.partition_number;
```

> ⚠️ 上の `lo` / `hi` の結び付け方は **`RANGE RIGHT` 前提**です。
> `RANGE LEFT` の場合は「区画 k の上限(以下)が `boundary_id = k`」になります。
> `sys.partition_functions.boundary_value_on_right` を見れば、どちらか判定できます。

`sys.partitions.rows` は**概算値ではなく実際の行数**ですが、更新のタイミングによっては
一時的にずれることがあります。厳密に数えたいときは `COUNT_BIG(*)` を使ってください。

---

## 8. パーティション除外 (partition elimination)

### 8-1. 効く条件

**`WHERE` 句にパーティション列に対する SARGable な条件があるとき**、
オプティマイザは「この区画は絶対に該当しない」と判断して読み飛ばします。これが除外です。

```sql
-- ○ 除外が効く: SaleDate に対する範囲条件 → 区画5(2018年)だけ読む
SELECT COUNT_BIG(*), SUM(Amount)
FROM   dbo.SalesFactPartitioned
WHERE  SaleDate >= '2018-01-01'
  AND  SaleDate <  '2019-01-01';
```

```sql
-- ✗ 除外が効かない: パーティション列の条件がない → 全12区画を読む
SELECT COUNT_BIG(*), SUM(Amount)
FROM   dbo.SalesFactPartitioned
WHERE  CustomerId = 500;
```

```sql
-- ✗ 除外が効かない: 列を関数で包んでいる(18章の SARGability と同じ話)
SELECT COUNT_BIG(*), SUM(Amount)
FROM   dbo.SalesFactPartitioned
WHERE  YEAR(SaleDate) = 2018;
```

> ⚠️ **`YEAR(SaleDate) = 2018` は「年で分割している表」でも除外が効きません。**
> 「年で切ってあるのだから `YEAR()` で書けば当然速いはず」と考えがちですが、逆です。
> パーティション除外は **列の生の値に対する比較**からしか導けません。
> **18章の SARGability の原則は、パーティション除外にもそのまま効きます。**

### 8-2. 実行プランでの確認方法 — `Actual Partition Count`

1. SSMS で **`Ctrl` + `M`**(実際の実行プランを含める)を ON にする。
2. クエリを実行し、プランの **`Clustered Index Scan` / `Clustered Index Seek` 演算子**を選ぶ。
3. **`F4`(プロパティ ウィンドウ)** を開いて、次の項目を見る。

| プロパティ | 意味 |
|---|---|
| **`Partitioned`** | `True` なら、この演算子はパーティション表を触っている |
| **`Actual Partition Count`** | **実際に読んだ区画の数**。ここが本命 |
| **`Actual Partitions Accessed`** | 実際に読んだ区画番号の範囲(例: `5..5`) |
| `Seek Predicates` の `PtnId1000` | 区画番号に対する内部的な絞り込み条件 |

判断基準はシンプルです。

- `Actual Partition Count` が **1〜2** … 除外がしっかり効いている。
- `Actual Partition Count` が **区画数と同じ(この例なら 12)** … **除外がまったく効いていない**。
  `WHERE` にパーティション列の条件があるか、関数で包んでいないかを疑う。

> ⚠️ **`Actual Partition Count` は「実際の実行プラン」にしか出ません**。
> 推定プラン(`Ctrl`+`L`)には `Partitioned = True` は出ますが実測値は出ません。

### 8-3. 静的除外と動的除外

```sql
-- ① 静的除外: リテラルなのでコンパイル時に区画が確定する
SELECT COUNT_BIG(*) FROM dbo.SalesFactPartitioned
WHERE SaleDate >= '2018-01-01' AND SaleDate < '2019-01-01';

-- ② 動的除外: 変数の中身は実行時にしか分からない
DECLARE @from DATE = '2018-01-01', @to DATE = '2019-01-01';
SELECT COUNT_BIG(*) FROM dbo.SalesFactPartitioned
WHERE SaleDate >= @from AND SaleDate < @to;
```

②でも除外自体は効きます(`RangePartitionNew()` という内部関数がプランに現れ、
**実行時に**区画を絞り込みます)。ただし **推定行数は全区画ぶんで見積もられる**ため、
28章のパラメータスニッフィングと同じ問題(結合方式の誤選択・メモリ不足)が起こり得ます。
気になる場合は `OPTION (RECOMPILE)` で実測してください。

### 8-4. 除外は「インデックスの代わり」にはならない

8-1 の `WHERE CustomerId = 500` は全区画を読みます。これを速くしたいなら、
**パーティショニングではなく `CustomerId` の非クラスタ化インデックス**が答えです。

さらに重要な事実として、**分割したことで遅くなる**パターンがあります。

```sql
-- パーティション表に対して、ある1行を SaleId だけで引く
SELECT * FROM dbo.SalesFactPartitioned WHERE SaleId = 5000000;
```

`SaleId` はパーティション列ではないので、**12個すべてのB木を Seek** する必要があります
(プランでは `Actual Partition Count = 12` の Clustered Index Seek になります)。
分割していなければB木1本の Seek で済んだところが、12本になったわけです。

> ⚠️ **これが「パーティショニングで遅くなる」典型例**です。
> OLTP 的な単一行アクセスが主体の表を、その列以外でパーティション分割すると、
> **アクセスコストが区画数に比例して増えます**。

---

## 9. パーティション `SWITCH` — この機能の最大の価値

### 9-1. `SWITCH` とは何か

**`ALTER TABLE ... SWITCH`** は、**あるパーティション(または表全体)の所有権を、
別の表へ付け替える** 操作です。

**データは1バイトも動きません。** メタデータ上の「このページ群はこの表のもの」という
記述を書き換えるだけなので、**行数に関係なく一瞬(ミリ秒〜秒)で終わります**。

| 操作 | 1000万行の場合 |
|---|---|
| `DELETE FROM ... WHERE SaleDate < '2016-01-01'` | 数分〜数十分。ログが行数ぶん膨らむ。長時間ロック |
| `ALTER TABLE ... SWITCH PARTITION 2 TO ...` + `DROP TABLE` | **ほぼ一瞬**。ログはメタデータぶんのみ |

### 9-2. スイッチアウト(アーカイブ・高速削除)

```sql
-- ① 受け皿を作る。★構造は完全に同じ、★同じファイルグループ、★パーティション化しない
CREATE TABLE dbo.SalesFactArchive2015
(
    SaleId     BIGINT         NOT NULL,
    SaleDate   DATE           NOT NULL,
    CustomerId INT            NOT NULL,
    ProductId  INT            NOT NULL,
    EmployeeId INT            NOT NULL,
    RegionId   INT            NOT NULL,
    Quantity   INT            NOT NULL,
    UnitPrice  DECIMAL(10, 0) NOT NULL,
    Discount   DECIMAL(4, 2)  NOT NULL,
    Amount     DECIMAL(14, 2) NOT NULL,
    CONSTRAINT PK_SalesFactArchive2015
        PRIMARY KEY CLUSTERED (SaleId, SaleDate)     -- 同じキー構成
)
ON [PRIMARY];                                        -- 区画2 と同じファイルグループ

-- ② 区画2(2015年)を丸ごと付け替える
ALTER TABLE dbo.SalesFactPartitioned
    SWITCH PARTITION 2 TO dbo.SalesFactArchive2015;

-- ③ アーカイブするなら別DBへコピー、捨てるなら DROP
DROP TABLE dbo.SalesFactArchive2015;
```

実行後、`dbo.SalesFactPartitioned` の区画2は **0行** になり、
`dbo.SalesFactArchive2015` に約100万行が入っています。

### 9-3. スイッチの前提条件(ここを外すと必ず失敗する)

`SWITCH` は「メタデータの書き換えだけ」で済ませるため、
**移動先が移動元とまったく同じ物理レイアウトである**ことを要求します。
条件を1つでも外すと **Msg 4939 / 4982 系のエラー**で拒否されます。

| # | 条件 |
|---|---|
| 1 | **同じファイルグループ**にあること(区画N が置かれているファイルグループ = 相手表のファイルグループ) |
| 2 | **列の構成が完全一致**(列名・順序・データ型・長さ・精度・照合順序・NULL 許容・IDENTITY・計算列) |
| 3 | **移動先が空**であること(スイッチアウトの受け皿は 0 行) |
| 4 | **インデックスが一致**していること。移動元のアラインドなインデックスと同じものが移動先にもある。**非アラインドなインデックスが1本でもあると不可** |
| 5 | **圧縮設定が一致**(`DATA_COMPRESSION`)、`TEXTIMAGE_ON`、`大きな値の行外格納` 設定も一致 |
| 6 | **移動先を参照する外部キーがない**こと(移動先から他表へ張る FK は可) |
| 7 | **レプリケーションのパブリッシュ対象でない**こと |
| 8 | スイッチ**イン**の場合、移動元表に **区画の範囲を保証する CHECK 制約**が必要(9-4) |
| 9 | 全文検索インデックス・XML インデックスなどが両者で一致していること |

> 💡 条件2は想像以上に厳しく、**`NOT NULL` / `NULL` の食い違いだけでも失敗**します。
> 実務では **受け皿の DDL を「本体の DDL からコピーして、`ON スキーム` を `ON ファイルグループ` に
> 変えただけ」** にするのが安全です。SSMS の「スクリプト生成」を使うのが確実。

**ロックについて**: `SWITCH` は両方の表に **スキーマ変更ロック(Sch-M)** を取ります。
一瞬ですが、**その表を読んでいるセッションが1つでもあると待たされ、
逆に `SWITCH` が待っている間は新しい読み取りもブロックされます**。
本番では次の書き方でブロッキングの連鎖を防げます(**SQL Server 2014 以降**)。

```sql
ALTER TABLE dbo.SalesFactPartitioned
    SWITCH PARTITION 2 TO dbo.SalesFactArchive2015
    WITH (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF));
-- 1分待って取れなければ、自分(SELF)が諦める。BLOCKERS を指定すると相手を強制終了する。
```

### 9-4. スイッチイン(高速な一括投入)

新しいデータをステージング表に静かにロードしてから、一瞬で本体に接続します。
**本体は投入処理中まったくロックされません**。ETL の定石です。

```sql
-- ① ステージング表(本体と同一構造・同一ファイルグループ・パーティション化なし)
CREATE TABLE dbo.SalesFactStage2025
(
    /* … dbo.SalesFactPartitioned と完全に同じ列定義 … */
    CONSTRAINT PK_SalesFactStage2025 PRIMARY KEY CLUSTERED (SaleId, SaleDate)
) ON [PRIMARY];

-- ② ゆっくりロードする(本体には一切触れないので、業務時間中でも安全)
INSERT INTO dbo.SalesFactStage2025 (...) SELECT ... ;

-- ③ ★必須: 「この表の中身は本当に区画12の範囲に収まっている」ことを CHECK 制約で保証する
ALTER TABLE dbo.SalesFactStage2025
    ADD CONSTRAINT CK_SalesFactStage2025_Range
        CHECK (SaleDate >= '2025-01-01' AND SaleDate < '2026-01-01');

-- ④ 一瞬で接続する
ALTER TABLE dbo.SalesFactStage2025
    SWITCH TO dbo.SalesFactPartitioned PARTITION 12;
```

**③ の CHECK 制約が要る理由**: `SWITCH` は中身を1行も検査しません(だから速い)。
そのぶん「範囲外の行が紛れ込んでいない」ことを **宣言的に証明**する必要があり、
その役割が CHECK 制約です。付け忘れると次のエラーになります。

```
ALTER TABLE SWITCH statement failed. Check constraints of source table
'...' allow values that are not allowed by range defined by partition N
on target table '...'.
```

> ⚠️ CHECK 制約は **信頼済み(trusted)** でなければなりません。
> `WITH NOCHECK` で追加すると `is_not_trusted = 1` になり、`SWITCH` は失敗します。
> 確認: `SELECT name, is_not_trusted FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID('dbo.SalesFactStage2025');`
>
> また、境界の書き方は **パーティション関数の `RANGE RIGHT` / 半開区間と厳密に一致**させます。
> `BETWEEN '2025-01-01' AND '2025-12-31'` だと区画の範囲(`< 2026-01-01`)と一致せず失敗します。

### 9-5. `TRUNCATE TABLE ... WITH (PARTITIONS ...)` — 削除だけなら更に簡単

**捨てるだけ**(アーカイブ不要)なら、受け皿の表すら要りません。**SQL Server 2016 以降**:

```sql
TRUNCATE TABLE dbo.SalesFactPartitioned WITH (PARTITIONS (2));
TRUNCATE TABLE dbo.SalesFactPartitioned WITH (PARTITIONS (2, 4 TO 6));   -- 範囲指定も可
```

- `SWITCH` + `DROP TABLE` と同じ速さで、手順が1行。
- ただし **完全に消える**ので、アーカイブが必要なら `SWITCH` を使ってください。

---

## 10. `SPLIT` / `MERGE` とスライディングウィンドウ運用

### 10-1. `SPLIT` — 区画を増やす

```sql
-- ★必須: 新しくできる区画を置くファイルグループを先に指定する
ALTER PARTITION SCHEME ps_SalesByYear NEXT USED [PRIMARY];

-- 末尾の空区画を 2026-01-01 で割る → 2025年用の区画ができる
ALTER PARTITION FUNCTION pf_SalesByYear() SPLIT RANGE ('2026-01-01');
```

- `ALTER PARTITION FUNCTION` の括弧は **空**です(`pf_SalesByYear()`)。
- **`NEXT USED` を先に設定しないと失敗します**
  (「パーティション スキームには次に使用するファイル グループがありません」というエラー)。
  `ALL TO` で作ったスキームでも、明示しておくのが確実です。
- **`SPLIT` は分割対象の区画にデータがあると、その全行を物理的に書き直します。**
  必ず **空の区画を割る**ようにしてください(3-4 で末尾を空にしておいた理由)。

### 10-2. `MERGE` — 区画を減らす

```sql
-- 境界 '2015-01-01' を消す → 区画1(空) と 区画2 が1つになる
ALTER PARTITION FUNCTION pf_SalesByYear() MERGE RANGE ('2015-01-01');
```

- `MERGE RANGE` に渡すのは **消したい境界値**です。区画番号ではありません。
- **`MERGE` は、統合される2区画の片方(または両方)が空でないとデータ移動が発生します。**
  `SWITCH` で空にしてから `MERGE` するのが正しい順序です。
- `MERGE` すると **区画番号が繰り上がります**。
  「先週は区画3だったから今週も3」は成り立たないので、
  **保守スクリプトでは区画番号をハードコードせず、`$PARTITION` や
  `sys.partition_range_values` から求める**ようにしてください。

### 10-3. スライディングウィンドウ(定型パターン)

「直近 N 期間ぶんだけを保持し、古い期間は落とす」という運用を、
毎期この4手順で回します。これが実務における**パーティショニングの完成形**です。

```
【毎月 or 毎年 の定型作業】

  ① 未来側を用意する  ALTER PARTITION SCHEME ... NEXT USED ...
                       ALTER PARTITION FUNCTION ... SPLIT RANGE (次期間の開始)
                       → 末尾の空区画を割るのでデータ移動ゼロ

  ② 新データを載せる  ステージング表にロード → CHECK 制約 → SWITCH IN
                       → 本体をロックせずに一瞬で接続

  ③ 最古を切り離す    ALTER TABLE 本体 SWITCH PARTITION 最古 TO アーカイブ表
                       → 一瞬。アーカイブ表は別DBへ移すか DROP

  ④ 過去側を片付ける  ALTER PARTITION FUNCTION ... MERGE RANGE (最古の境界)
                       → 両側が空なのでデータ移動ゼロ
```

- ①と④で **区画数が一定に保たれる**ため、「窓がスライドする」と呼ばれます。
- ①〜④はすべて **メタデータ操作**で、行数に依存しません。
  数十億行の表でも所要時間は変わりません。
- ①は **前もって(数期間ぶん先まで)やっておく**のが安全です。
  月次バッチ当日に `SPLIT` が失敗すると、その日の投入が止まります。

---

## 11. パーティション単位の保守

### 11-1. インデックスの再構築・再編成

パーティション表の最大の実利のひとつが、**変化した区画だけ**保守できることです。

```sql
-- 区画11(2024年)だけ再構築する
ALTER INDEX PK_SalesFactPartitioned ON dbo.SalesFactPartitioned
    REBUILD PARTITION = 11;

-- 区画11 だけ再編成する(常にオンライン。全エディション)
ALTER INDEX PK_SalesFactPartitioned ON dbo.SalesFactPartitioned
    REORGANIZE PARTITION = 11;

-- すべての区画を対象にする場合(従来どおり)
ALTER INDEX PK_SalesFactPartitioned ON dbo.SalesFactPartitioned
    REBUILD PARTITION = ALL;
```

- **単一パーティションのオンライン再構築**(`WITH (ONLINE = ON)` + `PARTITION = n`)は
  **SQL Server 2014 以降** かつ **Enterprise 相当**です。
- 断片化を区画別に見るには **`sys.dm_db_index_physical_stats`** の
  第4引数にパーティション番号(または `NULL` で全区画)を渡します。

```sql
SELECT partition_number                AS 区画番号,
       index_type_desc                 AS 種別,
       avg_fragmentation_in_percent    AS 断片化率,
       page_count                      AS ページ数
FROM   sys.dm_db_index_physical_stats
       (DB_ID(), OBJECT_ID('dbo.SalesFactPartitioned'), 1, NULL, 'SAMPLED')
ORDER  BY partition_number;
```

判断基準の目安(18章と同じ): 断片化率 5〜30% なら `REORGANIZE`、30% 超なら `REBUILD`、
ただし **`page_count` が 1000 未満の区画は放置してよい**。

### 11-2. インクリメンタル統計(**SQL Server 2014 以降**)

通常の統計情報は **表全体で1つのヒストグラム**です。1000万行の表で
2024年の区画にだけ100万行足しても、統計を更新するには**全1000万行をサンプリング**し直します。

**インクリメンタル統計**は、**区画ごとに統計を保持して後でマージ**する方式です。
更新した区画ぶんだけ読めばよいので、統計更新が劇的に速くなります。

```sql
-- インデックス作成時に指定
CREATE NONCLUSTERED INDEX IX_SalesFactPartitioned_ProductId
    ON dbo.SalesFactPartitioned (ProductId)
    WITH (STATISTICS_INCREMENTAL = ON);

-- 既存インデックスに後から付ける
ALTER INDEX PK_SalesFactPartitioned ON dbo.SalesFactPartitioned
    REBUILD WITH (STATISTICS_INCREMENTAL = ON);

-- 列統計を作るとき
CREATE STATISTICS ST_SalesFactPartitioned_RegionId
    ON dbo.SalesFactPartitioned (RegionId)
    WITH INCREMENTAL = ON;

-- DB 既定にする
ALTER DATABASE SalesLearning SET AUTO_CREATE_STATISTICS ON (INCREMENTAL = ON);
```

有効にすると、**区画を指定した統計更新**ができるようになります。

```sql
UPDATE STATISTICS dbo.SalesFactPartitioned (PK_SalesFactPartitioned)
    WITH RESAMPLE ON PARTITIONS (11);
```

> ⚠️ **誤解しやすい点**: インクリメンタル統計は
> **「統計更新を速くする」機能であって、「区画ごとの推定精度を上げる」機能ではありません。**
> オプティマイザは最適化時に、区画別統計を**マージした表全体のヒストグラム**を使います。
> 「2024年の区画だけ分布が違うから正しく推定してほしい」という期待には応えません。
> そこは 27章(統計情報とカーディナリティ推定)の話になります。
>
> また、`WITH RESAMPLE ON PARTITIONS` はインクリメンタル統計が有効な統計にしか使えません。

---

## 12. 列ストアとの組み合わせ

[30 列ストアインデックスとバッチモード](30_columnstore.md) と組み合わせるのは、
データウェアハウスにおける最も一般的な構成です。

```sql
-- パーティションスキーム上にクラスタ化列ストアインデックスを作る
CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesFactPartitioned
    ON dbo.SalesFactPartitioned
    ON ps_SalesByYear (SaleDate);
```

### 12-1. 相性が良い理由

- **列ストアのセグメント除外**(30章)と **パーティション除外** は**独立に効き、重ねられる**。
  区画で年を絞り、さらにセグメントの min/max で月を絞る、という二段構えになる。
- 列ストアは **区画単位で再構築**できるので、
  「デルタストアが溜まった直近の区画だけ `REBUILD`」という運用が成立する。
- **区画単位で圧縮方式を変えられる**。直近は `COLUMNSTORE`、
  もう更新されない古い年は `COLUMNSTORE_ARCHIVE` にしてさらに縮める:
  ```sql
  ALTER TABLE dbo.SalesFactPartitioned
      REBUILD PARTITION = 2 WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE);
  ```
- **行ストアと列ストアを区画ごとに使い分ける**構成も取れる
  (直近区画は行ストアで OLTP、古い区画は列ストアで分析)。

### 12-2. 相性が悪くなる条件(必ず押さえる)

> ⚠️ **列ストアのロウグループ(行グループ)は、パーティションをまたげません。**

列ストアは 1,048,576 行を1ロウグループにまとめて圧縮したときに最高効率になります。
区画を細かく切りすぎると、**各区画のロウグループが小さくなり、圧縮率もバッチモードの効率も落ちます**。

`dbo.SalesFact` は1000万行なので:

| 分割の粒度 | 1区画あたり | ロウグループ品質 |
|---|---|---|
| **年**(10区画) | 約100万行 | **ちょうど1ロウグループぶん。良好** |
| 月(120区画) | 約8万行 | ロウグループが 1/12 サイズ。**明確に劣化** |
| 日(3653区画) | 約2700行 | ほぼ全部デルタストア行き。**列ストアの意味がない** |

**判断基準**: 列ストアを併用するなら、**1区画あたり最低でも100万行、
できれば数百万行以上**を確保できる粒度にしてください。
これはパーティション設計で最も具体的で使える経験則です。

ロウグループの状態は **`sys.dm_db_column_store_row_group_physical_stats`** で確認します
(`partition_number` 列があるので区画別に見られます)。

---

## 13. アンチパターン

### 13-1. 小さい表をパーティション化する

- **数十万行程度の表に効果はありません。** 運用上のメリット(SWITCH の必要性)がないなら
  複雑さだけが増えます。
- 目安として、**「区画を1つ落とすのに `DELETE` で何分もかかる」規模でなければ不要**。
  数千万行〜数億行、あるいは数十GB以上が出発点です。
- 小さい表では、`SPLIT` / `MERGE` / `SWITCH` の運用スクリプトを書いて維持するコストのほうが、
  得られるものより大きくなります。

### 13-2. パーティション列を `WHERE` に含めない設計

- **業務クエリが日付で絞らないのに日付でパーティション分割する**のは、
  8-4 で見たとおり **全区画アクセス**を招くだけです。
- 設計時に必ず「**主要なクエリの `WHERE` に、そのパーティション列が入っているか**」を確認します。
- 逆に、**運用要件(削除・投入の単位)とクエリ要件(絞り込みの単位)が一致しない**場合は、
  **運用要件を優先**します。パーティショニングの主目的は運用性だからです
  (クエリのほうは非クラスタ化インデックスで手当てします)。

### 13-3. 区画が多すぎる

- 上限は 15,000 ですが、**実用的には数百程度まで**と考えてください。
- 区画が増えると:
  - **コンパイル時間が伸びる**(オプティマイザが区画情報を扱うコストが増える)。
  - **メタデータが増え**、`sys.partitions` を舐める保守クエリが重くなる。
  - **12-2 のロウグループ問題**が起きる。
  - 区画列を含まないクエリの Seek コストが**区画数に比例**する(8-4)。
- 「7年ぶんを日次で切る」→ 2555区画。これはやりすぎです。
  **直近1年は月次(12)、それ以前は年次(6)** のように **粒度を混在**させれば 18 区画で済みます。
  パーティション関数の境界値は等間隔である必要はありません。

### 13-4. その他の落とし穴

- **「性能改善のため」と説明してパーティショニングを導入する** → 1章の話。期待外れに終わります。
- **非アラインドな一意インデックスを作って `SWITCH` を封じる** → 6-2。
- **`SPLIT` の前に `NEXT USED` を設定し忘れる** → 10-1。月次バッチが止まります。
- **区画番号をスクリプトにハードコードする** → `MERGE` でずれます(10-2)。
- **`WHERE YEAR(列) = 2018` と書く** → 除外が効きません(8-1)。

---

## 14. 後片付け — 削除の順序が決まっている

パーティション関連オブジェクトには **依存関係があり、削除順序が決まっています**。

```
  表 (およびパーティションインデックス)
        ↓  が使っている
  パーティションスキーム
        ↓  が使っている
  パーティション関数
```

**依存されている側は、先に削除できません。** したがって **表 → スキーム → 関数** の順です。

```sql
-- ① 表を落とす(スキームを使っているのは表なので、これが最初)
DROP TABLE IF EXISTS dbo.SalesFactPartitioned;
DROP TABLE IF EXISTS dbo.SalesFactArchive2015;
DROP TABLE IF EXISTS dbo.SalesFactStage2025;
GO

-- ② スキームを落とす
DROP PARTITION SCHEME ps_SalesByYear;
GO

-- ③ 関数を落とす
DROP PARTITION FUNCTION pf_SalesByYear;
GO
```

順序を間違えると、次のように拒否されます。

| やろうとしたこと | 出るエラー(要旨) |
|---|---|
| 表があるのに `DROP PARTITION SCHEME` | 「パーティション スキーム `ps_SalesByYear` は、1つ以上のテーブルまたはインデックスのパーティション分割に現在使用されています」 |
| スキームがあるのに `DROP PARTITION FUNCTION` | 「パーティション関数 `pf_SalesByYear` を削除できません。1つ以上のパーティション スキームで使用されています」 |

> 💡 `DROP ... IF EXISTS` は **SQL Server 2016 以降**で、
> `DROP PARTITION SCHEME` / `DROP PARTITION FUNCTION` にも使えます。

**誰が使っているかを事前に調べる**クエリ:

```sql
-- このスキームを使っているオブジェクト
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS オブジェクト,
       i.name AS インデックス名,
       ps.name AS スキーム名
FROM   sys.indexes AS i
JOIN   sys.partition_schemes AS ps
       ON ps.data_space_id = i.data_space_id
ORDER  BY オブジェクト;

-- この関数を使っているスキーム
SELECT ps.name AS スキーム名, pf.name AS 関数名
FROM   sys.partition_schemes AS ps
JOIN   sys.partition_functions AS pf
       ON pf.function_id = ps.function_id;
```

---

## よくあるつまずき

- **「パーティション化したのに速くならない」** → 当然です。目的が違います(1章)。
  速度を求めるならインデックスか列ストアへ。
- **`WHERE YEAR(SaleDate) = 2018` で全区画スキャンになる** → 除外は
  **列の生の値に対する比較**からしか導けません。`>= AND <` の半開区間に書き換える(8-1)。
- **`Actual Partition Count` がプロパティに出ない** → 推定プランを見ています。
  `Ctrl`+`M`(実際の実行プラン)にしてから実行し直す(8-2)。
- **主キーが作れない(`Partition columns for a unique index must be a subset of the index key`)**
  → パーティション列をキーに含める(6-1)。
- **`SWITCH` が失敗する** → 9-3 のチェックリストを上から順に潰す。
  多いのは「ファイルグループ違い」「NULL 許容の食い違い」「CHECK 制約なし/未信頼」。
- **`SPLIT` が終わらない・ロックが長い** → 空でない区画を割っています。
  末尾に空の区画を用意しておく(3-4、10-1)。
- **`SPLIT` が「次に使用するファイルグループがありません」で失敗する**
  → `ALTER PARTITION SCHEME ... NEXT USED ...` を先に実行する(10-1)。
- **`DROP PARTITION FUNCTION` ができない** → 表 → スキーム → 関数 の順に削除する(14章)。
- **列ストアの圧縮率が上がらない** → 区画を切りすぎてロウグループが小さい(12-2)。

## この章のまとめ

- **パーティショニングの主目的は「性能」ではなく「大規模データの運用性」**。
  **保守・入替・アーカイブ**のための機能。速度改善が目的なら先にインデックスと列ストアを疑う。
- 部品は3層: **パーティション関数**(値の区切り)→ **パーティションスキーム**(物理配置)→ **表**。
  この依存関係が、後片付けの順序(**表 → スキーム → 関数**)になる。
- **日付分割は `RANGE RIGHT` が定石**。境界値は「期間の始まり」を書く(半開区間)。
  **両端に空の区画を用意**しておくと `SPLIT` / `MERGE` がデータ移動ゼロで済む。
- ファイルグループは **`ALL TO ([PRIMARY])` で始めてよい**。
  分けるのは **読み取り専用化・部分リストア・ストレージ階層化**という具体的な要件があるときだけ。
- **一意インデックスにはパーティション列を必ず含める**。
  そのぶん「単独列の一意性」は保証されなくなる、というトレードオフを理解する。
- **パーティション除外は `WHERE` にパーティション列の SARGable な条件があるときだけ効く**。
  実際の実行プランの **`Actual Partition Count`** で確認する。
  逆に、パーティション列以外での単一行アクセスは **区画数ぶん遅くなる**。
- **`SWITCH` こそが本命**。データを1バイトも動かさず、行数に依存しない時間で
  **アーカイブ(スイッチアウト)** と **無停止の一括投入(スイッチイン)** ができる。
  ただし **9-3 の前提条件**(同一ファイルグループ・同一構造・アラインド・CHECK 制約)を厳守する。
- **`SPLIT` / `MERGE` + `SWITCH`** を組み合わせた **スライディングウィンドウ**が完成形。
  区画数を一定に保ちながら、毎期の入替をすべてメタデータ操作で回す。
- 保守は **区画単位**で。`REBUILD PARTITION = n` と **インクリメンタル統計**(2014+)。
  ただしインクリメンタル統計は**更新を速くする**もので、**推定精度を上げるものではない**。
- 列ストアとの併用時は **1区画あたり100万行以上**を確保する(ロウグループは区画をまたげない)。
- アンチパターン: **小さい表を分割する / パーティション列を `WHERE` に含めない設計 /
  区画を作りすぎる**。

➡ 演習: [exercises/31_partitioning.md](../exercises/31_partitioning.md)
