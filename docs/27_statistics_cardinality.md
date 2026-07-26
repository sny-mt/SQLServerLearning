# 27 統計情報とカーディナリティ推定

> **このトピックのゴール**: 「なぜオプティマイザがこのプランを選んだのか」を、
> **統計情報の中身を根拠に自分の言葉で説明できる**ようになる。
> [18 インデックスと実行プラン](18_indexes_execution_plans.md) では
> 「推定と実際が乖離するとプランが壊れる」と述べただけでした。
> この章では **その乖離がどこでどう生まれるのか** を、統計情報の実体まで降りて解剖します。
>
> **前提**: [26 DMVによる調査](26_dmv_investigation.md) までを済ませていること。
> **さらに、この章は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください。
> `dbo.OrdersBig` に **非クラスタ化インデックスが1本もない**状態がスタート地点です。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

この章で使う `dbo.OrdersBig` の性質を、**推定の観点から**もう一度確認しておきます。
以下の数値は `sample-db/03_bulk_data.sql` の生成ロジックから **計算で確定できる**ので、
「推定が当たっているか」の答え合わせに使えます。

| 列 | 値の種類数 | 分布 |
|---|---|---|
| `OrderId` | 1,000,000 | 一意(クラスタ化主キー) |
| `CustomerId` | 12 | 均等(各 83,333 行) |
| `EmployeeId` | 13 | 均等(各 76,923 行) |
| `OrderDate` | 3,653 | ほぼ均等(1日あたり約 274 行) |
| `ShipDate` | 3,660 + NULL | **NULL が 50,000 行(5%)** |
| `Status` | 2 | **`N'完了'` 950,000 / `N'保留'` 50,000(強い偏り)** |

> ⚠️ そして重要な仕掛けがひとつ。生成ロジック上、
> **`Status = N'保留'` の行と `ShipDate IS NULL` の行は完全に同じ 50,000 行**です
> (どちらも `n % 20 = 0` の行)。この2列は **100% 相関** しています。5-(c) 節の主役になります。

---

## 1. なぜ「推定行数」がすべての起点なのか

### 1-1. オプティマイザは推定行数からコストを計算する

SQL Server のオプティマイザは **コストベース**です。
同じ結果を返す複数の実行方法(候補プラン)を作り、それぞれの **コスト**を計算して、
いちばん安いものを選びます。

そのコスト計算の **唯一の入力が「各演算子を何行が流れるか」= カーディナリティ(推定行数)** です。

推定行数から、少なくとも次の 4 つが決まります。

| 決まるもの | 推定が小さいと | 推定が大きいと |
|---|---|---|
| **結合方式** | Nested Loops(内側を1行ずつ回す) | Hash Match / Merge Join |
| **結合順序** | その表を先に(駆動表に)持ってくる | 後ろに回す |
| **並列度** | 直列プラン(コストがしきい値未満) | 並列プラン |
| **メモリ許可(memory grant)** | 小さく確保 → **tempdb へ spill** | 大きく確保 → **他のクエリを待たせる** |

- メモリ許可は **推定行数 × 推定1行あたりサイズ** から決まります。
  Sort / Hash Match が使うメモリを**実行前に**確保する仕組みなので、
  **推定を外すとどうしようもありません**(実行中に増やせない)。
- 推定が小さすぎる → 確保が足りず tempdb にあふれる(**spill**)。プランに警告アイコンが出ます。
- 推定が大きすぎる → メモリを無駄に握り、他のクエリが `RESOURCE_SEMAPHORE` で待たされます。
  **「遅い1本」ではなく「サーバー全体が遅い」**という形で現れるのが厄介なところです。

### 1-2. 誤差は連鎖して増幅する

推定は **右下の葉(テーブルアクセス)から左上へ、演算子をまたいで伝播** します。

```
  Index Seek (推定 100 / 実際 50,000)     ← ここで 500 倍外した
        ↓
  Nested Loops (内側を 100 回だけ回す想定)  ← 実際は 50,000 回回る
        ↓
  Sort (100 行ぶんのメモリしか確保しない)   ← tempdb へ spill
        ↓
  SELECT
```

- **最初にズレた場所が犯人**です。左側の演算子の乖離は、たいてい **その伝播にすぎません**。
- だからプランを見るときは **いちばん右(データ取得)から左へ順に見て、
  「最初に推定と実際が大きく食い違った演算子」を探す**。これが本章の実務スキルです。

> ⚠️ **「プランが悪い」のではなく「推定が悪い」ことがほとんど**です。
> ヒントでプランを固定する前に、**なぜ推定が外れたのか**を突き止めてください。
> 原因を直せばヒントは要らなくなります。ヒントは原因を直せないときの最後の手段です。

---

## 2. 統計情報はどこにあるのか

### 2-1. 統計オブジェクトの一覧を見る

統計情報は **テーブルに付随する独立したオブジェクト**です。`sys.stats` に一覧があります。

```sql
SELECT s.stats_id                         AS 統計ID,
       s.name                             AS 統計名,
       s.auto_created                     AS 自動作成か,
       s.user_created                     AS 手動作成か,
       s.has_filter                       AS フィルターありか,
       s.filter_definition                AS フィルター条件,
       STUFF((SELECT N', ' + c.name
              FROM   sys.stats_columns AS sc
              JOIN   sys.columns       AS c
                     ON  c.object_id = sc.object_id
                     AND c.column_id = sc.column_id
              WHERE  sc.object_id = s.object_id
                AND  sc.stats_id  = s.stats_id
              ORDER  BY sc.stats_column_id
              FOR XML PATH(N'')), 1, 2, N'') AS 列,
       sp.rows                            AS 統計作成時の行数,
       sp.rows_sampled                    AS 標本行数,
       sp.steps                           AS ステップ数,
       sp.last_updated                    AS 最終更新,
       sp.modification_counter            AS 更新後の変更行数
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
ORDER  BY s.stats_id;
```

- `sys.dm_db_stats_properties` は **SQL Server 2012 SP1 以降**(2008 R2 SP2 でも利用可)。
  古い `STATS_DATE()` 関数より情報量が多いので、こちらを使ってください。
- **`modification_counter` がこの章のキー指標**です。
  「最後に統計を更新してから、この統計の先頭列が何行変更されたか」を表します。
  これが 4-2 節のしきい値を超えると自動更新が走ります。

いま実行すると、`PK_OrdersBig`(主キーのインデックスに付随する統計)だけが出るはずです。

### 2-2. 統計は 3 つの経路で生まれる

| 経路 | 名前の形 | `auto_created` | 作られるタイミング |
|---|---|---|---|
| **インデックスに付随** | インデックスと同名 | 0 | `CREATE INDEX` と同時。**必ず作られる** |
| **自動作成** | `_WA_Sys_00000006_1A14E395` | **1** | `WHERE` / `JOIN` に単独列が現れ、統計が無いとき |
| **手動作成** | 自分で決めた名前 | 0(`user_created`=1) | `CREATE STATISTICS` を実行したとき |

- 自動作成は **単一列のみ**です。**複数列統計は絶対に自動では作られません**(7 節)。
- インデックスに付随する統計は、**インデックスを消すと一緒に消えます**。
- 手動統計はインデックスとは独立に存在でき、**インデックスを増やさずに推定だけ直せる**
  という点で実務価値があります(インデックスは更新コストを伴いますが、統計はほぼ無害)。

```sql
-- 手っ取り早く一覧するだけなら
EXEC sp_helpstats N'dbo.OrdersBig', N'ALL';
```

---

## 3. `DBCC SHOW_STATISTICS` を読む(この章の核心)

### 3-1. 準備 — 明示的に統計を作る

自動作成された `_WA_Sys_...` は名前が読みにくいので、
この章では **自分で名前を付けた統計**を作って観察します。

```sql
-- 偏りのある列
CREATE STATISTICS ST_OrdersBig_Status
    ON dbo.OrdersBig (Status)
    WITH FULLSCAN;

-- ほぼ均等に分布する列
CREATE STATISTICS ST_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate)
    WITH FULLSCAN;
```

- `WITH FULLSCAN` は **全行を読んで**統計を作ります。100万行なら数秒。
  学習中は常に `FULLSCAN` にしてください。**サンプリング由来の誤差を排除**して、
  「推定の理屈」だけを観察できます。
- この章の最後(9 節)で必ず削除します。

### 3-2. 3 つの結果セットを一度に出す

```sql
DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_OrderDate)
     WITH STAT_HEADER, DENSITY_VECTOR, HISTOGRAM, NO_INFOMSGS;
```

- 第1引数の **テーブル名は必ずクォート**(`'dbo.OrdersBig'`)。統計名はクォートしてもしなくても可。
- `WITH` を省くと 3 つとも出ます。**必要なものだけ**指定すると読みやすくなります。
- `NO_INFOMSGS` を付けると「DBCC 実行が完了しました」の定型メッセージが消えます。
- 実行には **`db_owner` / `db_ddladmin` / テーブル所有者** のいずれか、
  または `SHOWPLAN` 権限(SQL Server 2012 SP1 以降)が必要です。

以下、3 つの出力を **1 つずつ**丁寧に読み解きます。

### 3-3. STAT_HEADER — 「この統計はどれだけ信用できるか」

`ST_OrdersBig_OrderDate` の出力例(値は環境により前後します):

| Name | Updated | Rows | Rows Sampled | Steps | Density | Average key length | String Index |
|---|---|---|---|---|---|---|---|
| `ST_OrdersBig_OrderDate` | `Jul 26 2026 10:12AM` | 1000000 | 1000000 | 200 | 0 | 3 | NO |

読み方は次の 4 点だけです。

**(1) `Rows` — 統計を作った時点の行数**

いまのテーブルの行数ではありません。**「統計が知っている行数」**です。
`SELECT COUNT(*)` と食い違っていたら、**統計が古い**ということ。

```sql
SELECT (SELECT COUNT(*) FROM dbo.OrdersBig)        AS 現在の行数,
       sp.rows                                     AS 統計が知っている行数,
       sp.modification_counter                     AS 変更行数,
       sp.last_updated                             AS 最終更新
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  s.name = N'ST_OrdersBig_OrderDate';
```

**(2) `Rows Sampled` — 何行を実際に読んだか(いちばん重要)**

- `Rows Sampled` = `Rows` なら **全行走査(FULLSCAN 相当)**。推定の土台として最も信頼できます。
- `Rows Sampled` が `Rows` より **ずっと小さい**なら、**サンプリング**で作られています。
- **サンプリング率 = `Rows Sampled` ÷ `Rows`**。自動更新は既定でサンプリングを使い、
  テーブルが大きくなるほど **率は下がります**(数億行のテーブルでは 1% を切ることも珍しくありません)。

**サンプリング率が低いと何が困るのか。** 統計は「読んだ行から全体を外挿」します。
1% しか読んでいなければ、**1% の中に出てこなかった値は「存在しない」ことになる**。
とくに **少数だが業務上重要な値**(`N'保留'` のようなレア値)は、
サンプリングで取りこぼされて **推定が極端に小さくなる**ことがあります。

```sql
-- サンプリング率を一覧で見る(低い統計が要注意)
SELECT s.name                                                 AS 統計名,
       sp.rows                                                AS 行数,
       sp.rows_sampled                                        AS 標本行数,
       CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
            AS DECIMAL(5, 2))                                 AS サンプリング率,
       sp.last_updated                                        AS 最終更新
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
ORDER  BY サンプリング率;
```

> ⚠️ 実務の目安: **サンプリング率が 10% を切っている大きなテーブルで、
> 推定が合わないクエリがある**なら、その統計を `WITH FULLSCAN` で更新して
> 推定が変わるかを試す価値があります。変われば原因はサンプリングです。

**(3) `Steps` — ヒストグラムのステップ数**

**最大 200**。3-5 節の主題です。

**(4) `Updated` — 最終更新日時**

- `Density` 列は **旧バージョンの遺物**で、現在のオプティマイザは使いません。
  密度は次の DENSITY_VECTOR を見ます。
- `String Index` が `YES` なら、`LIKE` の推定用に **文字列統計(トライ木)** も持っています。
  `Status` は `NVARCHAR` なので `YES` になります。
- フィルター選択された統計なら `Filter Expression` と `Unfiltered Rows` が埋まります(7 節)。
- `Persisted Sample Percent`(**2016 SP1 CU4 以降**)は、
  `PERSIST_SAMPLE_PERCENT = ON` で固定したサンプリング率です(4-3 節)。

### 3-4. DENSITY_VECTOR — 「等値条件と GROUP BY の推定に使う値」

`ST_OrdersBig_OrderDate` の出力例:

| All density | Average Length | Columns |
|---|---|---|
| 0.0002737476 | 3 | `OrderDate` |

**`All density` の定義は 1 つだけ覚えれば十分です。**

```
All density = 1 ÷ (その列の組み合わせの「重複を除いた値の個数」)
```

`OrderDate` は 3,653 種類なので `1 / 3653 = 0.0002737...`。ぴったり一致します。

**何に使われるか。** 値が **コンパイル時に分からない**等値条件の推定です。

```
推定行数 = All density × Rows
```

`OrderDate` なら `0.0002737 × 1,000,000 = 274 行`。
実際に 1 日あたり約 274 行なので、**この列では密度推定が正確に当たります**。
分布が均等だからです。

ところが `Status` は違います。

```sql
DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_Status)
     WITH DENSITY_VECTOR, NO_INFOMSGS;
```

| All density | Average Length | Columns |
|---|---|---|
| 0.5 | 6 | `Status` |

`Status` は 2 種類なので `1 / 2 = 0.5`。したがって密度推定は **1,000,000 × 0.5 = 500,000 行**。
しかし実際は `N'完了'` なら 950,000 行、`N'保留'` なら 50,000 行です。

> ⚠️ **密度は「平均」しか表現できません。**
> だから **偏った列で密度推定に頼ると必ず外れます**(`N'保留'` に対して 10 倍の過大推定)。
> 「値が分かっているなら**ヒストグラム**、分からないなら**密度**」——これが推定の二本立てです。
> 5-(b) 節で、この違いを実演します。

**密度ベクターが複数行になる場合**

複数列の統計(インデックス付随を含む)では、**先頭からの前方一致の組み合わせすべて**が並びます。

```sql
-- 例: (Status, OrderDate) のインデックスを作ると
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status_OrderDate
    ON dbo.OrdersBig (Status, OrderDate);

DBCC SHOW_STATISTICS ('dbo.OrdersBig', IX_OrdersBig_Status_OrderDate)
     WITH DENSITY_VECTOR, NO_INFOMSGS;
```

| All density | Columns |
|---|---|
| 0.5 | `Status` |
| 0.0001368738 | `Status, OrderDate` |
| 0.000001 | `Status, OrderDate, OrderId` |

- 2 行目は `(Status, OrderDate)` の組み合わせが 7,306 種類(2 × 3,653)なので `1/7306`。
- 3 行目にクラスタ化キー `OrderId` が勝手に足されているのは、
  **非クラスタ化インデックスの葉がクラスタ化キーを含む**ため(18 章 2-2 節)。
  一意になるので `1/1,000,000 = 0.000001` です。
- **`GROUP BY` の出力行数の推定にもこの密度が使われます**。
  `GROUP BY Status, OrderDate` なら `1 / 0.0001368738 = 7,306 グループ` と推定されます。

### 3-5. HISTOGRAM — 「値の分布そのもの」

```sql
DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_OrderDate)
     WITH HISTOGRAM, NO_INFOMSGS;
```

出力例(200 行のうち先頭と途中を抜粋。**値は環境により前後します**):

| RANGE_HI_KEY | RANGE_ROWS | EQ_ROWS | DISTINCT_RANGE_ROWS | AVG_RANGE_ROWS |
|---|---|---|---|---|
| `2015-01-01` | 0 | 274 | 0 | 1 |
| `2015-01-20` | 5199 | 274 | 19 | 273.63 |
| `2015-02-08` | 5199 | 274 | 19 | 273.63 |
| … | … | … | … | … |
| `2023-06-10` | 4925 | 274 | 18 | 273.61 |
| … | … | … | … | … |
| `2024-12-31` | 5199 | 274 | 19 | 273.63 |

**5 つの列の意味**(1 行 = 1 ステップ = 値の区間 1 つ):

| 列 | 意味 |
|---|---|
| **`RANGE_HI_KEY`** | この区間の **上限値そのもの**(境界値) |
| **`RANGE_ROWS`** | 上限値を **含まない**区間内(前のステップの上限 < 値 < この上限)の行数 |
| **`EQ_ROWS`** | **`RANGE_HI_KEY` ちょうど**の値を持つ行数 |
| **`DISTINCT_RANGE_ROWS`** | 区間内(上限を含まない)の **値の種類数** |
| **`AVG_RANGE_ROWS`** | `RANGE_ROWS ÷ DISTINCT_RANGE_ROWS`。**区間内の1値あたり平均行数** |

**推定の実際の計算**を追ってみましょう。

```sql
-- ① 境界値ちょうどを指定した場合 → EQ_ROWS がそのまま推定行数
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-10';   -- 推定 274

-- ② 境界値ではない値 → その値が属する区間の AVG_RANGE_ROWS が推定行数
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-05';   -- 推定 273.6…

-- ③ 範囲条件 → またぐステップの RANGE_ROWS + EQ_ROWS を足し合わせ、
--    端のステップは AVG_RANGE_ROWS で按分する
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01' AND OrderDate < '2023-07-01';       -- 推定 約 8,200
```

- **`EQ_ROWS` は境界値だけの特権**です。境界値以外は `AVG_RANGE_ROWS`(区間の平均)になります。
- つまり **ヒストグラムも「区間の中は均等」と仮定している**。
  区間内に極端な偏りがあれば、そこは表現できません。

`Status` のヒストグラムは対照的に、たった 2 行です。

```sql
DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_Status)
     WITH HISTOGRAM, NO_INFOMSGS;
```

| RANGE_HI_KEY | RANGE_ROWS | EQ_ROWS | DISTINCT_RANGE_ROWS | AVG_RANGE_ROWS |
|---|---|---|---|---|
| `保留` | 0 | 50000 | 0 | 1 |
| `完了` | 0 | 950000 | 0 | 1 |

- 値が 2 種類しかないので、**両方が境界値になり、`EQ_ROWS` に実数が入る**。
  → **リテラルで書けば推定は完璧**(50,000 / 950,000)。
- 3-4 節の密度 0.5 と見比べてください。**同じ列でも、
  値が分かるか分からないかで推定が 10 倍変わる**。これが 5-(b) 節の正体です。
- `NULL` がある列では、**ヒストグラムの最初のステップが `RANGE_HI_KEY = NULL`** になり、
  `EQ_ROWS` に NULL 行数が入ります。`ShipDate` の統計で確認できます。

### 3-6. 【最重要の制約】ヒストグラムは最大 200 ステップしか持てない

**どんなに大きなテーブルでも、ヒストグラムのステップは最大 200 個**です
(パーティション単位の増分統計を除く)。これは仕様であり、変更できません。

`OrderDate` は 3,653 種類の値を **200 ステップに圧縮**しています。

```
3,653 種類 ÷ 200 ステップ ≒ 1 ステップあたり 18.3 種類
1,000,000 行 ÷ 200 ステップ = 1 ステップあたり 5,000 行
```

だから `DISTINCT_RANGE_ROWS` が 18〜19、`RANGE_ROWS` が約 5,000 になっているのです。

**なぜこれが大きなテーブルで問題になるのか。**

- 値の種類が 200 を超えた瞬間から、**個々の値の正確な行数は失われます**。
  残るのは「この区間の平均は 274 行」という情報だけ。
- 区間の中に **1 日だけ 10 万件のセール日**があっても、
  ヒストグラムは「平均 274 行」としか言えません。→ **400 倍の過小推定**。
- 値の種類が 1,000 万ある列(顧客ID・商品コードなど)では、
  **1 ステップが 5 万種類を代表する**ことになります。**解像度は絶望的に粗い**。

**対処の考え方**(万能薬はありません):

| 対処 | 効く場面 |
|---|---|
| **フィルター選択された統計**(7-2 節) | 偏りが「特定の部分集合」に閉じているとき。**その部分集合に 200 ステップを丸ごと使える** |
| **パーティション + 増分統計** | パーティションごとに 200 ステップを持てる |
| **`OPTION (RECOMPILE)`** | 値が実行時に決まるとき。ヒストグラムは使えるようになる(ただし解像度は上がらない) |
| **一時テーブルへの実体化**([15 章](15_temp_tables.md)) | 絞り込んだ後の小さな集合に、新しい統計を作らせる |

> ⚠️ **「統計を更新したのに推定が合わない」の最大の原因がこれ**です。
> 統計が古いのではなく、**200 ステップという解像度の限界に当たっている**。
> `FULLSCAN` で更新しても解像度は上がりません。**表現できないものは表現できない**のです。

### 3-7. DMV でヒストグラムを読む(結合・絞り込みができる)

`DBCC SHOW_STATISTICS` の出力は **結果セットとして加工できません**。
`sys.dm_db_stats_histogram`(**SQL Server 2016 SP1 CU2 以降 / 2017 以降**)を使うと、
ヒストグラムを **普通の行セット**として扱えます。

```sql
-- ヒストグラムを「特に太いステップ」順に見る(偏りのある区間を探す)
SELECT TOP (10)
       h.step_number          AS ステップ番号,
       h.range_high_key       AS 上限値,
       h.range_rows           AS 区間内行数,
       h.equal_rows           AS 上限値ちょうどの行数,
       h.distinct_range_rows  AS 区間内の値の種類,
       h.average_range_rows   AS 区間内1値あたり平均
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_histogram(s.object_id, s.stats_id) AS h
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  s.name      = N'ST_OrdersBig_OrderDate'
ORDER  BY h.average_range_rows DESC;
```

- **`average_range_rows` の降順で並べる**のが実務の定石。
  **突出して大きいステップ = 推定を外しやすい危険地帯**です。
- `range_high_key` は `sql_variant` 型なので、比較や書式化には `CAST` が要ります。
- ステップ数の合計 `COUNT(*)` が 200 に張り付いていたら、3-6 節の解像度問題を疑ってください。

---

## 4. 統計はいつ作られ、いつ更新されるのか

### 4-1. データベースオプションを確認する

```sql
SELECT name                             AS DB名,
       compatibility_level              AS 互換性レベル,
       is_auto_create_stats_on          AS 統計の自動作成,
       is_auto_update_stats_on          AS 統計の自動更新,
       is_auto_update_stats_async_on    AS 統計の非同期更新
FROM   sys.databases
WHERE  name = N'SalesLearning';
```

- **`AUTO_CREATE_STATISTICS`(既定 ON)**: `WHERE` / `JOIN` に単独列が現れ、
  その列の統計が無いときに `_WA_Sys_...` を自動生成します。**原則 ON のまま**にしてください。
- **`AUTO_UPDATE_STATISTICS`(既定 ON)**: しきい値を超えた統計を、
  **その統計を使うクエリのコンパイル時に**更新します。
  → **更新を待つぶん、そのクエリだけが遅くなる**ことがあります。

### 4-2. 自動更新のしきい値(旧方式と新方式)

自動更新は `modification_counter`(2-1 節)がしきい値を超えたときに走ります。
**しきい値の計算式が SQL Server 2016 で変わりました。**

**旧方式**(互換性レベル 120 以下、または 2016 未満):

| テーブルの行数 `n` | しきい値 |
|---|---|
| 0 行 | 1 行の変更 |
| 1 〜 499 行 | 500 行の変更 |
| 500 行以上 | **500 + 0.20 × n** |

**新方式**(**SQL Server 2016 以降 かつ 互換性レベル 130 以上**。
2016 未満でもトレースフラグ 2371 で有効化可):

```
しきい値 = MIN( 旧方式のしきい値 ,  SQRT(1000 × n) )
```

`dbo.OrdersBig`(100万行)で計算してみます。

```
旧方式: 500 + 0.20 × 1,000,000               = 200,500 行
新方式: SQRT(1000 × 1,000,000) = SQRT(10^9)  ≒  31,623 行
                → MIN(200,500, 31,623)       =  31,623 行
```

**大きなテーブルほど新方式のほうが桁違いに小さくなる**のがポイントです。

| 行数 | 旧方式 | 新方式(平方根) | 実効しきい値 |
|---|---|---|---|
| 10,000 | 2,500 | 3,162 | **2,500**(旧が小さい) |
| 100,000 | 20,500 | 10,000 | **10,000** |
| 1,000,000 | 200,500 | 31,623 | **31,623** |
| 100,000,000 | 20,000,500 | 316,228 | **316,228** |

- 旧方式の「20%」は **1億行のテーブルで 2,000万行変わるまで更新されない**という意味でした。
  実運用ではまず到達しません。→ **統計が永遠に古いまま**になる。これが新方式導入の理由です。
- 逆に言うと、**互換性レベルが 120 以下のまま運用しているデータベースは、
  大きなテーブルの統計が更新されていない可能性が高い**。真っ先に疑うポイントです。

```sql
-- しきい値まであとどれくらいかを計算する(実務で有用)
SELECT s.name                                        AS 統計名,
       sp.rows                                       AS 行数,
       sp.modification_counter                       AS 変更行数,
       CAST(SQRT(1000.0 * sp.rows) AS INT)           AS 新方式しきい値,
       500 + CAST(0.20 * sp.rows AS INT)             AS 旧方式しきい値,
       CASE WHEN sp.modification_counter
                 >= CAST(SQRT(1000.0 * sp.rows) AS INT)
            THEN N'★ 更新待ち' ELSE N'—' END        AS 判定
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
ORDER  BY sp.modification_counter DESC;
```

> ⚠️ **自動更新は「時間で」ではなく「変更行数で」走ります。**
> 夜間バッチで 3 万行だけ追加するようなテーブルは、**何日たっても更新されない**ことがあります。
> 「昨日まで速かったのに今日から遅い」の相当数がこれです。

### 4-3. 手動で更新する

```sql
-- (1) テーブルのすべての統計を全行走査で更新(最も正確・最も重い)
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN;

-- (2) 特定の統計だけを更新
UPDATE STATISTICS dbo.OrdersBig ST_OrdersBig_OrderDate WITH FULLSCAN;

-- (3) サンプリング率を指定(大きなテーブルの折衷案)
UPDATE STATISTICS dbo.OrdersBig WITH SAMPLE 30 PERCENT;

-- (4) 既定のサンプリング率で更新(自動更新と同じ動作)
UPDATE STATISTICS dbo.OrdersBig;

-- (5) インデックスに付随する統計だけ / 列統計だけ
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN, INDEX;
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN, COLUMNS;
```

**サンプリング率を「固定」する**(**SQL Server 2016 SP1 CU4 以降**):

```sql
UPDATE STATISTICS dbo.OrdersBig ST_OrdersBig_OrderDate
    WITH SAMPLE 50 PERCENT, PERSIST_SAMPLE_PERCENT = ON;
```

- こうしておくと、**以後の自動更新もこの率を使い続けます**。
  「手で `FULLSCAN` したのに、次の自動更新で既定の低いサンプリングに戻ってしまった」
  という悩みへの答えです。
- 解除は `PERSIST_SAMPLE_PERCENT = OFF`(または `WITH SAMPLE 0 PERCENT, PERSIST_SAMPLE_PERCENT = OFF`)。

**`sp_updatestats`(データベース全体)**:

```sql
EXEC sp_updatestats;
```

- **1 行でも変更があった統計をすべて更新**します。手軽ですが:
  - サンプリングは **既定率**(`FULLSCAN` にはできない)。
  - **すべてのプランキャッシュが再コンパイル対象**になり、直後に CPU が跳ねます。
- 実務では、**必要な統計だけを狙って `UPDATE STATISTICS` する**か、
  メンテナンススクリプト(Ola Hallengren の `IndexOptimize` など)に任せるのが定石です。

> ⚠️ **`ALTER INDEX ... REBUILD` はインデックス統計を FULLSCAN 相当で更新します**が、
> **`REORGANIZE` は統計をまったく更新しません**。
> また REBUILD しても **列統計(`_WA_Sys_...`)は更新されません**。
> 「インデックスを再構築したから統計は最新のはず」は **半分しか正しくない**ので注意してください。

### 4-4. 非同期更新 `AUTO_UPDATE_STATISTICS_ASYNC`

既定(同期)では、しきい値を超えた統計に触れたクエリが **統計の更新を待ってから**コンパイルされます。
大きなテーブルでは、この待ちが数秒〜数十秒になることがあります。

```sql
-- 現在値を必ず先に記録してから変更する
SELECT name, is_auto_update_stats_async_on
FROM   sys.databases WHERE name = N'SalesLearning';

ALTER DATABASE SalesLearning SET AUTO_UPDATE_STATISTICS_ASYNC ON;

-- 元に戻す(既定は OFF)
ALTER DATABASE SalesLearning SET AUTO_UPDATE_STATISTICS_ASYNC OFF;
```

| | 同期(既定 OFF) | 非同期(ON) |
|---|---|---|
| そのクエリ | **待つ**(遅くなる) | **待たない** |
| 使う統計 | **新しい統計** | **古い統計**(更新はバックグラウンド) |
| 向く場面 | 精度優先。バッチ処理 | **応答時間のばらつきを嫌う OLTP** |

- **使いどころ**: 「たまに特定のクエリだけ極端に遅い(初回だけ 10 秒かかる)」
  という症状で、原因が同期統計更新だと特定できたとき。
- **副作用**: 更新が反映されるまでの間、**古い統計で作られたプランがキャッシュに載ります**。
  つまり「古い統計問題」を **少し長引かせる**トレードオフです。
- `AUTO_UPDATE_STATISTICS` が OFF だと、ASYNC を ON にしても意味がありません。
- **SQL Server 2022 以降**では、非同期更新がスキーマ変更ロックで詰まる問題に対して
  `ALTER DATABASE SCOPED CONFIGURATION SET ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY = ON`
  が使えます。

---

## 5. 【最重要】推定が外れる 7 つの典型パターン

ここからが本章の中心です。**各パターンについて「なぜ外れるか」「どう対処するか」**を
`dbo.OrdersBig` の実演で確認していきます。

各例は **実際の実行プラン(`Ctrl` + `M`)** を有効にして実行し、
演算子のツールチップで **`推定行数` と `実際の行数`** を見比べてください。

### (a) 統計情報が古い

**なぜ外れるか**: 統計が知っている `Rows` と分布が、現在のデータと食い違っているから。
とくに **大量 INSERT の直後**は、4-2 節のしきい値に届かず自動更新が走りません。

```sql
-- 症状の検出: 統計の行数と実際の行数がズレていないか
SELECT s.name                                   AS 統計名,
       sp.rows                                  AS 統計上の行数,
       (SELECT COUNT(*) FROM dbo.OrdersBig)     AS 実際の行数,
       sp.modification_counter                  AS 変更行数,
       DATEDIFF(DAY, sp.last_updated, SYSDATETIME()) AS 何日前の統計か
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig');
```

**対処**:

1. **バッチ処理の最後に明示的に `UPDATE STATISTICS`**。
   これが唯一まともな解です。「自動更新に任せる」は大量ロード直後には通用しません。
2. しきい値の計算(4-2 節)で「あとどれくらいで自動更新が走るか」を把握しておく。
3. 互換性レベルが 120 以下なら **130 以上に上げる**ことを検討する(6 節の注意付き)。

> ⚠️ **判断基準**: `modification_counter` が `rows` の 5% を超えていて、
> かつ推定が合わないクエリがあるなら、**まず `UPDATE STATISTICS ... WITH FULLSCAN` を試す**。
> これで直れば原因確定。直らなければ (b)〜(g) を疑います。

### (b) パラメータではなくローカル変数を使っている ★実演

**これが実務でいちばん多く、いちばん見落とされるパターン**です。

**なぜ外れるか**: オプティマイザは **コンパイル時に値が分かるものしかヒストグラムに引けません**。
ローカル変数の中身は **実行時にしか決まらない**ので、
ヒストグラムを諦めて **密度ベクター(平均)**にフォールバックします(3-4 節)。

```sql
-- ① リテラル: ヒストグラムの EQ_ROWS がそのまま使われる
--    推定 50,000 / 実際 50,000 → 完璧
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'保留';

-- ② ローカル変数: 密度ベクターにフォールバックする
--    推定 = All density × Rows = 0.5 × 1,000,000 = 500,000
--    実際 = 50,000 → 【10 倍の過大推定】
DECLARE @s NVARCHAR(10) = N'保留';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = @s;
```

**必ず自分の目で確認してください。** ②の Scan 演算子の推定行数が
**きっちり 500,000** になっているはずです。この数字は 3-4 節の `All density = 0.5` から
**電卓で出せる**値です。「オプティマイザの気まぐれ」ではなく、**計算された結果**なのです。

範囲条件ではさらに乱暴になります。ヒストグラムも密度も使えないので、**固定の推測値**が使われます。

```sql
-- ③ 範囲 + ローカル変数 → 固定率 30%
--    推定 300,000 / 実際 約 8,500 → 【35 倍の過大推定】
DECLARE @d DATE = '2024-12-01';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= @d;

-- ④ BETWEEN + ローカル変数 → 旧CEでは 9%(0.3 × 0.3)
--    推定 90,000 / 実際 約 8,500
DECLARE @from DATE = '2024-12-01', @to DATE = '2024-12-31';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate BETWEEN @from AND @to;
```

#### 【早見表】推定はどこから来るのか

| 条件の書き方 | 推定に使うもの | `dbo.OrdersBig` での推定 | 実際 |
|---|---|---|---|
| `Status = N'保留'`(リテラル) | **ヒストグラムの `EQ_ROWS`** | 50,000 | 50,000 |
| `Status = @s`(**ローカル変数**) | **密度 × 行数** | **500,000** | 50,000 |
| `Status = @p`(**プロシージャの引数**) | **初回実行時の値**でヒストグラム | 50,000 or 950,000 | 値による |
| `OrderDate >= @d` | **固定率 30%** | **300,000** | 約 8,500 |
| `OrderDate BETWEEN @a AND @b` | **固定率 9%**(旧CE) | **90,000** | 約 8,500 |
| `YEAR(OrderDate) = 2023` | ヒストグラム使用不可 → 推測値 | (d) 節参照 | 約 100,000 |
| テーブル変数 `@t` | **1 行**(2019+/互換150 は実行時行数) | 1 | (f) 節参照 |

> ⚠️ **「変数とパラメータは違う」**。ここを混同しないでください。
> - **ローカル変数** `DECLARE @s ...` → 値が見えない → **密度**(平均)
> - **プロシージャ/`sp_executesql` のパラメータ** → **初回の値が見える** → **ヒストグラム**
>
> 後者は「値が見えるぶん初回は正確」ですが、
> **その値で作られたプランがキャッシュされて他の値でも使われる**という別の問題を生みます。
> これが **パラメータスニッフィング**で、[28 パラメータスニッフィング詳解](28_parameter_sniffing.md)
> の主題です。**本章の (b) と 28 章は表裏一体**だと理解してください。

**対処**:

```sql
-- 対処①: OPTION (RECOMPILE) — 実行時の値を見てからコンパイルさせる(最も確実)
DECLARE @s1 NVARCHAR(10) = N'保留';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = @s1 OPTION (RECOMPILE);
-- → 推定 50,000。リテラルと同じになる。

-- 対処②: OPTIMIZE FOR — 「この値だと思ってコンパイルして」と指定する
DECLARE @s2 NVARCHAR(10) = N'保留';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = @s2
OPTION (OPTIMIZE FOR (@s2 = N'保留'));

-- 対処③: OPTIMIZE FOR UNKNOWN — 明示的に「密度で推定してくれ」と言う
--         (= 何もしないときと同じ挙動。意図を明示するために書く)
DECLARE @s3 NVARCHAR(10) = N'保留';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = @s3
OPTION (OPTIMIZE FOR UNKNOWN);
```

| 対処 | 長所 | 短所 |
|---|---|---|
| `OPTION (RECOMPILE)` | **常に正確**。値ごとに最適なプラン | 毎回コンパイル(CPU)。プランがキャッシュされないので 24 章の Query Store で追いにくい |
| `OPTIMIZE FOR (@x = 値)` | 代表値でプランを固定できる | データが変わっても追随しない。値の妥当性を人間が保証する必要 |
| `OPTIMIZE FOR UNKNOWN` | **プランが安定**する(値に左右されない) | **平均に最適化**するので、偏った列ではどの値でもそこそこ悪い |

> ⚠️ **`OPTION (RECOMPILE)` は「実行のたびにコンパイルするコスト」を払っています。**
> 秒間数千回呼ばれる OLTP クエリに付けると、**コンパイルが CPU を食い尽くします**。
> 「重いけど実行回数が少ないクエリ」に限って使うのが原則です。

### (c) 列と列に相関がある(独立の仮定)★実演

**なぜ外れるか**: 複数の `WHERE` 条件があるとき、オプティマイザは
**それぞれの選択度を掛け算**します。これは **「列どうしは独立である」という仮定**です。
現実のデータは独立ではありません。

**実演① 相関がある場合(過小推定になる)**

`dbo.OrdersBig` では `Status = N'保留'` と `ShipDate IS NULL` が **完全に同じ 50,000 行**です。

```sql
-- 推定 vs 実際 を見る
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留' AND ShipDate IS NULL;
```

計算してみましょう。

```
選択度(Status = N'保留')  = 50,000 / 1,000,000 = 0.05
選択度(ShipDate IS NULL)  = 50,000 / 1,000,000 = 0.05

旧CE(独立を仮定して単純に掛ける):
    0.05 × 0.05 × 1,000,000 = 2,500 行

新CE(指数バックオフ: 選択度の高い順に 1, 1/2, 1/4, 1/8 乗して掛ける):
    0.05 × 0.05^(1/2) × 1,000,000 = 0.05 × 0.2236 × 1,000,000 = 11,180 行

実際: 50,000 行
```

→ **旧CE で 20 倍、新CE でも 4.5 倍の過小推定**。
新CE の指数バックオフは「多少は相関があるだろう」という緩和策ですが、
**100% 相関には遠く及びません**。

過小推定の怖さは 1-1 節のとおりです。2,500 行だと思って Nested Loops を選び、
実際には 50,000 回ループする——これが「なぜか遅い」の典型的な機序です。

**実演② 本当に独立な場合(新CE は逆に過大推定になる)**

`CustomerId`(12種・均等)と `EmployeeId`(13種・均等)は、生成ロジック上 **本当に独立**です。

```sql
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  CustomerId = 5 AND EmployeeId = 7;
```

```
選択度(CustomerId = 5)  = 83,333 / 1,000,000 = 0.08333
選択度(EmployeeId = 7)  = 76,923 / 1,000,000 = 0.07692

旧CE: 0.08333 × 0.07692 × 1,000,000 = 6,410 行   ← 実際とぴったり一致
新CE: 0.07692 × 0.08333^(1/2) × 1,000,000
    = 0.07692 × 0.28868 × 1,000,000 = 22,206 行   ← 3.5 倍の過大推定

実際: 1,000,000 / (12 × 13) = 6,410 行
```

> ⚠️ **これは新CE が「劣化」した例です。**
> 「新しいほうが常に良い」わけではない、という何よりの証拠になります。
> 独立仮定(旧CE)は **本当に独立なら正しい**。指数バックオフ(新CE)は
> **相関があるときはマシだが、独立なときは過大推定する**。
> **どちらが自分のデータに合うかは、測ってみるまで分かりません**。これが 6 節の主題です。

**対処**:

```sql
-- 対処①: 複数列統計を作る(等値条件が全列に揃うときに効く)
CREATE STATISTICS ST_OrdersBig_Cust_Emp
    ON dbo.OrdersBig (CustomerId, EmployeeId)
    WITH FULLSCAN;

-- 密度ベクターの (CustomerId, EmployeeId) 行を見る
DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_Cust_Emp)
     WITH DENSITY_VECTOR, NO_INFOMSGS;
-- All density = 1 / 156 = 0.006410…
-- → 推定 = 0.006410 × 1,000,000 = 6,410 行。実際と一致する。

SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  CustomerId = 5 AND EmployeeId = 7;   -- 推定が 6,410 に改善する
```

- **複数列統計の密度ベクターは、条件が「全列に等値で揃った」ときだけ使われます**。
  `CustomerId = 5 AND EmployeeId > 7` のように片方が範囲だと使えません。
- ヒストグラムは **先頭列にしか作られない**ことに注意(7-1 節)。

```sql
-- 対処②: フィルター選択された統計(条件が固定的なとき。7-2 節)

-- 対処③: 相関を「最小選択度を採用する」ヒントで教える(最後の手段。2016 SP1+)
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留' AND ShipDate IS NULL
OPTION (USE HINT('ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES'));
-- → 掛け算をやめ、最も小さい選択度 0.05 をそのまま採用する
--    推定 = 0.05 × 1,000,000 = 50,000 行。実際と一致する。
```

- `ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES` は
  **「列は完全に相関していると仮定せよ」**という指示です(トレースフラグ 4137 相当)。
- 使えるヒント名の一覧は DMV で確認できます。**推測せずに引いてください**。

```sql
SELECT name, description FROM sys.dm_exec_valid_use_hints ORDER BY name;
```

> ⚠️ **`OPTION (RECOMPILE)` では相関問題は直りません**。
> RECOMPILE が解決するのは「値が見えない」問題((b) 節)だけです。
> **値が見えていても、列どうしの関係は統計に書かれていない**ので、
> 掛け算は掛け算のまま。ここを取り違えると延々と迷走します。

### (d) 列に式や関数を掛けている

**なぜ外れるか**: ヒストグラムは **`OrderDate` の値そのもの**を並べたものです。
`YEAR(OrderDate)` の分布はどこにも書かれていません。
オプティマイザは統計を引けず、**固定の推測値(guess)にフォールバック**します。

```sql
-- ① 関数を掛けている → 統計が使えない
SELECT COUNT(*) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2023;

-- ② 同じ結果の SARGable な書き方 → ヒストグラムが使える
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01';
```

**実際のプランで①と②の推定行数を比べてください。** ②はヒストグラムから約 100,000 行と
正確に見積もりますが、①は **実際とかけ離れた固定値**になります
(具体的な率は CE のバージョンで異なるので、**必ず自分の環境で実測**してください)。

これは 18 章 4 節の **SARGability** と同じ話に見えますが、**被害は 2 段構え**です。

| 被害 | 内容 |
|---|---|
| **① インデックスが使えない** | 18 章で学んだ問題。Scan になる |
| **② 推定が壊れる** | **本章の問題**。結合方式・結合順序・メモリ許可が全部おかしくなる |

**インデックスが無い列でも②の被害は発生します**。ここが 18 章との違いです。
「どうせインデックスが無いから `YEAR()` でいい」は誤りなのです。

**対処**:

1. **書き換える**(最善・無コスト)。`>= / <` の範囲条件にする。
2. **永続化された計算列 + 統計**。書き換えられない場合の定石です。

```sql
-- 計算列を作ると、その列に統計を作れる(= 分布を教えられる)
ALTER TABLE dbo.OrdersBig ADD 受注年 AS YEAR(OrderDate) PERSISTED;
CREATE STATISTICS ST_OrdersBig_受注年 ON dbo.OrdersBig (受注年) WITH FULLSCAN;

-- クエリを書き換えなくても、式が計算列の定義と一致すればマッチングされる
SELECT COUNT(*) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2023;
```

- **`PERSISTED` でなくても統計は作れます**が、
  インデックスを張るには決定性・精度の条件があるため `PERSISTED` が無難です。
- **列を追加するのでテーブル定義が変わります**。本番投入前に影響を確認してください。
  この章の 9 節で必ず削除します。

3. `sp_executesql` で定数を渡すなど、**式を条件から追い出す**。

### (e) 昇順キー問題(統計の範囲外)

**なぜ外れるか**: `OrderDate` や `IDENTITY` の主キーのように、
**常に増える方向にデータが追加される列**では、
新しい行の値が **ヒストグラムの最大値(`RANGE_HI_KEY` の最後)より大きく**なります。

統計は「そんな値は存在しない」と言うので、**推定は 1 行**になります(旧CE)。
そして 4-2 節のしきい値(100万行なら 31,623 行)に届かないうちは **自動更新も走りません**。

```
ヒストグラムの最終ステップ: RANGE_HI_KEY = 2024-12-31
              ↓
今日 INSERT された 5,000 行: OrderDate = 2025-01-15
              ↓
WHERE OrderDate >= '2025-01-01'  →  統計には無い値  →  推定 1 行
              ↓
「1 行しか返らない」前提で Nested Loops が選ばれる  →  実際は 5,000 回ループ
```

**この症状は「直近データを検索するクエリだけが遅い」という形で現れます。**
月初・日次バッチの直後に発生し、統計が更新されると勝手に直るので、
**再現しにくく原因を掴みにくい**のが厄介なところです。

**実演**(`ROLLBACK` で必ず元に戻します):

```sql
-- 事前に統計を最新にして、ヒストグラムの上限が 2024-12-31 であることを確認
UPDATE STATISTICS dbo.OrdersBig ST_OrdersBig_OrderDate WITH FULLSCAN;

SELECT MAX(CAST(h.range_high_key AS DATE)) AS ヒストグラムの最大値
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_histogram(s.object_id, s.stats_id) AS h
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  s.name      = N'ST_OrdersBig_OrderDate';

BEGIN TRAN;

    -- 統計の範囲外(2025年)のデータを 5,000 行だけ追加する
    -- 5,000 < しきい値 31,623 なので、自動更新は走らない
    INSERT INTO dbo.OrdersBig (OrderId, CustomerId, EmployeeId, OrderDate, ShipDate, Status, Amount)
    SELECT TOP (5000)
           1000000 + ROW_NUMBER() OVER (ORDER BY OrderId),
           CustomerId, EmployeeId,
           DATEADD(DAY, 30, '2025-01-01'),
           NULL, N'保留', Amount
    FROM   dbo.OrdersBig
    ORDER  BY OrderId;

    -- 変更行数がしきい値未満であることを確認
    SELECT sp.rows, sp.modification_counter,
           CAST(SQRT(1000.0 * sp.rows) AS INT) AS しきい値
    FROM   sys.stats AS s
    CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
      AND  s.name      = N'ST_OrdersBig_OrderDate';

    -- ★ 実際のプランで推定行数を確認する
    --   旧CE(互換110以下): 推定 1 行 / 実際 5,000 行
    --   新CE(互換120以上): 変更行数を加味して多少改善するが、やはり実際とはズレる
    SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= '2025-01-01';

ROLLBACK;   -- ★必ずロールバックする

-- ロールバック後、統計のカウンタを整える
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN;
```

**対処**:

| 対処 | 内容 | 注意 |
|---|---|---|
| **統計を明示的に更新する** | バッチ処理の最後に `UPDATE STATISTICS`。**これが本命** | 重いテーブルでは対象を絞る |
| **新CE を使う** | 互換性レベル 120 以上。範囲外を「変更行数」から推定する | 完全ではない。6 節 |
| **`OPTION (RECOMPILE)`** | 直らない。値は見えているが **ヒストグラムに無い**のが問題 | **効きません** |
| **トレースフラグ 2389 / 2390** | 旧CE 用。列が「昇順」と判定されると範囲外を推定 | **グローバル設定**。3 回の統計更新で「昇順」と認定される |
| **トレースフラグ 4139** | 新CE 用。昇順判定に関係なく範囲外推定を有効化 | 2014 SP1 CU/2016 以降。本番では十分な検証が必要 |

> ⚠️ **トレースフラグはサーバー全体(または セッション)に効きます**。
> 学習環境以外では、必ず影響範囲を確認してから使ってください。
> **まずは「バッチの最後に統計を更新する」で解決できないかを検討する**のが正しい順序です。

### (f) テーブル変数を使っている

[15 一時テーブルとテーブル変数](15_temp_tables.md) 6 節で扱った内容の再確認です。

**なぜ外れるか**: **テーブル変数は統計情報を一切持ちません**。
ヒストグラムも密度もないので、オプティマイザは **1 行**と推定します。

```sql
DECLARE @T TABLE (OrderId INT PRIMARY KEY, CustomerId INT, Amount DECIMAL(12, 0));

INSERT INTO @T
SELECT OrderId, CustomerId, Amount FROM dbo.OrdersBig WHERE OrderDate >= '2024-01-01';
-- 約 100,000 行入る

-- 推定 1 行 / 実際 約 100,000 行 → 【10万倍の過小推定】
SELECT COUNT(*) FROM @T AS t JOIN dbo.Customers AS c ON c.CustomerId = t.CustomerId;
```

**対処と、その限界**:

| 対処 | 効果 | 限界 |
|---|---|---|
| **一時テーブル `#t` に変える** | **統計が作られる**。ヒストグラムも密度も手に入る | tempdb への書き込みコスト |
| **SQL Server 2019+ / 互換性レベル 150** | **テーブル変数の遅延コンパイル**で **行数**は正確になる | **行数だけ**。**分布(ヒストグラム)は依然として無い** |
| **`OPTION (RECOMPILE)`** | 2017 以前でも、その文だけ実際の行数でコンパイル | 同上。分布は分からない |

> ⚠️ **2019 の遅延コンパイルを「テーブル変数問題は解決した」と読んではいけません。**
> 直るのは 1-1 節の表でいう **メモリ許可と結合方式の一部**です。
> 「テーブル変数の `Status` 列で絞る」ような **分布に依存する推定は改善しません**。
> 統計が要るなら一時テーブル、という原則は 2019 以降も変わりません。

### (g) 複数列統計が無い

(c) 節の裏返しですが、**独立した問題として認識しておく価値があります**。

**なぜ外れるか**: **自動作成される統計は単一列だけ**です(2-2 節)。
複数列にまたがる分布は、**誰かが明示的に `CREATE STATISTICS` するまで存在しません**。

「インデックスを作れば付随して統計もできる」のは事実ですが、
**インデックスは更新コストとディスクを消費します**。
**推定を直したいだけなら、統計だけを作るほうがはるかに安い**のです。

```sql
-- 「複数列の条件がよく出てくるのに、複数列統計もインデックスも無い列の組み合わせ」を探す
SELECT s.name                             AS 統計名,
       s.auto_created                     AS 自動作成か,
       COUNT(*)                           AS 列数
FROM   sys.stats AS s
JOIN   sys.stats_columns AS sc
       ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
GROUP  BY s.name, s.auto_created
ORDER  BY 列数 DESC, s.name;
```

- **列数がすべて 1 なら、複数列統計は 1 つも無い**ということです。
- 実務では **「よく一緒に `WHERE` に出る列の組み合わせ」** を [26 章](26_dmv_investigation.md) の
  DMV や [24 章] の Query Store で洗い出し、そこに複数列統計を用意します。

**対処**: 7-1 節へ。

---

## 6. カーディナリティ推定モデル(CE)— バージョンアップでプランが変わる正体

### 6-1. 旧CE と 新CE

SQL Server 2014 で、**カーディナリティ推定エンジンが 15 年ぶりに書き直されました**。

| | **旧CE(レガシーCE)** | **新CE** |
|---|---|---|
| モデル版 | **70**(SQL Server 7.0 由来) | **120 / 130 / 140 / 150 / 160** |
| 使われる互換性レベル | **110 以下**(SQL Server 2012 相当まで) | **120 以上**(SQL Server 2014 以降) |
| 複数条件 | **独立を仮定して単純に掛ける** | **指数バックオフ**(1, 1/2, 1/4, 1/8 乗) |
| 結合の包含 | **単純包含**(結合前にフィルタが効いた前提) | **基本包含**(フィルタ前の基本テーブルで包含を判定) |
| 昇順キーの範囲外 | **1 行**と推定 | 変更行数を加味して推定 |

**どちらが「良い」ということはありません。** 5-(c) 節で見たとおり、
**相関があるデータでは新CE が有利、本当に独立なデータでは旧CE が有利**です。

> ⚠️ **「SQL Server をバージョンアップしたら特定のクエリだけ激遅になった」の
> もっとも多い原因が、互換性レベルの変更に伴う CE の切り替わりです。**
> データもインデックスもクエリも変えていないのに、**推定モデルだけが変わった**。
> バージョンアップ後の性能退行を調査するときは、**まずここを疑ってください**。

### 6-2. いま自分のクエリがどちらの CE を使っているかを知る

**実行プランの XML に必ず書いてあります。**

```sql
SET STATISTICS XML ON;
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'保留';
SET STATISTICS XML OFF;
```

返ってきた XML(SSMS ではリンクをクリック → 右クリック → 「実行プラン XML の表示」)の
`<StmtSimple>` 要素に次の属性があります。

```xml
<StmtSimple ... CardinalityEstimationModelVersion="150" ...>
```

| 値 | 意味 |
|---|---|
| `70` | **旧CE** |
| `120` | SQL Server 2014 の新CE |
| `130` | SQL Server 2016 |
| `140` | SQL Server 2017 |
| `150` | SQL Server 2019 |
| `160` | SQL Server 2022 |

`70` と表示されたら旧CE、それ以外は新CE です。**推測せず、この属性で確認してください。**

### 6-3. 旧CE に戻す 3 つの方法(安全な順に)

★★★ **安全方針**: 以下はいずれも **元に戻す手順とセット**で示します。
**必ず先に現在値を確認して記録してから**変更してください。

#### 【安全確認】現在値を記録する

```sql
-- ① 互換性レベル(★この値をメモしてください)
SELECT name AS DB名, compatibility_level AS 互換性レベル
FROM   sys.databases
WHERE  name = N'SalesLearning';

-- ② データベーススコープ構成(★この値もメモしてください)
SELECT [name]                AS 構成名,
       [value]               AS 現在値,
       [value_for_secondary] AS セカンダリ用
FROM   sys.database_scoped_configurations
WHERE  [name] IN (N'LEGACY_CARDINALITY_ESTIMATION',
                  N'PARAMETER_SNIFFING',
                  N'QUERY_OPTIMIZER_HOTFIXES');
```

#### 方法① クエリ単位のヒント(**いちばん安全。まずこれ**)

```sql
-- このクエリだけ旧CE でコンパイルする(SQL Server 2016 SP1 以降)
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留' AND ShipDate IS NULL
OPTION (USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION'));
```

- **影響範囲がその 1 文だけ**。他のクエリ・他のユーザーに一切影響しません。
- **元に戻す手順は「ヒントを消す」だけ**。事故が起きようがありません。
- 特別な権限も不要です(古い `OPTION (QUERYTRACEON 9481)` は `sysadmin` が必要でした)。
- 5-(c) 節の相関の例で試すと、推定が 11,180 → 2,500 に変わるのが確認できます。

**実務でも、原因が特定できた 1 本のクエリを救うならこれが第一選択**です。

#### 方法② データベーススコープ構成(DB 単位)

```sql
-- 【変更前に】現在値を必ず確認する(上の【安全確認】を実行済みであること)

-- 旧CE をデータベース全体で使う
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;

-- ...検証...

-- ★元に戻す(既定値は OFF)
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = OFF;

-- 戻ったことを確認
SELECT [name], [value] FROM sys.database_scoped_configurations
WHERE  [name] = N'LEGACY_CARDINALITY_ESTIMATION';
```

- **SQL Server 2016 以降**。`ALTER ANY DATABASE SCOPED CONFIGURATION` 権限が必要です。
- **副作用: このデータベースのプランキャッシュがクリアされます。**
  本番で実行すると **直後に全クエリが再コンパイル**され、CPU が跳ねます。
- **互換性レベルは 130+ のまま、CE だけ旧に戻せる**のが利点です。
  「新機能は使いたいが CE は変えたくない」というバージョンアップ戦略で使われます。

#### 方法③ 互換性レベル(**影響が最も大きい。学習環境のみ**)

```sql
-- 【変更前に】現在値を必ずメモする
SELECT name, compatibility_level FROM sys.databases WHERE name = N'SalesLearning';
-- 例: 150 だった、とメモする

-- 旧CE になるレベルまで下げる
ALTER DATABASE SalesLearning SET COMPATIBILITY_LEVEL = 110;

-- ...検証...(CardinalityEstimationModelVersion="70" になることを確認)

-- ★元に戻す(必ず、メモした元の値に戻すこと)
ALTER DATABASE SalesLearning SET COMPATIBILITY_LEVEL = 150;

SELECT name, compatibility_level FROM sys.databases WHERE name = N'SalesLearning';
```

互換性レベルとバージョンの対応:

| 互換性レベル | SQL Server | CE |
|---|---|---|
| 100 | 2008 / 2008 R2 | 旧 |
| 110 | 2012 | 旧 |
| **120** | 2014 | **新(境目)** |
| 130 | 2016 | 新 |
| 140 | 2017 | 新 |
| 150 | 2019 | 新 |
| 160 | 2022 | 新 |

> ⚠️ **互換性レベルを下げると CE 以外も一緒に変わります。**
> 統計の自動更新しきい値(4-2 節)、テーブル変数の遅延コンパイル、
> インテリジェントクエリ処理(適応結合・メモリ許可フィードバックなど)が
> **まとめて無効化**されます。**CE だけを変えたいなら方法②を使ってください。**
> この章の 9 節で、必ず元の値に戻したことを確認します。

### 6-4. バージョンアップ時の実務的な進め方

1. **上げる前に** Query Store([24 章])を有効にし、現行のプランと実行時間を採取する。
2. 互換性レベルは **古いまま**でバージョンアップする(これは公式に推奨されている手順)。
3. Query Store を有効にしたまま **互換性レベルを上げる**。
4. 退行したクエリを Query Store の「退行したクエリ」から特定する。
5. 退行したクエリだけを **方法①のヒント**で救う。全体を巻き戻さない。

---

## 7. 複数列統計とフィルター選択された統計

### 7-1. 複数列統計

```sql
CREATE STATISTICS ST_OrdersBig_Cust_Emp
    ON dbo.OrdersBig (CustomerId, EmployeeId)
    WITH FULLSCAN;
```

**効くところと効かないところを正確に押さえてください。**

| | 内容 |
|---|---|
| **ヒストグラム** | **先頭列(`CustomerId`)にしか作られない** |
| **密度ベクター** | `(CustomerId)` と `(CustomerId, EmployeeId)` の両方 |
| **効く条件** | **すべての列に等値条件**が揃ったとき(密度ベクターが使われる) |
| **効かない条件** | 片方が範囲条件 / 片方の条件が無い / 順序違いは関係ない(等値なら順序不問) |

- 列の順序は、**ヒストグラムをどちらの列に作りたいか**で決めます。
  単独でも検索される列を先頭にすると無駄がありません。
- **インデックスを作れば統計は付随します**が、逆は成り立ちません。
  **推定だけ直したいなら統計だけを作る**。これは覚えておく価値のあるテクニックです。

### 7-2. フィルター選択された統計(filtered statistics)

**「テーブルの一部分だけ」を対象にした統計**です。
3-6 節の 200 ステップ制約に対する、もっとも直接的な武器になります。

```sql
CREATE STATISTICS ST_OrdersBig_Pending_OrderDate
    ON dbo.OrdersBig (OrderDate)
    WHERE Status = N'保留'
    WITH FULLSCAN;

DBCC SHOW_STATISTICS ('dbo.OrdersBig', ST_OrdersBig_Pending_OrderDate)
     WITH STAT_HEADER, NO_INFOMSGS;
```

STAT_HEADER にフィルター統計だけの列が現れます。

| Rows | Rows Sampled | Steps | Filter Expression | Unfiltered Rows |
|---|---|---|---|---|
| 50000 | 50000 | 200 | `([Status]=N'保留')` | 1000000 |

- **`Rows` はフィルター適用後の行数(50,000)**。`Unfiltered Rows` が元の 1,000,000。
- **200 ステップを 50,000 行のためだけに使える** → 該当部分の解像度が上がります。

**使われるための条件が 2 つあります。ここが落とし穴です。**

1. **クエリの条件が、統計のフィルター条件を論理的に含んでいること**。
   `WHERE Status = N'保留' AND ...` ならOK。`WHERE Status = @s` ではダメ。
2. **コンパイル時にそれが判定できること**。
   パラメータ化されていると判定できないので、**`OPTION (RECOMPILE)` が必要**になりがちです。

```sql
-- フィルター統計が使われる形
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留'
  AND  OrderDate >= '2024-01-01' AND OrderDate < '2024-02-01'
OPTION (RECOMPILE);
```

> ⚠️ **`dbo.OrdersBig` は人工データで分布が均等**なため、
> この例でフィルター統計の効果を数字で実感するのは難しいはずです。
> **効果が出るのは「部分集合だけ分布が大きく違う」実データ**です。例えば:
> 「解約済み顧客だけ注文日が 2020 年以前に偏っている」「特定店舗だけ客単価が 10 倍」など。
> **本章では「作り方」と「STAT_HEADER の読み方」を身につけてください。**

- **フィルター統計は自動更新のしきい値の判定が全体の変更行数ベース**になるため、
  **更新されにくい**という弱点があります。定期的な明示更新を検討してください。

---

## 8. 推定と実際を突き合わせる手順と判断基準

### 8-1. 手順

**① SSMS で実際の実行プランを見る(基本)**

- `Ctrl` + `M` を ON にして実行。演算子にマウスを乗せてツールチップを見る。
- 見る項目: **`推定行数`** と **`実際の行数`**、そして **`実行回数`**。

> ⚠️ **SSMS 18 以降では「実際の行数(すべての実行)」と
> 「推定行数(実行あたり)」が並んでいます。単位が違います。**
> Nested Loops の内側にある演算子は何度も実行されるので、
> **比較するには `実際の行数 ÷ 実行回数` を計算しなければなりません**。
> ここを忘れて「1000 倍ずれている!」と早合点するのは、非常によくある間違いです。

**② テキストで確認する(SSMS が使えないとき)**

```sql
SET STATISTICS XML ON;

SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'保留' AND ShipDate IS NULL;

SET STATISTICS XML OFF;
```

XML の中の `EstimateRows`(推定)と `ActualRows`(実際)を見比べます。
`CardinalityEstimationModelVersion` も同じ XML にあります(6-2 節)。

**③ メモリ許可と spill を確認する**

XML のルート要素付近にある `MemoryGrantInfo` を見ます。

| 属性 | 意味 |
|---|---|
| `SerialRequiredMemory` | 最低限必要と見積もったメモリ |
| `GrantedMemory` | 実際に確保されたメモリ |
| `MaxUsedMemory` | 実際に使ったメモリ(**2016 SP1 以降**) |

- `GrantedMemory` に対して `MaxUsedMemory` が **極端に小さい** → **過大推定**。
  メモリを無駄に握って他のクエリを待たせています。
- プランに **Sort / Hash Match の警告アイコン**(「tempdb に書き込みました」)が出ていたら
  → **過小推定**による spill。

**④ 本番で動いているクエリのプランを取る**

```sql
-- 実行中のクエリの「実際の」プランを取得(SQL Server 2016 SP1 以降、軽量プロファイリングが必要)
SELECT r.session_id, r.status, r.command, qsx.query_plan
FROM   sys.dm_exec_requests AS r
CROSS  APPLY sys.dm_exec_query_statistics_xml(r.session_id) AS qsx
WHERE  r.session_id <> @@SPID;
```

- 詳しくは [26 DMVによる調査](26_dmv_investigation.md) を参照してください。

### 8-2. 判断基準 — 何倍ずれたら疑うか

**実務的な目安**です(絶対的な基準ではなく、**調査の優先順位を決めるための線引き**)。

| 乖離 | 判断 | 典型的な影響 |
|---|---|---|
| **2 倍未満** | **正常**。追いかける価値なし | 実質的な影響はほぼ無い |
| **2 〜 10 倍** | **要観察**。他に原因が無ければ調べる | 結合方式が変わりうる境界 |
| **10 〜 100 倍** | **★疑う**。原因を特定すべき | 結合方式が誤る。spill が起きる |
| **100 倍以上** | **★★確実に問題**。最優先で対処 | プランが根本的に破綻している |
| **推定 1 行 vs 実際が 4 桁以上** | **★★★最悪パターン** | Nested Loops 地獄。(e)(f) を疑う |

**あわせて見るべき 3 点**:

1. **どちら向きにずれているか**
   - **過小推定** → Nested Loops、メモリ不足、spill。**症状は「遅い」**。
   - **過大推定** → 不要な Hash / 並列化、メモリの独占。**症状は「サーバー全体が重い」**。
     こちらのほうが発見が遅れます。
2. **最初にずれた演算子はどこか**(1-2 節)。右から左へ見て、最初の犯人を特定する。
3. **その演算子が全体のコストに占める割合**。
   1,000 倍ずれていても、行数が 10 → 10,000 なら実害はありません。
   **「倍率」と「絶対行数」の両方**を見てください。

### 8-3. 原因の切り分けフローチャート

推定が合わないとわかったら、**この順に潰していきます**。

| 手順 | 確認すること | Yes なら |
|---|---|---|
| 1 | 統計が古い?(`modification_counter` / `last_updated`) | → **(a)**。`UPDATE STATISTICS ... WITH FULLSCAN` |
| 2 | 条件に **ローカル変数**を使っている? | → **(b)**。`OPTION (RECOMPILE)` で推定が変わるか試す |
| 3 | 条件の列が **関数や式で包まれている**? | → **(d)**。書き換える / 計算列 + 統計 |
| 4 | **テーブル変数**を使っている? | → **(f)**。一時テーブルに変える |
| 5 | 検索値が **統計のヒストグラム範囲外**(最新データ)? | → **(e)**。統計更新をバッチに組み込む |
| 6 | `WHERE` に **複数列の条件**がある? | → **(c)(g)**。複数列統計 / フィルター統計 |
| 7 | サンプリング率が低い?(`rows_sampled / rows`) | → **(a)**。`FULLSCAN` で更新して変化を見る |
| 8 | 値の種類が **200 を大きく超えている**? | → **3-6 節**。解像度の限界。フィルター統計や実体化を検討 |
| 9 | ここまで全部 No | → **CE の違い(6 節)** を疑う。`FORCE_LEGACY_CARDINALITY_ESTIMATION` で変わるか試す |

> ⚠️ **ヒントでプランを固定するのは、1〜9 をすべて試したあと**です。
> ヒントは「なぜ外れたか」を隠してしまうので、**根本原因が残り続けます**。
> データが変わったときに、また別の形で壊れます。

---

## 9. 後片付け(必ず実行)

この章で作ったものをすべて削除し、`dbo.OrdersBig` を初期状態に戻します。

```sql
-- (1) この章で作った統計を削除する
--     ★ DROP STATISTICS には IF EXISTS が無いので、存在確認で囲む
IF EXISTS (SELECT 1 FROM sys.stats
           WHERE object_id = OBJECT_ID('dbo.OrdersBig') AND name = N'ST_OrdersBig_Status')
    DROP STATISTICS dbo.OrdersBig.ST_OrdersBig_Status;

IF EXISTS (SELECT 1 FROM sys.stats
           WHERE object_id = OBJECT_ID('dbo.OrdersBig') AND name = N'ST_OrdersBig_OrderDate')
    DROP STATISTICS dbo.OrdersBig.ST_OrdersBig_OrderDate;

IF EXISTS (SELECT 1 FROM sys.stats
           WHERE object_id = OBJECT_ID('dbo.OrdersBig') AND name = N'ST_OrdersBig_Cust_Emp')
    DROP STATISTICS dbo.OrdersBig.ST_OrdersBig_Cust_Emp;

IF EXISTS (SELECT 1 FROM sys.stats
           WHERE object_id = OBJECT_ID('dbo.OrdersBig') AND name = N'ST_OrdersBig_Pending_OrderDate')
    DROP STATISTICS dbo.OrdersBig.ST_OrdersBig_Pending_OrderDate;

-- (2) この章で作ったインデックスを削除する
DROP INDEX IF EXISTS IX_OrdersBig_Status_OrderDate ON dbo.OrdersBig;

-- (3) 計算列を削除する(5-(d) 節で作った場合)
IF EXISTS (SELECT 1 FROM sys.stats
           WHERE object_id = OBJECT_ID('dbo.OrdersBig') AND name = N'ST_OrdersBig_受注年')
    DROP STATISTICS dbo.OrdersBig.ST_OrdersBig_受注年;

IF COL_LENGTH('dbo.OrdersBig', N'受注年') IS NOT NULL
    ALTER TABLE dbo.OrdersBig DROP COLUMN 受注年;

-- (4) 設定を元に戻したか確認する ★最重要
SELECT name                          AS DB名,
       compatibility_level           AS 互換性レベル,     -- 章の最初にメモした値と同じか
       is_auto_create_stats_on       AS 統計の自動作成,   -- 1 であること
       is_auto_update_stats_on       AS 統計の自動更新,   -- 1 であること
       is_auto_update_stats_async_on AS 非同期更新        -- 元の値(通常 0)であること
FROM   sys.databases
WHERE  name = N'SalesLearning';

SELECT [name] AS 構成名, [value] AS 現在値
FROM   sys.database_scoped_configurations
WHERE  [name] = N'LEGACY_CARDINALITY_ESTIMATION';        -- 0(OFF)であること

-- (5) 残っている統計を確認する(PK_OrdersBig と _WA_Sys_... だけになっていれば OK)
SELECT s.name AS 統計名, s.auto_created AS 自動作成か, s.user_created AS 手動作成か
FROM   sys.stats AS s
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig')
ORDER  BY s.stats_id;

-- (6) 統計を最新の状態に戻す
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN;
```

- 自動作成された `_WA_Sys_...` は残っていて構いません(害はありません)。
  気になるなら同じ要領で `DROP STATISTICS` できます。
- **設定を戻し忘れると、以降のすべての章の計測結果が変わります。** (4) を必ず実行してください。

> ⚠️ 途中でおかしくなったら、`sample-db/03_bulk_data.sql` を再実行すれば
> `dbo.OrdersBig` を丸ごと作り直せます(統計・インデックス・計算列もすべて消えます)。
> ただし **互換性レベルとデータベーススコープ構成は戻りません**。(4) で必ず確認してください。

---

## よくあるつまずき

- **「統計を更新すれば直る」と思い込む** → 直るのは (a) と一部の (e) だけ。
  (b) ローカル変数、(c) 相関、(d) 式、(f) テーブル変数は **統計を更新しても一切直りません**。
  8-3 節のフローで切り分けること。
- **`OPTION (RECOMPILE)` を万能薬だと思う** → 直るのは「**値が見えない**」問題だけ。
  相関(c)・式(d)・ヒストグラム範囲外(e)には **効きません**。
- **`DBCC SHOW_STATISTICS` の `Density` 列を見てしまう** → STAT_HEADER の `Density` は
  **旧バージョンの遺物**で現在は使われません。密度は **DENSITY_VECTOR の `All density`** を見る。
- **`Rows` を「現在の行数」だと思う** → **統計を作った時点の行数**。
  `COUNT(*)` と比べてズレていたら、それ自体が「統計が古い」証拠。
- **推定と実際を単位を揃えずに比べる** → ループの内側の演算子は
  **`実際の行数 ÷ 実行回数`** に直してから比べる(8-1 節)。
- **過大推定を軽視する** → 過小推定は「そのクエリが遅い」で済みますが、
  過大推定は **メモリを独占して他人を巻き添え**にします。むしろ発見が難しい。
- **ヒストグラムのステップを増やそうとする** → **200 が上限で変更できません**。
  解像度が足りないならフィルター統計・パーティション・実体化を検討する。
- **`ALTER INDEX ... REORGANIZE` で統計が更新されると思う** → **更新されません**。
  `REBUILD` はインデックス統計だけを更新し、**列統計は更新しません**。
- **互換性レベルを下げて「解決」してしまう** → CE 以外の機能もまとめて古くなります。
  CE だけを戻したいなら **データベーススコープ構成**、
  1 本だけ救いたいなら **`USE HINT`** を使う(6-3 節)。
- **設定を戻し忘れる** → 互換性レベル・スコープ構成・トレースフラグは
  **必ず現在値を記録してから変更し、検証後に戻す**。

## この章のまとめ

- オプティマイザは **推定行数(カーディナリティ)からコストを計算**し、
  **結合方式・結合順序・並列度・メモリ許可**を決める。
  **推定を外すと、そこから先が連鎖的に全部外れる**。
- 統計情報は 3 つの結果セットで読む。
  - **STAT_HEADER**: `Rows` は **統計作成時**の行数。**`Rows Sampled / Rows` = サンプリング率**が
    低いと推定が甘くなる。`Steps` は最大 **200**。
  - **DENSITY_VECTOR**: **`All density` = 1 ÷ 値の種類数**。
    **値が分からない等値条件**と **`GROUP BY` の推定**に使われる。**平均しか表現できない**。
  - **HISTOGRAM**: `RANGE_HI_KEY`(境界値)/ `EQ_ROWS`(境界値ちょうど)/
    `RANGE_ROWS`(区間内)/ `DISTINCT_RANGE_ROWS` / `AVG_RANGE_ROWS`(区間内平均)。
    **境界値なら正確、それ以外は区間平均**。
- **ヒストグラムは最大 200 ステップ**。大きなテーブルでは **解像度が根本的に足りない**。
  `FULLSCAN` で更新しても解像度は上がらない。
- 自動更新のしきい値は **旧: 500 + 20%**、**2016+/互換130+: `MIN(旧, SQRT(1000 × 行数))`**。
  100万行なら **31,623 行**。`sys.dm_db_stats_properties` の `modification_counter` で監視する。
- **推定が外れる 7 パターン**:
  **(a)** 古い統計 / **(b)** **ローカル変数 → 密度(平均)で推定** /
  **(c)** 列間の相関(独立を仮定した掛け算) / **(d)** 式・関数を掛けた列 /
  **(e)** 昇順キー(ヒストグラム範囲外 → 1 行) / **(f)** テーブル変数(統計なし) /
  **(g)** 複数列統計が無い。**それぞれ効く対処が違う**(8-3 節のフロー)。
- **ローカル変数とパラメータは別物**。前者は密度(平均)、後者は初回の値でヒストグラム。
  後者の問題が [28 パラメータスニッフィング詳解](28_parameter_sniffing.md)。
- **CE は 互換性レベル 110以下 = 旧CE(モデル 70) / 120以上 = 新CE**。
  新CE は相関に強いが、**本当に独立なデータでは過大推定する**。
  **どちらが良いかはデータ次第**。プラン XML の
  `CardinalityEstimationModelVersion` で確認する。
- **CE の変更は「クエリ単位の `USE HINT` → DBスコープ構成 → 互換性レベル」の順に、
  影響の小さいものから試す**。変更するときは **必ず現在値を記録し、元に戻す**。
- **乖離の目安**: 2倍未満は正常 / 10倍超で疑う / 100倍超は確実に問題 /
  推定1行 vs 実際4桁は最悪。**右から左に見て、最初にずれた演算子が犯人**。
  ループ内は **実行あたり**に直して比べる。

➡ 演習: [exercises/27_statistics_cardinality.md](../exercises/27_statistics_cardinality.md)
