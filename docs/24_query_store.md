# 24 Query Store

> **このトピックのゴール**: **「昨日まで速かったクエリが、今日になって急に遅い」** という
> 実務でもっとも厄介な事象を、**推測ではなく履歴データで**証明できるようになる。
> クエリテキスト・実行プラン・実行時統計を**データベースの中に永続化**する Query Store を有効化し、
> リソースを食っているクエリを特定し、**プランリグレッション(プランの劣化)を検出**し、
> 必要なら**プランを強制**して止血できるようになる。
>
> **前提**: [23 待機統計とボトルネック特定](23_wait_statistics.md) までを済ませていること。
> **さらに、この章は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください。

> ⚠️ **Query Store は SQL Server 2016 で導入された機能** です。2014 以前では利用できません。
> 本章では次のバージョン差にも触れます。
>
> | 機能 | 必要バージョン |
> |---|---|
> | Query Store 本体・プラン強制 | **2016+** |
> | `sys.query_store_wait_stats`(クエリ単位の待機統計) | **2017+** |
> | 自動チューニング(`FORCE_LAST_GOOD_PLAN`) | **2017+**(Enterprise) |
> | `QUERY_CAPTURE_MODE = CUSTOM` / 既定が `AUTO` に変更 | **2019+** |
> | 新規DBで既定 ON・セカンダリレプリカ対応・Query Store ヒント | **2022+** |

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

---

## 1. Query Store とは何か

### 1-1. プランキャッシュだけでは「昨日」が分からない

[18 インデックスと実行プラン](18_indexes_execution_plans.md) でプランを読み、
[23 待機統計とボトルネック特定](23_wait_statistics.md) でサーバー全体のボトルネックを見ました。
しかし、どちらにも共通する致命的な弱点があります。

```sql
-- プランキャッシュ上の統計。これは「今そこにあるもの」しか見えない
SELECT TOP (5)
       qs.execution_count,
       qs.total_worker_time / 1000 AS 合計CPUミリ秒,
       SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                   ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS クエリ
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER  BY qs.total_worker_time DESC;
```

このデータは **揮発性(volatile)** です。次のどれかが起きた瞬間に消えます。

- **SQL Server の再起動 / フェールオーバー**
- メモリ不足によるキャッシュの追い出し(エビクション)
- `DBCC FREEPROCCACHE`、インデックスの作成・変更、統計の更新による**再コンパイル**
- `ALTER DATABASE ... SET ...` などの設定変更

つまり、**「障害が起きた夜のプランを、翌朝になってから見る」ことができない**。
これが現場でチューニングを難しくしている最大の理由です。
「遅かったんです」「今は再現しません」で調査が終わってしまう。

### 1-2. Query Store が変えたこと

Query Store は、次の4種類の情報を **ユーザーデータベースの内部テーブルに永続化** します。

| 記録するもの | 内容 |
|---|---|
| **クエリテキスト** | 正規化されたステートメント単位のSQL文 |
| **実行プラン** | そのクエリに対して**過去に使われたすべてのプラン**(1つではない) |
| **実行時統計** | 実行回数・所要時間・CPU・論理読み取り・メモリ・DOP などを**時間間隔ごとに集計** |
| **待機統計**(2017+) | そのクエリが**何を待っていたか**をカテゴリ単位で |

決定的なのは次の2点です。

1. **データベース内に保存される**ので、**再起動をまたいでも消えない**。
   バックアップ/リストアやデータベースのデタッチ/アタッチにも**ついて回ります**。
   AlwaysOn のフェールオーバー後も、そのデータベースの履歴は残ります。
2. **1つのクエリに対して複数のプランを保持する**。
   だから「**先週はプランAで 50ms、今週はプランBで 8000ms**」という比較ができる。

> 💡 Query Store はよく「**SQL Server のフライトレコーダー(ブラックボックス)**」と呼ばれます。
> 事故が起きてから「あのとき何が起きていたか」を再生できる、という意味です。
> **本番環境では原則として有効化しておくべき機能**だと考えてください。

### 1-3. 記録の仕組みとオーバーヘッド

```
  クエリ実行
     │
     ▼
  [メモリ上のバッファ]  ← ここへは非同期に書かれる(実行を待たせない)
     │
     │  DATA_FLUSH_INTERVAL_SECONDS ごと(既定 900 秒)
     ▼
  [データベース内の内部テーブル]  ← ここに永続化される
     │
     ▼
  sys.query_store_* カタログビューから読める
```

- 収集は**非同期**なので、クエリの実行そのものはほとんど待たされません。
  一般に **CPU オーバーヘッドは数%以内**とされますが、
  **極端にアドホッククエリが多いシステム**(毎回リテラルが違うSQLを大量に投げる)では
  無視できない負荷になります。その場合の対処は 2-5 節の `QUERY_CAPTURE_MODE` です。
- **ディスク上のフラッシュ前のデータは、異常終了時に失われます**。
  検証のために「今すぐ書き出したい」ときは `sys.sp_query_store_flush_db` を実行します(9 節)。

> ⚠️ Query Store は **データベース単位**の機能です。サーバー全体ではありません。
> `master` / `model` / `msdb` / `tempdb` などのシステムデータベースでは有効化できません
> (`master` と `msdb` は一部バージョンで可)。**調べたい業務DBごとに有効化**します。

---

## 2. 有効化と設定

### 2-1. まず現在の状態を確認する(必ず最初に)

**設定を変える前に、元の状態を必ず記録してください。** 本章の最後に元へ戻します。

```sql
SELECT desired_state_desc          AS 設定上の状態,
       actual_state_desc           AS 実際の状態,      -- ★ここが最重要
       readonly_reason             AS 読取専用理由,
       current_storage_size_mb     AS 現在サイズMB,
       max_storage_size_mb         AS 上限MB,
       flush_interval_seconds      AS フラッシュ間隔秒,
       interval_length_minutes     AS 集計間隔分,
       stale_query_threshold_days  AS 保持日数,
       size_based_cleanup_mode_desc AS サイズ基準クリーンアップ,
       query_capture_mode_desc     AS 収集モード,
       max_plans_per_query         AS プラン上限,
       wait_stats_capture_mode_desc AS 待機統計収集     -- 2017+
FROM   sys.database_query_store_options;
```

- `actual_state_desc` が `OFF` なら未使用、`READ_WRITE` なら記録中、`READ_ONLY` なら**記録が止まっています**。
- **`desired_state_desc` と `actual_state_desc` が食い違っていたら異常** です。
  「READ_WRITE にしたつもりなのに実際は READ_ONLY」= 2-4 節の罠にはまっています。

> 💡 **SQL Server 2022 以降で作成した新規データベースでは Query Store が既定で ON** です。
> 2016〜2019 で作った `SalesLearning` では `OFF` のはずですが、必ず上のクエリで確かめてください。

### 2-2. 有効化する

```sql
ALTER DATABASE SalesLearning SET QUERY_STORE = ON;
```

これだけでも動きますが、**既定値のままでは実務で困ります**。オプションを明示するのが定石です。

```sql
ALTER DATABASE SalesLearning
SET QUERY_STORE = ON
(
    OPERATION_MODE              = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 900,      -- 15分ごとにディスクへ書き出す
    INTERVAL_LENGTH_MINUTES     = 15,       -- 15分単位で統計を集計する
    MAX_STORAGE_SIZE_MB         = 2048,     -- Query Store が使ってよい容量
    QUERY_CAPTURE_MODE          = AUTO,     -- 些末なクエリは拾わない
    SIZE_BASED_CLEANUP_MODE     = AUTO,     -- 上限に近づいたら自動で古いものを消す
    STALE_QUERY_THRESHOLD_DAYS  = 30,       -- 30日より古い履歴は消す
    MAX_PLANS_PER_QUERY         = 200,
    WAIT_STATS_CAPTURE_MODE     = ON        -- 2017+
);
```

> ⚠️ `ALTER DATABASE ... SET QUERY_STORE` の実行には、そのデータベースに対する
> **`ALTER` 権限**(実質 `db_owner` 相当)が必要です。

### 2-3. 各オプションの意味と実務的な推奨値

| オプション | 既定値 | 推奨 | 理由 |
|---|---|---|---|
| `OPERATION_MODE` | `READ_WRITE` | `READ_WRITE` | `READ_ONLY` は**読めるが記録しない**。手動で落とすのは調査を凍結したいときだけ |
| `DATA_FLUSH_INTERVAL_SECONDS` | `900` | `900`(検証時は `60`) | 短くすると I/O が増える代わりに、異常終了時の**取りこぼしが減る** |
| `INTERVAL_LENGTH_MINUTES` | `60` | **`15`** | **統計の粒度**。小さいほど「何時何分から遅くなったか」が分かるが、行数が増え容量を食う |
| `MAX_STORAGE_SIZE_MB` | 2016/2017: `100`<br>2019+: `1000` | **`1024`〜`4096`** | **2016/2017 の既定 100MB は明らかに小さい**。すぐ埋まって記録が止まる(2-4 節) |
| `QUERY_CAPTURE_MODE` | 2016/2017: `ALL`<br>2019+: `AUTO` | **`AUTO`** | `ALL` はアドホッククエリの洪水で Query Store が埋まる |
| `SIZE_BASED_CLEANUP_MODE` | `AUTO` | **`AUTO`(絶対に OFF にしない)** | `AUTO` なら上限の約90%で自動的に古いデータを削除し、**READ_ONLY 落ちを防ぐ** |
| `STALE_QUERY_THRESHOLD_DAYS` | `30` | `30`(月次比較したいなら `45`〜`60`) | これより古い履歴は削除される。**「前回のリリース前と比べたい」期間をカバーする長さ**にする |
| `MAX_PLANS_PER_QUERY` | `200` | `200` | 0 は「無制限」。上限に達すると**新しいプランが記録されなくなる** |
| `WAIT_STATS_CAPTURE_MODE` | `ON` | `ON` | 2017+。8 節で使う。切る理由はほぼない |

`INTERVAL_LENGTH_MINUTES` に指定できる値は **`1`, `5`, `10`, `15`, `30`, `60`, `1440` のみ**です。
任意の数値は指定できません。

> 💡 **`INTERVAL_LENGTH_MINUTES` の決め方**: この値が「グラフの横軸の刻み」になります。
> 60 分だと「9時台に遅かった」までしか分からない。15 分にすると
> 「9:15〜9:30 のバッチと重なったときだけ遅い」まで見えます。
> 学習・短時間の検証では `1` にすると即座に区間が切り替わって観察しやすいですが、
> **本番で `1` は容量を激しく食う**ので使わないでください。

### 2-4. ⚠️ 最大の落とし穴 — 容量が上限に達すると記録が止まる

**この章でいちばん覚えて帰ってほしい罠です。**

Query Store の使用量が `MAX_STORAGE_SIZE_MB` に達すると、
**`OPERATION_MODE` は自動的に `READ_ONLY` へ落ち、それ以降いっさい記録されなくなります**。

しかもエラーは出ません。**静かに止まります。**
半年後に障害調査をしようとして「データが3月で止まっている」と気づく、という事故が実際に起きます。

```sql
-- 定期的にこれを見る。actual_state_desc = READ_ONLY なら異常
SELECT actual_state_desc          AS 実際の状態,
       readonly_reason            AS 読取専用理由コード,
       current_storage_size_mb    AS 現在サイズMB,
       max_storage_size_mb        AS 上限MB,
       CAST(100.0 * current_storage_size_mb / NULLIF(max_storage_size_mb, 0)
            AS DECIMAL(5,1))      AS 使用率パーセント
FROM   sys.database_query_store_options;
```

`readonly_reason` は**ビットマスク**です。主な値:

| 値 | 意味 | 対処 |
|---|---|---|
| `1` | データベースが読み取り専用 | DB 側の問題 |
| `2` | シングルユーザーモード | DB 側の問題 |
| `4` | 緊急(EMERGENCY)モード | DB 側の問題 |
| `8` | セカンダリレプリカ | 2022 より前は正常な挙動 |
| `65536` | **`MAX_STORAGE_SIZE_MB` の上限に達した** | **最頻出。下記参照** |
| `131072` | 異なるステートメント数が内部メモリ上限に達した | `QUERY_CAPTURE_MODE` を見直す |
| `262144` | 未フラッシュデータが内部メモリ上限に達した | `DATA_FLUSH_INTERVAL_SECONDS` を短く |
| `524288` | データベースがディスクサイズ上限に達した | ファイル拡張 |

**`65536`(容量超過)への対処:**

```sql
-- ① 上限を広げる
ALTER DATABASE SalesLearning SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 4096);

-- ② サイズ基準の自動クリーンアップが ON になっているか必ず確認する
ALTER DATABASE SalesLearning SET QUERY_STORE (SIZE_BASED_CLEANUP_MODE = AUTO);

-- ③ READ_WRITE に戻す(①②をやってから。でないとまたすぐ落ちる)
ALTER DATABASE SalesLearning SET QUERY_STORE (OPERATION_MODE = READ_WRITE);
```

> ⚠️ **`SIZE_BASED_CLEANUP_MODE = OFF` は事実上の時限爆弾**です。
> 「古いデータを消したくないから OFF にする」という判断は、
> 結果として**上限到達後の新しいデータを全部捨てる**ことになります。順序が逆です。
> 容量が足りないなら `MAX_STORAGE_SIZE_MB` を増やす。`AUTO` は必ず維持する。

> ⚠️ もう一つの落とし穴: **クリーンアップ処理自体がそれなりに重い**。
> `QUERY_CAPTURE_MODE = ALL` でアドホッククエリを大量に拾い続けると、
> 「入れては消し」を繰り返して CPU を無駄に使います。**入口(収集モード)で絞るのが正解**です。

### 2-5. `QUERY_CAPTURE_MODE` — 何を拾うか

| モード | 挙動 | 使いどころ |
|---|---|---|
| `ALL` | **すべて**のクエリを記録 | 短期の検証・学習。実行回数が少ないシステム |
| `AUTO` | **実行回数やリソース消費が些末なクエリを無視**する | **本番の既定解**。2019+ では既定値 |
| `NONE` | 新規クエリを記録しない(**既存クエリの統計収集は続く**) | 「もう対象は揃った、これ以上増やすな」というとき |
| `CUSTOM` | しきい値を自分で決める(**2019+**) | AUTO では拾えない/拾いすぎるクエリを調整したいとき |

```sql
-- 2019+: しきい値を自分で決める
ALTER DATABASE SalesLearning
SET QUERY_STORE = ON
(
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY =
    (
        STALE_CAPTURE_POLICY_THRESHOLD = 24 HOURS,  -- この期間内に
        EXECUTION_COUNT                = 30,        -- 30回以上実行 か
        TOTAL_COMPILE_CPU_TIME_MS      = 1000,      -- 合計コンパイルCPUが1秒超 か
        TOTAL_EXECUTION_CPU_TIME_MS    = 100        -- 合計実行CPUが100ms超 なら記録
    )
);
```

> ⚠️ **`NONE` は「止める」ではありません**。新しいクエリを**登録しなくなる**だけで、
> すでに登録済みのクエリの統計は取り続けます。完全に止めたいなら `OPERATION_MODE = READ_ONLY` か `OFF`。

### 2-6. クリアと無効化

```sql
-- 記録された内容をすべて消す(設定は残る)
ALTER DATABASE SalesLearning SET QUERY_STORE CLEAR;

-- 無効化する(データは残ったまま。もう一度 ON にすると見える)
ALTER DATABASE SalesLearning SET QUERY_STORE = OFF;
```

- `CLEAR` は **データだけ**を消します。オプション設定は保持されます。
- `OFF` は **収集を止めるだけ**で、記録済みデータは削除されません。
  完全に元へ戻したいなら **`CLEAR` してから `OFF`** の順で実行します。
- `CLEAR ALL` と書くと、統計に加えてランタイム統計以外の内部状態も初期化されます。
  通常は `CLEAR` で十分です。

> ⚠️ `CLEAR` は**取り消せません**。本番で軽い気持ちで打つと、
> 数か月ぶんの貴重な履歴が消えます。**「調子が悪いからとりあえずクリア」は最悪手**。
> まず `sys.database_query_store_options` で状態を確認してください。

---

## 3. カタログビューの地図

Query Store のデータは、5つのビューを結合して読みます。**この関係図が頭に入れば9割終わり**です。

```
 sys.query_store_query_text     1件のSQL文のテキスト
        │ query_text_id
        ▼
 sys.query_store_query          クエリ(コンテキスト設定込み)      … query_id
        │ query_id
        ▼
 sys.query_store_plan           そのクエリに使われた「プラン」     … plan_id  ★複数ありうる
        │ plan_id
        ▼
 sys.query_store_runtime_stats  プラン×時間区間ごとの実行時統計
        │ runtime_stats_interval_id
        ▼
 sys.query_store_runtime_stats_interval   時間区間(start_time / end_time)
```

| ビュー | 主なキー | 押さえる列 |
|---|---|---|
| `sys.query_store_query_text` | `query_text_id` | `query_sql_text` |
| `sys.query_store_query` | `query_id` | `query_text_id`, `object_id`(プロシージャなら), `query_hash`, `last_execution_time`, `count_compiles`, `avg_compile_duration` |
| `sys.query_store_plan` | `plan_id` | `query_id`, `query_plan`(XMLの文字列), `is_forced_plan`, `last_force_failure_reason_desc`, `is_parallel_plan`, `compatibility_level`, `query_plan_hash` |
| `sys.query_store_runtime_stats` | `runtime_stats_id` | `plan_id`, `runtime_stats_interval_id`, `count_executions`, `avg_duration`, `avg_cpu_time`, `avg_logical_io_reads`, `avg_rowcount`, `avg_dop`, `execution_type_desc` |
| `sys.query_store_runtime_stats_interval` | `runtime_stats_interval_id` | `start_time`, `end_time`(`datetimeoffset`) |

### 3-1. 単位に注意(ここでよく間違える)

| 列 | 単位 |
|---|---|
| `avg_duration` / `avg_cpu_time` / `last_duration` など時間系 | **マイクロ秒(μs)** |
| `avg_logical_io_reads` / `avg_physical_io_reads` / `avg_query_max_used_memory` | **8KB ページ数** |
| `avg_log_bytes_used` | バイト |
| `sys.query_store_wait_stats` の `*_wait_time_ms` | **ミリ秒(ms)** ← ここだけ違う |

> ⚠️ **時間系はマイクロ秒**です。`avg_duration = 8000000` は 8 秒であって 8000 秒ではありません。
> ミリ秒にしたいなら `/ 1000.0`、秒なら `/ 1000000.0`。
> **`sys.query_store_wait_stats` だけはミリ秒**という不揃いがあるので毎回確認してください。

### 3-2. プランを目で見る

`sys.query_store_plan.query_plan` は **`NVARCHAR(MAX)` の文字列**です。
SSMS でクリックしてグラフィカルプランを開くには、**XML にキャストします**。

```sql
SELECT p.plan_id,
       p.is_forced_plan,
       p.is_parallel_plan,
       CAST(p.query_plan AS XML) AS 実行プラン     -- ← クリックするとプランが開く
FROM   sys.query_store_plan AS p
WHERE  p.query_id = 1;                             -- 調べたい query_id を指定
```

---

## 4. リソースを食っているクエリを特定する

ここからが実用パートです。**まず「どのクエリが重いか」を確定させます。**

### 4-1. 合計CPU時間の多いクエリ Top10

```sql
SELECT TOP (10)
       q.query_id,
       OBJECT_NAME(q.object_id)                                   AS オブジェクト,
       qt.query_sql_text                                          AS クエリ,
       COUNT(DISTINCT p.plan_id)                                  AS プラン数,
       SUM(rs.count_executions)                                   AS 実行回数,
       SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0        AS 合計CPUミリ秒,
       SUM(rs.avg_cpu_time * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0         AS 平均CPUミリ秒,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0         AS 平均経過ミリ秒,
       MAX(rs.last_execution_time)                                AS 最終実行
FROM   sys.query_store_query            AS q
JOIN   sys.query_store_query_text       AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan             AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats    AS rs ON rs.plan_id       = p.plan_id
JOIN   sys.query_store_runtime_stats_interval AS rsi
       ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE  rsi.start_time >= DATEADD(HOUR, -24, SYSDATETIMEOFFSET())   -- 直近24時間
GROUP  BY q.query_id, q.object_id, qt.query_sql_text
ORDER  BY 合計CPUミリ秒 DESC;
```

- **`合計CPUミリ秒` で並べるのが基本**です。「1回0.5秒だが10万回走るクエリ」のほうが、
  「1回10秒だが日に1回のクエリ」よりサーバーへの影響は大きい。
- `プラン数` が 2 以上のクエリは、**5 節のリグレッション検査の対象**です。
- `OBJECT_NAME(q.object_id)` はストアドプロシージャ内のステートメントなら
  プロシージャ名を返します(アドホックなら `object_id = 0` で NULL)。

### 4-2. 論理読み取りの多いクエリ Top10

18 章の合言葉「**チューニングの効果は論理読み取り数で語る**」は、ここでも変わりません。

```sql
SELECT TOP (10)
       q.query_id,
       qt.query_sql_text                                            AS クエリ,
       SUM(rs.count_executions)                                     AS 実行回数,
       SUM(rs.avg_logical_io_reads * rs.count_executions)           AS 合計論理読み取りページ,
       SUM(rs.avg_logical_io_reads * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0)                    AS 平均論理読み取りページ,
       SUM(rs.avg_logical_io_reads * rs.count_executions) * 8 / 1024 AS 合計読み取りMB,
       SUM(rs.avg_rowcount * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0)                    AS 平均返却行数
FROM   sys.query_store_query          AS q
JOIN   sys.query_store_query_text     AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan           AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats  AS rs ON rs.plan_id       = p.plan_id
GROUP  BY q.query_id, qt.query_sql_text
ORDER  BY 合計論理読み取りページ DESC;
```

> 💡 **`平均論理読み取りページ` と `平均返却行数` を並べて見る**のが上級者の読み方です。
> 「274 行返すのに 6,000 ページ読んでいる」なら、それは 18 章で学んだ
> **インデックス不足か非SARGableな条件**です。比率が判断材料になります。

### 4-3. 実行回数の多いクエリ Top10

```sql
SELECT TOP (10)
       q.query_id,
       qt.query_sql_text                                        AS クエリ,
       SUM(rs.count_executions)                                 AS 実行回数,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0        AS 平均経過ミリ秒,
       SUM(rs.avg_duration * rs.count_executions) / 1000.0       AS 合計経過ミリ秒,
       q.count_compiles                                          AS コンパイル回数,
       q.avg_compile_duration / 1000.0                           AS 平均コンパイルミリ秒
FROM   sys.query_store_query          AS q
JOIN   sys.query_store_query_text     AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan           AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats  AS rs ON rs.plan_id       = p.plan_id
GROUP  BY q.query_id, qt.query_sql_text, q.count_compiles, q.avg_compile_duration
ORDER  BY 実行回数 DESC;
```

- **`実行回数` ≒ `コンパイル回数` になっているクエリは要注意**。
  毎回コンパイルし直している = プランが再利用されていない、という意味です。
  アドホックSQL・`OPTION (RECOMPILE)` の付けすぎ・パラメーター化されていないクエリを疑います
  ([20 動的SQL](20_dynamic_sql.md) 参照)。
- そもそも「1日に 50 万回呼ばれる」クエリは、**チューニングより呼び出し回数を減らす**ほうが
  効果が大きいことがあります。アプリ側の N+1 問題を疑ってください。

### 4-4. ⚠️ 平均の取り方を間違えない

Query Store の統計は「**時間区間ごとの平均**」です。
これをさらに `AVG()` で平均すると、**実行回数の重みが失われます**。

```sql
-- ✗ 誤り: 区間ごとの平均を単純平均している
--   1回しか実行されなかった区間と、10万回実行された区間が「同じ重み」になる
SELECT q.query_id, AVG(rs.avg_duration) / 1000.0 AS 平均ミリ秒_誤
FROM   sys.query_store_query AS q
JOIN   sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
GROUP  BY q.query_id;

-- ○ 正しい: 実行回数で重み付けする
SELECT q.query_id,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS 平均ミリ秒_正
FROM   sys.query_store_query AS q
JOIN   sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
GROUP  BY q.query_id;
```

**合計値 = `SUM(avg_XXX * count_executions)`、平均値 = それを `SUM(count_executions)` で割る。**
このイディオムを丸暗記してください。本章の以降のクエリはすべてこの形です。

> 💡 平均だけを見ていると、**「たまに極端に遅い」クエリを見逃します**。
> `max_duration` や `stdev_duration` も一緒に出すと、
> 「平均は 20ms だが最大 12 秒」というブレの大きいクエリが見つかります。
> これは SSMS の「**変動が大きいクエリ**」レポート(7 節)と同じ観点です。

---

## 5. プランリグレッションの検出(この章の主目的)

**Query Store の存在意義はここにあります。** 上位クエリの一覧を出すだけなら、
プランキャッシュの DMV でもできる。**「プランが変わって遅くなった」を証明できるのは Query Store だけ**です。

### 5-1. なぜプランは勝手に変わるのか

同じSQL文なのに、SQL Server が別のプランを選ぶ主な理由:

| 原因 | 詳しくは |
|---|---|
| **統計情報が更新され、推定行数が変わった** | [27 統計情報とカーディナリティ推定](27_statistics_cardinality.md) |
| **パラメーター スニッフィング**(初回実行時の引数でプランが固定された) | [28 パラメータスニッフィング詳解](28_parameter_sniffing.md) |
| インデックスの追加・削除・無効化 | [18 インデックスと実行プラン](18_indexes_execution_plans.md) |
| データ量そのものの増加(ティッピングポイント超え) | 18 章 5-4 節 |
| **データベース互換性レベルの変更**(CE の世代が変わる) | 27 章 |
| SQL Server のバージョンアップ・累積更新の適用 | — |
| サーバー設定(MAXDOP、コストしきい値)の変更 | [29 結合アルゴリズムと並列処理](29_join_algorithms_parallelism.md) |

**どれもアプリのコードは1行も変わっていません。** だから「デプロイしてないのに遅くなった」が起きる。

### 5-2. 複数のプランを持つクエリを洗い出す

まずは**候補**を見つけます。プランが1つしかないクエリはリグレッションのしようがありません。

```sql
SELECT q.query_id,
       COUNT(DISTINCT p.plan_id) AS プラン数,
       LEFT(qt.query_sql_text, 120) AS クエリ抜粋
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
GROUP  BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 1
ORDER  BY プラン数 DESC;
```

### 5-3. プランごとの平均実行時間を比較する(核心)

**同じクエリの、プランごとの成績表**を出します。**このクエリが本章の中心**です。

```sql
WITH PlanStats AS (
    SELECT p.query_id,
           p.plan_id,
           p.is_forced_plan,
           p.is_parallel_plan,
           SUM(rs.count_executions)                                       AS 実行回数,
           SUM(rs.avg_duration * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0             AS 平均経過ミリ秒,
           SUM(rs.avg_cpu_time * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0             AS 平均CPUミリ秒,
           SUM(rs.avg_logical_io_reads * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0)                      AS 平均論理読み取り,
           MIN(rs.first_execution_time)                                   AS 初回実行,
           MAX(rs.last_execution_time)                                    AS 最終実行
    FROM   sys.query_store_plan          AS p
    JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    GROUP  BY p.query_id, p.plan_id, p.is_forced_plan, p.is_parallel_plan
)
SELECT ps.query_id,
       ps.plan_id,
       ps.is_forced_plan            AS 強制中,
       ps.is_parallel_plan          AS 並列プランか,
       ps.実行回数,
       ps.平均経過ミリ秒,
       ps.平均CPUミリ秒,
       ps.平均論理読み取り,
       ps.初回実行,
       ps.最終実行,
       LEFT(qt.query_sql_text, 100) AS クエリ抜粋
FROM   PlanStats AS ps
JOIN   sys.query_store_query      AS q  ON q.query_id      = ps.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  ps.query_id IN (SELECT query_id
                       FROM   sys.query_store_plan
                       GROUP  BY query_id
                       HAVING COUNT(*) > 1)          -- 複数プランを持つクエリだけ
ORDER  BY ps.query_id, ps.平均経過ミリ秒;
```

読み方:

- 同じ `query_id` の行が **プランの数だけ並びます**。
  **`平均経過ミリ秒` が桁違いなら、それがリグレッション**です。
- **`最終実行` を必ず見ること**。「速いプランは先週まで、遅いプランが今日も動いている」なら、
  **今まさに劣化している**状態です。逆に遅いプランが過去のものなら、すでに解消しています。
- `平均論理読み取り` も一緒に見ます。**時間だけでなく論理読み取りも増えていれば、
  「サーバーが忙しかったから遅かった」ではなく「プランが本当に悪くなった」**と断定できます。
  ここが 18 章の教えと繋がるところです。

### 5-4. 「最良プランと現行プランの差」で自動抽出する

上の結果を人間が眺めるのではなく、**劣化倍率で自動的に並べます**。
SSMS の「回帰したクエリ」レポートがやっていることと同じです。

```sql
WITH PlanStats AS (
    SELECT p.query_id,
           p.plan_id,
           SUM(rs.count_executions)                                   AS 実行回数,
           SUM(rs.avg_duration * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0         AS 平均ミリ秒,
           MAX(rs.last_execution_time)                                AS 最終実行
    FROM   sys.query_store_plan          AS p
    JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    GROUP  BY p.query_id, p.plan_id
),
Ranked AS (
    SELECT ps.*,
           MIN(ps.平均ミリ秒) OVER (PARTITION BY ps.query_id) AS 最良平均ミリ秒,
           ROW_NUMBER() OVER (PARTITION BY ps.query_id
                              ORDER BY ps.最終実行 DESC)       AS 直近順
    FROM   PlanStats AS ps
    WHERE  ps.実行回数 >= 5          -- サンプルが少なすぎるプランはノイズなので除外
)
SELECT r.query_id,
       r.plan_id                                        AS 現行プラン,
       r.平均ミリ秒                                      AS 現行平均ミリ秒,
       r.最良平均ミリ秒,
       CAST(r.平均ミリ秒 / NULLIF(r.最良平均ミリ秒, 0)
            AS DECIMAL(10,1))                           AS 劣化倍率,
       r.実行回数,
       r.最終実行,
       LEFT(qt.query_sql_text, 120)                     AS クエリ抜粋
FROM   Ranked AS r
JOIN   sys.query_store_query      AS q  ON q.query_id       = r.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  r.直近順 = 1                                       -- 各クエリの「今使われているプラン」
  AND  r.平均ミリ秒 > r.最良平均ミリ秒 * 2                  -- 最良の2倍以上遅い
ORDER  BY 劣化倍率 DESC;
```

- `実行回数 >= 5` の足切りが重要です。**1回しか走っていないプランは、
  たまたま初回でキャッシュに乗っていなかっただけ**かもしれません。統計的に無意味なノイズを除きます。
- `劣化倍率` のしきい値(ここでは 2 倍)は運用に合わせて調整します。
  **8 倍・100 倍といった値が出たら、それはほぼ確実にプランリグレッション**です。

> 💡 **判断基準のまとめ**:
> 「**同じクエリ・同じ結果件数(`avg_rowcount`)なのに、
> 論理読み取りと所要時間が桁で増えており、そのタイミングでプランIDが変わっている**」
> — この4つが揃ったら、プランリグレッションと断定してよい。

---

## 6. プランの強制(Force Plan)

リグレッションを見つけたら、**「良かったプランを固定する」**ことができます。これが止血手段です。

### 6-1. 強制する

```sql
-- query_id と plan_id を指定する(5 節のクエリで調べた値)
EXEC sys.sp_query_store_force_plan @query_id = 1, @plan_id = 1;
```

- 以後、そのクエリは**指定したプランで実行されようとします**。
- 強制は**データベース内に永続化**されます。再起動しても解除されません。
- 内部的には `USE PLAN` ヒントを付けたのと同じ効果ですが、**アプリのSQLを1文字も変えずに**適用できます。
  これが Query Store の実務的価値です。

### 6-2. 強制されているプランを確認する

```sql
SELECT q.query_id,
       p.plan_id,
       p.is_forced_plan                     AS 強制中,
       p.plan_forcing_type_desc             AS 強制の種類,   -- MANUAL / AUTO(自動チューニング)
       p.force_failure_count                AS 強制失敗回数,
       p.last_force_failure_reason          AS 最終失敗理由コード,
       p.last_force_failure_reason_desc     AS 最終失敗理由,
       LEFT(qt.query_sql_text, 120)         AS クエリ抜粋
FROM   sys.query_store_plan       AS p
JOIN   sys.query_store_query      AS q  ON q.query_id       = p.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  p.is_forced_plan = 1;
```

**運用ではこのクエリを定期的に流してください。**
「いつの間にか誰かが強制したプランが残っていて、データ量が変わった今では逆に足を引っ張っている」
というのは、実際によくある事故です。

### 6-3. ⚠️ 強制が失敗するとき

**強制は「必ずそのプランになる」保証ではありません。** SQL Server が
そのプランを再現できないと判断すると、**黙って別のプランで実行します**。
`is_forced_plan = 1` のままなのに、実際は強制されていない、という状態になり得ます。

**気づく方法は `force_failure_count` と `last_force_failure_reason_desc` を見ること**です。

| `last_force_failure_reason_desc` | 意味 | よくある原因 |
|---|---|---|
| `NONE` | 失敗していない(正常) | — |
| `NO_INDEX` | **プランが参照しているインデックスが存在しない** | 誰かがインデックスを削除・リネームした |
| `NO_PLAN` | プランを生成できなかった | オブジェクト定義が変わった |
| `VIEW_COMPILE_FAILED` | ビューのコンパイルに失敗 | ビュー定義の変更 |
| `IS_TRIVIAL` | 自明なプラン(強制の対象にならない) | 単純すぎるクエリを強制しようとした |
| `TIMEOUT` | 強制付きのコンパイルがタイムアウト | 極端に複雑なクエリ |
| `ONLINE_INDEX_BUILD` | オンラインインデックス構築中 | 一時的。再試行で解消 |
| `GENERAL_FAILURE` | その他 | エラーログ・拡張イベントを併用して調査 |

```sql
-- 強制が失敗しているプランだけを抽出する(監視に使う)
SELECT q.query_id, p.plan_id,
       p.force_failure_count            AS 失敗回数,
       p.last_force_failure_reason_desc AS 失敗理由,
       LEFT(qt.query_sql_text, 150)     AS クエリ抜粋
FROM   sys.query_store_plan       AS p
JOIN   sys.query_store_query      AS q  ON q.query_id       = p.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  p.is_forced_plan = 1
  AND  p.force_failure_count > 0;
```

> ⚠️ **`NO_INDEX` はもっとも多い失敗理由**です。プランを強制したあとで
> 「使われていないから」とインデックスを削除すると、強制が静かに壊れます。
> **プランを強制したら、そのプランが依存するインデックスは削除禁止**として管理してください。

### 6-4. 強制を解除する

```sql
EXEC sys.sp_query_store_unforce_plan @query_id = 1, @plan_id = 1;
```

### 6-5. ⚠️ 安易に強制しないこと — これは対症療法である

**プランの強制は「解熱剤」であって「治療」ではありません。**
実務では、次の順序を守ってください。

1. **まず原因を疑う。**
   - **統計情報は古くないか?** → [27 統計情報とカーディナリティ推定](27_statistics_cardinality.md)。
     `sys.dm_db_stats_properties` で `last_updated` と `modification_counter` を確認。
     統計を更新するだけで元のプランに戻ることは非常に多い。
   - **パラメーター スニッフィングではないか?** → [28 パラメータスニッフィング詳解](28_parameter_sniffing.md)。
     `OPTION (RECOMPILE)` / `OPTIMIZE FOR` / 変数への代入で解決できることが多い。
   - **インデックスが不足・過剰ではないか?** → [18 インデックスと実行プラン](18_indexes_execution_plans.md)。
   - **クエリ自体が非SARGableではないか?** → 18 章 4 節。**書き換えはノーコストの改善**。
2. **どうしても時間がない障害対応中だけ、強制で止血する。**
3. **強制したら「いつ外すか」を必ず記録する。** 課題管理票に起票してください。

強制が危険な理由:

- **データは変化し続ける**。今日の最適プランは、行数が10倍になった半年後には最悪プランかもしれません。
  強制は**オプティマイザの判断を永久に凍結**します。
- 強制されたプランは、統計を更新しても改善しません。**改善の芽を摘みます**。
- 誰も外さないまま残り続け、**数年後に「なぜこれが強制されているのか誰も知らない」**状態になります。

> ⚠️ **強制したプランの一覧(6-2 節)を定期的にレビューする仕組みがないなら、
> そもそも強制すべきではありません。**

### 6-6. 自動化する選択肢(参考)

**自動プラン修正(Automatic Plan Correction)— 2017+ / Enterprise**

Query Store のデータをもとに、SQL Server が**自動的に「最後に良かったプラン」を強制**します。

```sql
-- 有効化(2017+ Enterprise Edition)
ALTER DATABASE SalesLearning
SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);

-- SQL Server からの推奨事項を見る(有効化していなくても推奨だけは出る)
SELECT reason                       AS 理由,
       score                        AS スコア,
       JSON_VALUE(state,   '$.currentValue')          AS 状態,
       JSON_VALUE(details, '$.implementationDetails.script') AS 実行スクリプト
FROM   sys.dm_db_tuning_recommendations;
```

- `sys.dm_db_tuning_recommendations` は **有効化しなくても読めます**。
  「SQL Server はここを直したいと思っている」というヒント集として、まず読むだけでも価値があります。
  JSON の読み方は [22 JSON操作](22_json.md) を参照。
- 自動修正は、**強制したプランが改善しなければ自動的に解除**してくれます。
  人手の強制より安全ですが、**Query Store が有効であることが前提**です。

**Query Store ヒント — 2022+**

プランそのものを固定するのではなく、**ヒントだけを外付け**します。
アプリのSQLを変えずに `OPTION (RECOMPILE)` 相当を適用できる、より穏当な手段です。

```sql
-- SQL Server 2022+ のみ
EXEC sys.sp_query_store_set_hints @query_id = 1,
                                  @query_hints = N'OPTION(RECOMPILE)';
-- 解除
EXEC sys.sp_query_store_clear_hints @query_id = 1;
```

---

## 7. SSMS の Query Store レポート

Query Store を有効にすると、SSMS のオブジェクト エクスプローラーで
**データベース → Query Store** の下にレポートが並びます。
**カタログビューを叩く前に、まずここを見るのが速い**です。

| レポート | 何が見えるか | 使うタイミング |
|---|---|---|
| **上位のリソースを消費するクエリ** | 期間内で CPU / 期間 / 論理読み取り などの上位クエリ。**左に棒グラフ、右上に複数プランの散布図、右下にプラン図**の3ペイン構成 | **最初に開くレポート**。4 節のクエリと同じ内容 |
| **回帰したクエリ** | 直前の期間と比べて**悪化した**クエリ | 「昨日まで速かった」の調査。5 節に相当 |
| **全体的なリソース消費量** | 期間ごとの実行回数・所要時間・CPU・論理読み取りの推移 | 「いつから重くなったか」の当たりをつける |
| **変動が大きいクエリ** | 平均は普通だが**ばらつき(標準偏差)が大きい**クエリ | パラメーター スニッフィングの検出(28 章) |
| **強制プランのあるクエリ** | 現在強制されているプランの一覧 | 定期レビュー(6-2 節) |
| **クエリ待機統計**(2017+) | 待機カテゴリ別の上位クエリ | 8 節。23 章の待機統計をクエリ単位で見る |
| **追跡対象クエリ** | 指定した1つのクエリを継続監視 | 対策の前後比較 |

**「上位のリソースを消費するクエリ」画面の使い方(実務でいちばん使う操作):**

1. 右上のドロップダウンで **メトリック**(CPU 時間 / 期間 / 論理読み取り など)と
   **統計**(合計 / 平均 / 最大 / 標準偏差)を切り替える。**まず「CPU 時間 × 合計」**で全体像を見る。
2. 左の棒グラフでクエリを選ぶと、**右上に「そのクエリのプラン一覧」が丸印で散布表示**される。
   **丸が複数あればプランが複数ある = リグレッションの候補**。丸の大きさは実行回数です。
3. 2つの丸を選んで **「プランの比較」ボタン**を押すと、
   **2つの実行プランを並べて差分表示**できます。どの演算子が変わったか一目で分かる。
4. 良かったほうのプランを選んで **「プランの強制」ボタン** → 6 節の `sp_query_store_force_plan` が実行されます。

> 💡 レポートの期間・表示件数は右上の**「構成」**から変更できます。既定は「直近1時間・上位25件」なので、
> 「昨日の障害」を見たいときは**必ず期間を広げてから**見てください。
> 「データが出ない」の原因の大半はこれです。

---

## 8. Query Store の待機統計(2017+)

[23 待機統計とボトルネック特定](23_wait_statistics.md) では `sys.dm_os_wait_stats` で
**サーバー全体**の待機を見ました。しかしそこには決定的な限界があります。

> 「`PAGEIOLATCH_SH` が全体の 60% を占めている」…**で、どのクエリのせいなのか?**

`sys.query_store_wait_stats`(**2017+**)は、この待機を **クエリ単位・プラン単位** に分解します。
**これが Query Store のもう一つの大きな価値**です。

```sql
SELECT TOP (10)
       q.query_id,
       ws.wait_category_desc                       AS 待機カテゴリ,
       SUM(ws.total_query_wait_time_ms)            AS 合計待機ミリ秒,   -- ★ここはミリ秒
       SUM(ws.total_query_wait_time_ms)
           / NULLIF(SUM(rs.count_executions), 0)   AS 実行1回あたり待機ミリ秒,
       MAX(ws.max_query_wait_time_ms)              AS 最大待機ミリ秒,
       LEFT(qt.query_sql_text, 120)                AS クエリ抜粋
FROM   sys.query_store_wait_stats     AS ws
JOIN   sys.query_store_plan           AS p  ON p.plan_id       = ws.plan_id
JOIN   sys.query_store_query          AS q  ON q.query_id      = p.query_id
JOIN   sys.query_store_query_text     AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_runtime_stats  AS rs
       ON  rs.plan_id                  = ws.plan_id
       AND rs.runtime_stats_interval_id = ws.runtime_stats_interval_id
       AND rs.execution_type            = ws.execution_type
GROUP  BY q.query_id, ws.wait_category_desc, qt.query_sql_text
ORDER  BY 合計待機ミリ秒 DESC;
```

主な `wait_category_desc` と、23 章の待機種別との対応:

| カテゴリ | 含まれる主な待機 | 疑うこと |
|---|---|---|
| `CPU` | `SOS_SCHEDULER_YIELD` | CPU 飽和。並列度・クエリ効率 |
| `Buffer IO` | `PAGEIOLATCH_*` | **ディスクからの読み込み待ち。インデックス不足の典型**(18 章) |
| `Buffer Latch` | `PAGELATCH_*` | ホットページ競合。tempdb / 末尾挿入 |
| `Lock` | `LCK_M_*` | **ブロッキング**(19 章・23 章) |
| `Memory` | `RESOURCE_SEMAPHORE` | メモリ許可待ち。推定行数の過大見積もり(27 章) |
| `Parallelism` | `CXPACKET` / `CXCONSUMER` | 並列処理の偏り(29 章) |
| `Network IO` | `ASYNC_NETWORK_IO` | **クライアント側の結果取得が遅い**(SQL Server は悪くない) |
| `Compilation` | コンパイル関連 | 再コンパイルが多すぎる。4-3 節 |
| `Tran Log IO` | `WRITELOG` | ログ書き込み待ち。トランザクション設計(19 章) |

> ⚠️ Query Store の待機統計は **`sys.dm_os_wait_stats` よりも粒度が粗い**(カテゴリに丸められる)です。
> **「どのクエリが待っているか」を Query Store で絞り込み、
> 「厳密に何の待機か」を 23 章の DMV や [25 拡張イベント](25_extended_events.md) で確定させる**、
> という二段構えが実務の型です。

> ⚠️ 待機時間は「そのクエリが待った時間」であり、**待たせている側(ブロッカー)は分かりません**。
> ブロッキングの犯人特定は 23 章 / [26 DMVによる調査](26_dmv_investigation.md) の担当です。

---

## 9. メンテナンス用ストアドプロシージャ

| プロシージャ | 用途 |
|---|---|
| `sys.sp_query_store_flush_db` | メモリ上の未書き込みデータを**即座にディスクへ書き出す**。**検証で必須** |
| `sys.sp_query_store_force_plan` | プランを強制(6 節) |
| `sys.sp_query_store_unforce_plan` | 強制を解除(6 節) |
| `sys.sp_query_store_remove_plan` | 特定のプランとその統計を削除 |
| `sys.sp_query_store_remove_query` | 特定のクエリ・そのプラン・統計をまとめて削除 |
| `sys.sp_query_store_reset_exec_stats` | 特定プランの実行時統計だけリセット(**対策の前後比較に便利**) |

```sql
-- 検証の定番: 負荷を流した直後にフラッシュしてから読む
EXEC sys.sp_query_store_flush_db;

-- 対策を入れる直前に統計をリセットして、前後を公平に比べる
EXEC sys.sp_query_store_reset_exec_stats @plan_id = 1;
```

> ⚠️ **`sp_query_store_flush_db` を実行せずに「記録されていない!」と慌てるのは、
> Query Store 初心者の通過儀礼**です。既定では最大 15 分メモリ上に留まります。
> 検証時は `DATA_FLUSH_INTERVAL_SECONDS` を短くするか、明示的にフラッシュしてください。

---

## 10. 後片付け — 元の状態に戻す

**この章と演習で設定を変えたら、必ず元へ戻してください。**

```sql
-- ① 強制したプランをすべて解除する(残すと後の章の計測が狂う)
DECLARE @q INT, @p INT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT query_id, plan_id FROM sys.query_store_plan WHERE is_forced_plan = 1;
OPEN cur;
FETCH NEXT FROM cur INTO @q, @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @q, @plan_id = @p;
    FETCH NEXT FROM cur INTO @q, @p;
END
CLOSE cur; DEALLOCATE cur;

-- ② 記録内容をすべて消す
ALTER DATABASE SalesLearning SET QUERY_STORE CLEAR;

-- ③ 元が OFF だったなら OFF に戻す(2-1 節で記録した値に従うこと)
ALTER DATABASE SalesLearning SET QUERY_STORE = OFF;

-- ④ 戻ったことを確認
SELECT actual_state_desc, desired_state_desc, current_storage_size_mb
FROM   sys.database_query_store_options;
```

> ⚠️ **`OFF` にする前に `CLEAR` してください。** 順序が逆だと、
> 記録データがデータベース内に残ったままになります(容量を占有し続けます)。

> 💡 **本番環境では話が逆です。** 本番の Query Store は
> **有効のまま運用するのが正しい**(1-2 節)。ここで OFF に戻すのは、
> あくまで**学習環境を演習前の状態に揃えるため**です。

---

## よくあるつまずき

- **有効化したのに何も記録されていない** → ① `sp_query_store_flush_db` していない(9 節)、
  ② `actual_state_desc` が `READ_ONLY` に落ちている(2-4 節)、
  ③ SSMS レポートの**期間が「直近1時間」のまま**(7 節)。
- **`desired_state_desc = READ_WRITE` なのに `actual_state_desc = READ_ONLY`**
  → 容量上限。`readonly_reason = 65536`。`MAX_STORAGE_SIZE_MB` を増やし、
  `SIZE_BASED_CLEANUP_MODE = AUTO` を確認してから `OPERATION_MODE = READ_WRITE` に戻す。
- **時間の桁が合わない** → `avg_duration` などは**マイクロ秒**。
  `sys.query_store_wait_stats` だけ**ミリ秒**(3-1 節)。
- **平均値がおかしい** → `AVG(rs.avg_duration)` は誤り。
  **`SUM(avg_XXX * count_executions) / SUM(count_executions)`** で重み付けする(4-4 節)。
- **`sys.query_store_wait_stats` が存在しないと言われる** → **2017+** の機能。
- **プランを強制したのに速くならない** → `force_failure_count > 0` を確認(6-3 節)。
  `NO_INDEX` ならプランが依存するインデックスが消えている。
- **Query Store が肥大化して DB が膨らむ** → `QUERY_CAPTURE_MODE = ALL` でアドホッククエリを
  拾いすぎている。`AUTO`(または 2019+ の `CUSTOM`)へ。
- **一時的に遅いだけなのにプランを強制してしまう** → 実行回数の少ないプランはノイズ。
  `count_executions` で足切りする(5-4 節)。まず統計とスニッフィングを疑う(6-5 節)。
- **`CLEAR` を軽い気持ちで打って履歴を失う** → 取り消せない。本番では厳禁。
- **他のデータベースのクエリが見えない** → Query Store は**データベース単位**。
  `USE` して対象DBのコンテキストで読む必要がある(1-3 節)。

## この章のまとめ

- Query Store(**2016+**)は、クエリテキスト・**過去に使われたすべてのプラン**・実行時統計・
  待機統計(**2017+**)を **データベース内に永続化**する。
  **プランキャッシュが再起動やキャッシュ追い出しで消えるのに対し、Query Store は残る**。
  これが「昨日の障害を今日調べる」ことを可能にする決定的な違い。
- 有効化は `ALTER DATABASE ... SET QUERY_STORE = ON (...)`。
  **`MAX_STORAGE_SIZE_MB`(2016/2017 の既定 100MB は小さすぎる)** と
  **`SIZE_BASED_CLEANUP_MODE = AUTO`** を必ず確認する。
- ⚠️ **容量が上限に達すると `READ_ONLY` に落ち、記録が黙って止まる**。
  `actual_state_desc` と `readonly_reason`(`65536`)を定期監視すること。
- カタログビューは
  `query_store_query_text` → `query_store_query` → `query_store_plan` →
  `query_store_runtime_stats` → `query_store_runtime_stats_interval` の直列。
  **時間はマイクロ秒、I/O は8KBページ、待機統計だけミリ秒**。
- 集計の鉄則: **合計 = `SUM(avg_XXX * count_executions)`、
  平均 = それを `SUM(count_executions)` で割る**。単純な `AVG()` は誤り。
- **プランリグレッションの検出が Query Store の主目的**。
  「**同一 `query_id` に複数の `plan_id`** があり、プランごとの平均時間と論理読み取りが桁で違う」
  状態を探す。`最終実行` を見て「今も遅いプランが動いているか」を判断する。
- `sp_query_store_force_plan` / `sp_query_store_unforce_plan` でプランを固定・解除できる。
  **`is_forced_plan` だけでなく `force_failure_count` と
  `last_force_failure_reason_desc`(特に `NO_INDEX`)を必ず確認**する。
- ⚠️ **強制は対症療法**。先に **統計情報(27章)** と **パラメーター スニッフィング(28章)**、
  そしてインデックスとSARGability(18章)を疑うこと。強制したら**外す期限を決める**。
- SSMS の Query Store レポート(**上位のリソースを消費するクエリ / 回帰したクエリ /
  変動が大きいクエリ / クエリ待機統計**)は、カタログビューを書く前の最速の入口。
  **プランの比較**ボタンが強力。
- `sys.query_store_wait_stats` により、23 章のサーバー全体の待機統計を
  **クエリ単位に分解**できる。「どのクエリが待たせているか」まで到達できる。
- 検証時は `sp_query_store_flush_db`。学習後は **`CLEAR` → `OFF` の順**で元へ戻す。

➡ 演習: [exercises/24_query_store.md](../exercises/24_query_store.md)
