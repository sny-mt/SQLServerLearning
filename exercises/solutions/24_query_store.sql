/* ============================================================
   解答例 24 — Query Store
   対象演習: exercises/24_query_store.md

   ★ Query Store は SQL Server 2016 以降の機能。2014 以前では実行できない。
     Q12(sys.query_store_wait_stats)は 2017 以降が必要。

   前提: sample-db/03_bulk_data.sql を実行し、dbo.OrdersBig(100万行)
         が作成済みであること。開始時点で非クラスタ化インデックスは0本。

   ============================================================
   ⚠ 安全上の注意(必ず読むこと)
   ------------------------------------------------------------
   このスクリプトは ALTER DATABASE ... SET QUERY_STORE で
   データベースの設定を変更する。

     ・本番環境・共用の検証環境では絶対に実行しないこと。
     ・Q1 で「変更前の状態」を必ず控えてから始めること。
     ・最後の Q14(後片付け)まで必ず実行すること。
       → 強制プランの解除 → CLEAR → 元の状態(既定では OFF)へ戻す

   ※ 実行時間・論理読み取り数のコメントは目安。環境・バージョンで前後する。
   ※ このスクリプト自体のクエリも Query Store に記録される。
     分析クエリを結果から除くため、以降の抽出では
     「query_store」という文字列を含むクエリを除外している。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 【必ず最初に】変更前の Query Store 設定を記録する
--     この結果をコピーして手元に保存しておくこと(Q14 で使う)。
SELECT desired_state_desc           AS 設定上の状態,
       actual_state_desc            AS 実際の状態,
       readonly_reason              AS 読取専用理由,
       current_storage_size_mb      AS 現在サイズMB,
       max_storage_size_mb          AS 上限MB,
       flush_interval_seconds       AS フラッシュ間隔秒,
       interval_length_minutes      AS 集計間隔分,
       stale_query_threshold_days   AS 保持日数,
       size_based_cleanup_mode_desc AS サイズ基準クリーンアップ,
       query_capture_mode_desc      AS 収集モード,
       max_plans_per_query          AS プラン上限,
       wait_stats_capture_mode_desc AS 待機統計収集            -- 2017+
FROM   sys.database_query_store_options;
GO

/* Q1 の読み方:
   ・actual_state_desc が最重要。OFF=未使用 / READ_WRITE=記録中 / READ_ONLY=記録停止。
   ・desired_state_desc と actual_state_desc が食い違っていたら異常。
     「READ_WRITE にしたのに実際は READ_ONLY」= 容量上限に達している(readonly_reason=65536)。
   ・SQL Server 2016〜2019 で作成した SalesLearning なら OFF のはず。
     SQL Server 2022 以降で作成した新規DBは既定で ON になっている点に注意。       */


-- Q2. Query Store を有効化する(学習用の設定)
ALTER DATABASE SalesLearning
SET QUERY_STORE = ON
(
    OPERATION_MODE              = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 60,      -- 学習用。既定は 900
    INTERVAL_LENGTH_MINUTES     = 1,       -- 学習用。既定は 60、本番推奨は 15
    MAX_STORAGE_SIZE_MB         = 1024,
    QUERY_CAPTURE_MODE          = ALL,     -- 学習用。本番推奨は AUTO
    SIZE_BASED_CLEANUP_MODE     = AUTO,    -- ★これは本番でも必ず AUTO
    STALE_QUERY_THRESHOLD_DAYS  = 7,
    MAX_PLANS_PER_QUERY         = 200
);
GO

-- Q2(確認). 反映されたことを確認する
SELECT desired_state_desc           AS 設定上の状態,
       actual_state_desc            AS 実際の状態,
       interval_length_minutes      AS 集計間隔分,
       flush_interval_seconds       AS フラッシュ間隔秒,
       max_storage_size_mb          AS 上限MB,
       query_capture_mode_desc      AS 収集モード,
       size_based_cleanup_mode_desc AS サイズ基準クリーンアップ
FROM   sys.database_query_store_options;
GO

/* Q2 の説明 — なぜこの3つは「学習用であって本番向きではない」か

   ① INTERVAL_LENGTH_MINUTES = 1
      統計を集計する時間区間の長さ。1分にすると区間がすぐ切り替わるので
      「流した直後に結果が見える」= 学習に都合がよい。
      しかし本番では区間の数が 60 倍になり、runtime_stats の行数と
      Query Store の使用容量が激増する。→ 本番は 15(既定 60)が定石。
      指定できる値は 1 / 5 / 10 / 15 / 30 / 60 / 1440 のみ。

   ② DATA_FLUSH_INTERVAL_SECONDS = 60
      メモリ上のデータをディスクへ書き出す間隔。短いほど異常終了時の
      取りこぼしが減るが、そのぶん書き込み I/O が増える。
      検証では短くしたいが、本番で常時 60 秒にする必要はない(既定 900 で十分)。

   ③ QUERY_CAPTURE_MODE = ALL
      すべてのクエリを記録する。学習では「流したものが確実に記録される」ので便利。
      しかし本番、特にリテラル埋め込みのアドホックSQLが多いシステムでは
      Query Store が一瞬で埋まり、クリーンアップ処理が CPU を食い、
      最終的に容量上限に達して READ_ONLY へ落ちる。
      → 本番は AUTO(2019+ の既定)。細かく制御したいなら 2019+ の CUSTOM。   */


-- Q3. 記録内容をクリアして、まっさらな状態にする
ALTER DATABASE SalesLearning SET QUERY_STORE CLEAR;
GO

-- Q3(確認). 記録が空になったことを確認する
SELECT (SELECT COUNT(*) FROM sys.query_store_query)         AS クエリ数,
       (SELECT COUNT(*) FROM sys.query_store_plan)          AS プラン数,
       (SELECT COUNT(*) FROM sys.query_store_runtime_stats) AS 実行時統計行数;
GO

/* Q3 の説明:
   ・CLEAR は「記録されたデータ」だけを消す。オプション設定(Q2 で入れた値)は残る。
   ・CLEAR が本番で危険な理由: 取り消せないから。
     数か月ぶんの履歴 = 「障害の証拠」を一瞬で失う。
     「調子が悪いのでとりあえずクリア」は最悪手。まず
     sys.database_query_store_options で actual_state_desc を確認すること。
   ・上のカウントが 0 ではなく数件になることがあるが、それは
     このカウントクエリ自身が(実行後に)記録されたため。異常ではない。    */


-- Q4. 負荷を流して Query Store に記録させる
------------------------------------------------------------

-- Q4-a. 速いクエリ: クラスタ化主キーでの1行取得 × 20回
--       プラン       : Clustered Index Seek (PK_OrdersBig)
--       論理読み取り : 3〜4
SELECT * FROM dbo.OrdersBig WHERE OrderId = 500000;
GO 20

-- Q4-b. 遅いクエリ: 非SARGable な YEAR() × 10回
--       プラン       : Clustered Index Scan (PK_OrdersBig)
--       論理読み取り : 約 6,000
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  YEAR(OrderDate) = 2023;
GO 10

-- Q4-c. 中くらいのクエリ: 範囲条件(この時点では索引が無いので Scan)× 10回
--       ★ Q9 でまったく同じテキストを再利用するので、1文字も変えないこと
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01'
  AND  OrderDate <  '2023-07-01';
GO 10

-- Q4(フラッシュ). メモリ上の未書き込みデータを即座にディスクへ書き出す
EXEC sys.sp_query_store_flush_db;
GO

-- Q4(確認). 記録されたことを確認する
SELECT (SELECT COUNT(*) FROM sys.query_store_query)         AS クエリ数,
       (SELECT COUNT(*) FROM sys.query_store_plan)          AS プラン数,
       (SELECT COUNT(*) FROM sys.query_store_runtime_stats) AS 実行時統計行数,
       (SELECT COUNT(*) FROM sys.query_store_runtime_stats_interval) AS 区間数;
GO

/* Q4 のポイント:
   ・GO 20 は SSMS(sqlcmd)のバッチ繰り返し構文。T-SQL の文法ではない。
   ・同一テキストのクエリは1つの query_id にまとめられ、
     count_executions が加算されていく。20行に増えるわけではない。
   ・sp_query_store_flush_db を忘れると「記録されていない!」と焦ることになる。
     既定では最大 DATA_FLUSH_INTERVAL_SECONDS(900秒)メモリ上に留まる。   */


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 合計CPU時間の多いクエリ Top10
--     ★集計の鉄則:
--        合計 = SUM(avg_XXX * count_executions)
--        平均 = 合計 / SUM(count_executions)
--     ★時間系の単位はマイクロ秒。ミリ秒にするには / 1000.0
SELECT TOP (10)
       q.query_id,
       OBJECT_NAME(q.object_id)                                AS オブジェクト,
       LEFT(qt.query_sql_text, 150)                            AS クエリ抜粋,
       COUNT(DISTINCT p.plan_id)                               AS プラン数,
       SUM(rs.count_executions)                                AS 実行回数,
       SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0     AS 合計CPUミリ秒,
       SUM(rs.avg_cpu_time * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0      AS 平均CPUミリ秒,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0      AS 平均経過ミリ秒,
       MAX(rs.last_execution_time)                             AS 最終実行
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id    = p.plan_id
JOIN   sys.query_store_runtime_stats_interval AS rsi
       ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE  rsi.start_time >= DATEADD(HOUR, -24, SYSDATETIMEOFFSET())
  AND  qt.query_sql_text NOT LIKE N'%query_store%'      -- 分析クエリ自身を除く
GROUP  BY q.query_id, q.object_id, qt.query_sql_text
ORDER  BY 合計CPUミリ秒 DESC;
GO

/* Q5 の考察:
   ・Q4-b(YEAR(OrderDate) = 2023)が最上位に来るはず。
     10回しか実行していないのに、1回あたり 100万行ぶんを走査するため。
   ・「合計」で並べるのが基本。1回0.5秒でも10万回走るクエリのほうが
     1回10秒で日に1回のクエリよりサーバー負荷は大きい。
   ・プラン数 >= 2 のクエリは Q9 のリグレッション検査対象。
   ・OBJECT_NAME(q.object_id) はプロシージャ内のステートメントならプロシージャ名。
     アドホックなら object_id = 0 なので NULL になる。                      */


-- Q6. 合計論理読み取りページ数の多いクエリ Top10
SELECT TOP (10)
       q.query_id,
       LEFT(qt.query_sql_text, 150)                                  AS クエリ抜粋,
       SUM(rs.count_executions)                                      AS 実行回数,
       SUM(rs.avg_logical_io_reads * rs.count_executions)            AS 合計論理読み取りページ,
       SUM(rs.avg_logical_io_reads * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0)                     AS 平均論理読み取りページ,
       SUM(rs.avg_logical_io_reads * rs.count_executions) * 8 / 1024 AS 合計読み取りMB,
       SUM(rs.avg_rowcount * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0)                     AS 平均返却行数
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id    = p.plan_id
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, qt.query_sql_text
ORDER  BY 合計論理読み取りページ DESC;
GO

/* Q6 の考察 — 「返却行数のわりに読み取りページ数が異常に多いクエリ」:

   Q4-b: YEAR(OrderDate) = 2023
       平均返却行数 1(COUNT(*) なので結果は1行)
       平均論理読み取り 約 6,000 ページ(= 約 47MB)
   Q4-a: OrderId = 500000
       平均返却行数 1、平均論理読み取り 3〜4 ページ

   同じ「1行返す」クエリで読み取りページ数が 1,500 倍違う。
   原因は 18 章の内容そのもの:
     ① OrderDate に非クラスタ化インデックスが無い
     ② そのうえ WHERE の左辺で列を YEAR() で包んでいる(非SARGable)
        → インデックスを作っても、この書き方のままではシークできない
   対処は「範囲条件へ書き換える(ノーコスト)」+「索引を作る」の順。

   ★ Query Store の値は「集計された履歴」なので、
     SET STATISTICS IO ON で1回ずつ測らなくても、
     過去に流れた全クエリを横断して同じ判断ができる。これが本章の価値。  */


-- Q7. 実行回数の多いクエリ Top10(コンパイル回数つき)
SELECT TOP (10)
       q.query_id,
       LEFT(qt.query_sql_text, 150)                            AS クエリ抜粋,
       SUM(rs.count_executions)                                AS 実行回数,
       q.count_compiles                                        AS コンパイル回数,
       q.avg_compile_duration / 1000.0                         AS 平均コンパイルミリ秒,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0      AS 平均経過ミリ秒,
       SUM(rs.avg_duration * rs.count_executions) / 1000.0     AS 合計経過ミリ秒
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id    = p.plan_id
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, qt.query_sql_text, q.count_compiles, q.avg_compile_duration
ORDER  BY 実行回数 DESC;
GO

/* Q7 の説明 — 実行回数 ≒ コンパイル回数 が意味すること:

   プランがまったく再利用されていない、ということ。
   実行のたびにオプティマイザが動いており、CPU をコンパイルに浪費している。
   疑うべき原因:
     ・リテラルを埋め込んだアドホックSQL(値が違うと別クエリ扱い)
       → パラメーター化する(sp_executesql / 20章)
     ・OPTION (RECOMPILE) の付けすぎ
     ・スキーマ変更・統計更新が頻発している
     ・SET オプションがセッションごとに違う(コンテキスト設定が異なると別プラン)

   逆に「1日に50万回呼ばれる軽いクエリ」は、チューニングより
   呼び出し回数そのものを減らす(アプリ側の N+1 問題)ほうが効くことが多い。  */


-- Q8. 平均の取り方 — A が誤り、B が正しい
------------------------------------------------------------

-- ✗ A: 区間ごとの平均を単純平均している(実行回数の重みが失われる)
SELECT q.query_id,
       AVG(rs.avg_duration) / 1000.0 AS 平均ミリ秒_誤,
       LEFT(qt.query_sql_text, 80)   AS クエリ抜粋
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id    = p.plan_id
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, qt.query_sql_text
ORDER  BY q.query_id;

-- ○ B: 実行回数で重み付けした加重平均
SELECT q.query_id,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS 平均ミリ秒_正,
       SUM(rs.count_executions)                           AS 実行回数,
       COUNT(*)                                           AS 集計区間数,
       LEFT(qt.query_sql_text, 80)                        AS クエリ抜粋
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id    = p.plan_id
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, qt.query_sql_text
ORDER  BY q.query_id;
GO

/* Q8 の説明:
   sys.query_store_runtime_stats の1行は
   「プラン × 時間区間 × 実行種別」ごとの “平均値” である。
   したがって行そのものが既に集計値であり、行を単純に AVG すると
   「10万回実行された区間」と「1回だけ実行された区間」が同じ重みになる。

   例: 区間1 = 1回 × 5,000ms、区間2 = 999回 × 10ms
       A(単純平均) = (5000 + 10) / 2 = 2,505ms  ← 実感とかけ離れている
       B(加重平均) = (1×5000 + 999×10) / 1000 ≈ 15ms ← 正しい

   → 合計は SUM(avg_XXX * count_executions)、
     平均はそれを SUM(count_executions) で割る。このイディオムを丸暗記する。

   なお、平均だけを見ると「たまに極端に遅い」クエリを見逃す。
   max_duration / stdev_duration も併せて見ると、
   SSMS の「変動が大きいクエリ」レポートと同じ観点で
   パラメーター スニッフィング(28章)の候補を見つけられる。            */


-- Q9. プランリグレッションを人工的に起こして検出する
------------------------------------------------------------

-- Q9-1. OrderDate に非クラスタ化インデックスを作る
CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate);
GO

-- Q9-2. Q4-c とまったく同じテキストのクエリを 20 回流す(良いプラン)
--       プラン       : Index Seek (IX_OrdersBig_OrderDate)
--       論理読み取り : 20 前後
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01'
  AND  OrderDate <  '2023-07-01';
GO 20

-- Q9-3. インデックスを削除する(= 現場で起きる「誰かが索引を消した」を再現)
DROP INDEX IX_OrdersBig_OrderDate ON dbo.OrdersBig;
GO

-- Q9-4. まったく同じクエリをもう一度 20 回流す(悪いプラン)
--       プラン       : Clustered Index Scan (PK_OrdersBig)
--       論理読み取り : 約 6,000
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01'
  AND  OrderDate <  '2023-07-01';
GO 20

-- Q9-5. フラッシュ
EXEC sys.sp_query_store_flush_db;
GO

-- Q9-a. まず「複数のプランを持つクエリ」を洗い出す
SELECT q.query_id,
       COUNT(DISTINCT p.plan_id)    AS プラン数,
       LEFT(qt.query_sql_text, 150) AS クエリ抜粋
FROM   sys.query_store_query      AS q
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_plan       AS p  ON p.query_id       = q.query_id
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 1
ORDER  BY プラン数 DESC;
GO

-- Q9-b. ★本題: プランごとの成績表を出して比較する
WITH PlanStats AS (
    SELECT p.query_id,
           p.plan_id,
           p.is_forced_plan,
           p.is_parallel_plan,
           SUM(rs.count_executions)                                   AS 実行回数,
           SUM(rs.avg_duration * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0         AS 平均経過ミリ秒,
           SUM(rs.avg_cpu_time * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0         AS 平均CPUミリ秒,
           SUM(rs.avg_logical_io_reads * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0)                  AS 平均論理読み取り,
           SUM(rs.avg_rowcount * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0)                  AS 平均返却行数,
           MIN(rs.first_execution_time)                               AS 初回実行,
           MAX(rs.last_execution_time)                                AS 最終実行
    FROM   sys.query_store_plan          AS p
    JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    GROUP  BY p.query_id, p.plan_id, p.is_forced_plan, p.is_parallel_plan
)
SELECT ps.query_id,
       ps.plan_id,
       ps.is_forced_plan        AS 強制中,
       ps.is_parallel_plan      AS 並列プランか,
       ps.実行回数,
       ps.平均経過ミリ秒,
       ps.平均CPUミリ秒,
       ps.平均論理読み取り,
       ps.平均返却行数,
       ps.初回実行,
       ps.最終実行,
       CAST(p.query_plan AS XML) AS 実行プラン,     -- クリックするとプランが開く
       LEFT(qt.query_sql_text, 150) AS クエリ抜粋
FROM   PlanStats AS ps
JOIN   sys.query_store_plan       AS p  ON p.plan_id        = ps.plan_id
JOIN   sys.query_store_query      AS q  ON q.query_id       = ps.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  ps.query_id IN (SELECT query_id
                       FROM   sys.query_store_plan
                       GROUP  BY query_id
                       HAVING COUNT(*) > 1)
  AND  qt.query_sql_text NOT LIKE N'%query_store%'
ORDER  BY ps.query_id, ps.平均経過ミリ秒;
GO

-- Q9-c. (発展)劣化倍率で自動抽出する — SSMS「回帰したクエリ」と同じ考え方
WITH PlanStats AS (
    SELECT p.query_id,
           p.plan_id,
           SUM(rs.count_executions)                                AS 実行回数,
           SUM(rs.avg_duration * rs.count_executions)
               / NULLIF(SUM(rs.count_executions), 0) / 1000.0      AS 平均ミリ秒,
           MAX(rs.last_execution_time)                             AS 最終実行
    FROM   sys.query_store_plan          AS p
    JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    GROUP  BY p.query_id, p.plan_id
),
Ranked AS (
    SELECT ps.*,
           MIN(ps.平均ミリ秒) OVER (PARTITION BY ps.query_id) AS 最良平均ミリ秒,
           ROW_NUMBER() OVER (PARTITION BY ps.query_id
                              ORDER BY ps.最終実行 DESC)      AS 直近順
    FROM   PlanStats AS ps
    WHERE  ps.実行回数 >= 5          -- サンプルが少ないプランはノイズなので除外
)
SELECT r.query_id,
       r.plan_id                                     AS 現行プラン,
       r.平均ミリ秒                                   AS 現行平均ミリ秒,
       r.最良平均ミリ秒,
       CAST(r.平均ミリ秒 / NULLIF(r.最良平均ミリ秒, 0)
            AS DECIMAL(10,1))                        AS 劣化倍率,
       r.実行回数,
       r.最終実行,
       LEFT(qt.query_sql_text, 150)                  AS クエリ抜粋
FROM   Ranked AS r
JOIN   sys.query_store_query      AS q  ON q.query_id       = r.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  r.直近順 = 1
  AND  r.平均ミリ秒 > r.最良平均ミリ秒 * 2
  AND  qt.query_sql_text NOT LIKE N'%query_store%'
ORDER  BY 劣化倍率 DESC;
GO

/* Q9 の答え:

   劣化したプラン = Clustered Index Scan のプラン(後から記録されたほう)。
     ・平均論理読み取り  約 20 → 約 6,000(300 倍)
     ・平均経過ミリ秒    数ミリ秒 → 数十〜百数十ミリ秒
     ・最終実行         こちらのほうが新しい = 「今も遅いプランが動いている」

   「サーバーが混んでいて遅かっただけ」ではないと断定できる根拠:

     ① 平均返却行数(avg_rowcount)が両プランで同じ。
        → 扱うデータ量は変わっていない。「データが増えたから遅い」ではない。
     ② 平均論理読み取りページ数が桁で増えている。
        論理読み取りはメモリ上のページアクセス回数であり、
        他人の負荷・ディスク速度・CPU の空き具合に左右されない(18章)。
        これが増えたということは「読む量そのものが増えた」= プランが変わった証拠。
     ③ plan_id が別になっており、切り替わった時刻(初回実行)が特定できる。
     ④ CPU 時間も同様に増えている(単なる待ち時間の増加ではない)。

   → 「同じクエリ・同じ返却行数なのに、論理読み取りと CPU が桁で増え、
      その時点でプランIDが変わっている」の4条件が揃えば
      プランリグレッションと断定してよい。

   現実の原因は今回の「索引の削除」以外にも、統計情報の更新(27章)、
   パラメーター スニッフィング(28章)、互換性レベルの変更、
   データ量の増加によるティッピングポイント超え(18章)などがある。      */


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q10. 良かったほうのプランを強制する
------------------------------------------------------------

-- Q10-0. 強制するプランは Index Seek のプラン。
--        Q9-3 で索引を削除しているので、まず作り直す。
--        (索引が無いまま Seek プランを強制しても失敗する = それが Q11 の題材)
CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate);
GO

-- Q10-1. 対象の query_id と「最も速いプラン」の plan_id を求めて強制する
DECLARE @query_id INT, @plan_id INT;

-- 複数プランを持つクエリのうち、プラン数が最も多いものを対象にする
SELECT TOP (1) @query_id = p.query_id
FROM   sys.query_store_plan AS p
JOIN   sys.query_store_query AS q ON q.query_id = p.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  qt.query_sql_text LIKE N'%OrdersBig%2023-06-01%'
  AND  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY p.query_id
HAVING COUNT(*) > 1
ORDER  BY COUNT(*) DESC;

-- そのクエリの中で加重平均経過時間が最小のプラン = 最良プラン
SELECT TOP (1) @plan_id = p.plan_id
FROM   sys.query_store_plan          AS p
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE  p.query_id = @query_id
GROUP  BY p.plan_id
ORDER  BY SUM(rs.avg_duration * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0) ASC;

PRINT N'対象 query_id = ' + CAST(@query_id AS NVARCHAR(20))
    + N' / 強制する plan_id = ' + CAST(@plan_id AS NVARCHAR(20));

EXEC sys.sp_query_store_force_plan @query_id = @query_id, @plan_id = @plan_id;
GO

/* (別解) query_id / plan_id を Q9-b の結果から目で読んでリテラルで書いてもよい。
     EXEC sys.sp_query_store_force_plan @query_id = 3, @plan_id = 4;
   実務では SSMS の「上位のリソースを消費するクエリ」画面で
   プランの丸を選んで「プランの強制」ボタンを押すのが最も速い。       */

-- Q10-2. 強制されているプランを確認する
--        ★この確認クエリは、運用で定期的に流すべきもの
SELECT q.query_id,
       p.plan_id,
       p.is_forced_plan                 AS 強制中,
       p.plan_forcing_type_desc         AS 強制の種類,     -- MANUAL / AUTO
       p.force_failure_count            AS 強制失敗回数,
       p.last_force_failure_reason      AS 最終失敗理由コード,
       p.last_force_failure_reason_desc AS 最終失敗理由,
       LEFT(qt.query_sql_text, 150)     AS クエリ抜粋
FROM   sys.query_store_plan       AS p
JOIN   sys.query_store_query      AS q  ON q.query_id       = p.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  p.is_forced_plan = 1;
GO

-- Q10-3. 強制したプランで動くことを確認する(同じクエリを再実行)
--        Ctrl+M を ON にして実行し、プランのプロパティに
--        「UsePlan = true」相当の情報が出ることを確認してもよい。
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01'
  AND  OrderDate <  '2023-07-01';
GO 5

EXEC sys.sp_query_store_flush_db;
GO

-- 強制後の実行が、強制したプランの count_executions に加算されていることを確認
SELECT p.plan_id,
       p.is_forced_plan            AS 強制中,
       SUM(rs.count_executions)    AS 実行回数,
       MAX(rs.last_execution_time) AS 最終実行
FROM   sys.query_store_plan          AS p
JOIN   sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE  p.query_id IN (SELECT query_id FROM sys.query_store_plan
                      GROUP BY query_id HAVING COUNT(*) > 1)
GROUP  BY p.plan_id, p.is_forced_plan
ORDER  BY p.plan_id;
GO

/* Q10 のポイント:
   ・強制はデータベース内に永続化される。SQL Server を再起動しても解除されない。
   ・内部的には USE PLAN ヒントを付けたのと同じ効果だが、
     アプリのSQLを1文字も変えずに適用できる。これが実務上の最大の価値。
   ・plan_forcing_type_desc が MANUAL なら人手、AUTO なら
     自動チューニング(FORCE_LAST_GOOD_PLAN / 2017+ Enterprise)による強制。 */


-- Q11. 強制を失敗させて、検知の方法を学ぶ
------------------------------------------------------------

-- Q11-1. 強制したプランが依存しているインデックスを削除する
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate ON dbo.OrdersBig;
GO

-- Q11-2. 同じクエリを数回実行する(強制の再現が試みられ、失敗する)
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-06-01'
  AND  OrderDate <  '2023-07-01';
GO 5

EXEC sys.sp_query_store_flush_db;
GO

-- Q11-3. 強制の失敗を検知する ★運用ではこれを監視する
SELECT q.query_id,
       p.plan_id,
       p.is_forced_plan                 AS 強制中,
       p.force_failure_count            AS 失敗回数,
       p.last_force_failure_reason      AS 失敗理由コード,
       p.last_force_failure_reason_desc AS 失敗理由,
       LEFT(qt.query_sql_text, 150)     AS クエリ抜粋
FROM   sys.query_store_plan       AS p
JOIN   sys.query_store_query      AS q  ON q.query_id       = p.query_id
JOIN   sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE  p.is_forced_plan = 1;
GO

/* Q11 の答え:

   last_force_failure_reason_desc = 'NO_INDEX'
     … 強制したプランが参照しているインデックスが存在しない、の意味。
   force_failure_count が実行のたびに増えていく。

   ★ここが最大の学び:
     is_forced_plan は 1 のまま(= 強制されているように見える)なのに、
     実際には強制が効かず、別のプラン(Clustered Index Scan)で実行されている。
     エラーは一切出ない。黙って劣化する。

     → だから「強制した」で終わらせず、
       force_failure_count と last_force_failure_reason_desc を
       定期的に監視する仕組みが必要。

   「プランを強制したあとにインデックスを削除してはいけない」理由:
     強制されたプランは特定のインデックスを前提に組まれている。
     18章で学んだとおり「使われていないインデックスは削除候補」だが、
     sys.dm_db_index_usage_stats 上の使用回数が少なくても、
     強制プランが依存していれば削除してはならない。
     → プランを強制したら「そのプランが依存するインデックスは削除禁止」として
       台帳で管理すること。

   主な失敗理由(last_force_failure_reason_desc):
     NONE                … 正常
     NO_INDEX            … 依存インデックスが無い(最頻出)
     NO_PLAN             … プランを生成できなかった(オブジェクト定義の変更)
     VIEW_COMPILE_FAILED … ビューのコンパイル失敗
     IS_TRIVIAL          … 自明なプランなので強制対象外
     TIMEOUT             … 強制付きコンパイルがタイムアウト
     ONLINE_INDEX_BUILD  … オンライン索引構築中(一時的)
     GENERAL_FAILURE     … その他                                        */

-- Q11-4. 強制を解除する
DECLARE @q2 INT, @p2 INT;
SELECT TOP (1) @q2 = query_id, @p2 = plan_id
FROM   sys.query_store_plan
WHERE  is_forced_plan = 1;

IF @q2 IS NOT NULL
    EXEC sys.sp_query_store_unforce_plan @query_id = @q2, @plan_id = @p2;
GO

-- 解除できたことを確認(0件になれば成功)
SELECT query_id, plan_id, is_forced_plan
FROM   sys.query_store_plan
WHERE  is_forced_plan = 1;
GO


-- Q12. クエリ単位の待機統計(★SQL Server 2017 以降)
------------------------------------------------------------
--     2016 では sys.query_store_wait_stats が存在しないためエラーになる。
--     その場合はこのバッチを飛ばしてよい(以降のバッチは実行できる)。
SELECT TOP (10)
       q.query_id,
       ws.wait_category_desc                       AS 待機カテゴリ,
       SUM(ws.total_query_wait_time_ms)            AS 合計待機ミリ秒,   -- ★ミリ秒
       SUM(ws.total_query_wait_time_ms)
           / NULLIF(SUM(rs.count_executions), 0)   AS 実行1回あたり待機ミリ秒,
       MAX(ws.max_query_wait_time_ms)              AS 最大待機ミリ秒,
       SUM(rs.count_executions)                    AS 実行回数,
       LEFT(qt.query_sql_text, 150)                AS クエリ抜粋
FROM   sys.query_store_wait_stats    AS ws
JOIN   sys.query_store_plan          AS p  ON p.plan_id        = ws.plan_id
JOIN   sys.query_store_query         AS q  ON q.query_id       = p.query_id
JOIN   sys.query_store_query_text    AS qt ON qt.query_text_id = q.query_text_id
JOIN   sys.query_store_runtime_stats AS rs
       ON  rs.plan_id                   = ws.plan_id
       AND rs.runtime_stats_interval_id = ws.runtime_stats_interval_id
       AND rs.execution_type            = ws.execution_type
WHERE  qt.query_sql_text NOT LIKE N'%query_store%'
GROUP  BY q.query_id, ws.wait_category_desc, qt.query_sql_text
ORDER  BY 合計待機ミリ秒 DESC;
GO

/* Q12 の答え:

   この演習の負荷では、YEAR(OrderDate) の全件走査クエリで
   CPU / Buffer IO(初回のディスク読み込み)/ Parallelism あたりが
   上位に出るはず(環境により異なる)。

   ★ Query Store の待機統計にしかできないこと:
     ① 待機を「クエリ単位・プラン単位」に分解できる。
        23章の sys.dm_os_wait_stats は「サーバー全体で PAGEIOLATCH_SH が60%」
        までしか言えず、「どのクエリのせいか」に到達できない。
     ② 履歴が残るので、「昨夜22時のバッチ時間帯だけ Lock 待ちが増えた」を
        後から追える。dm_os_wait_stats は累積値で再起動リセットのため、
        差分を自分で取り続ける仕組みが要る。
     ③ 同じクエリの「プランAのときは Buffer IO 待ち、プランBでは Parallelism 待ち」
        というプラン別の比較ができる。

   ★ Query Store の待機統計では分からないこと:
     ① 待機種別がカテゴリに丸められている。
        「Lock」までは分かるが LCK_M_X / LCK_M_S の区別はつかない。
        厳密な待機種別は sys.dm_os_wait_stats(23章)や
        拡張イベント(25章)で確定させる。
     ② 「誰に待たされたか」(ブロッカー)は分からない。
        ブロッキングの犯人特定は sys.dm_exec_requests の
        blocking_session_id など(23章・26章)の担当。
     ③ Query Store が有効なデータベース、かつ収集対象になったクエリしか見えない。

   → 実務の型:
       「どのクエリが待っているか」を Query Store で絞り込み、
       「厳密に何を待っているか」を DMV / 拡張イベントで確定させる。      */


-- Q13.(記述問題)プランを強制する前に確認すべきこと
------------------------------------------------------------
/*
   状況: あるクエリが先週まで平均 30ms、今週は平均 4,200ms。プランIDも変わった。

   ── 優先順位つきの確認事項 ──────────────────────────

   【1】統計情報が古くなっていないか(最有力・最も安く直せる)     → 27章
        調べ方:
          SELECT s.name, sp.last_updated, sp.rows, sp.rows_sampled,
                 sp.modification_counter
          FROM   sys.stats AS s
          CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
          WHERE  s.object_id = OBJECT_ID('dbo.対象テーブル');
        判断基準:
          ・last_updated が劣化した日時の直前 → 統計更新がプラン変化の引き金。
          ・modification_counter が rows に対して大きい → 統計が実態から乖離。
          ・rows_sampled / rows が極端に小さい → サンプリング率不足。
        対処: UPDATE STATISTICS dbo.対象テーブル WITH FULLSCAN;
              これだけで元のプランに戻ることが非常に多い。

   【2】パラメーター スニッフィングではないか                     → 28章
        調べ方:
          ・Query Store でそのクエリの stdev_duration / max_duration を見る。
            平均は普通なのにばらつきが極端に大きい = スニッフィングの典型。
            SSMS の「変動が大きいクエリ」レポートが同じ観点。
          ・プランXMLの ParameterCompiledValue と ParameterRuntimeValue を比較する。
            コンパイル時の値と実行時の値が大きく違えば確定。
        対処: OPTION (RECOMPILE) / OPTIMIZE FOR / OPTIMIZE FOR UNKNOWN /
              変数への代入 / プロシージャの分割。

   【3】プランが依存するインデックスや実行環境が変わっていないか   → 18章
        調べ方:
          ・sys.indexes / sys.index_columns で索引の追加・削除・無効化を確認。
          ・sys.query_store_plan の compatibility_level を新旧プランで比較。
            互換性レベルが変わっていればカーディナリティ推定器の世代が変わった。
          ・engine_version 列で累積更新の適用時期と突き合わせる。
          ・MAXDOP / コストしきい値などサーバー設定の変更履歴。

   【4】そもそもデータ量が変わっていないか
        調べ方:
          ・Query Store の avg_rowcount を新旧プランで比較する。
            返却行数が10倍になっているなら、それは劣化ではなく
            「正しくプランが切り替わった」だけかもしれない(ティッピングポイント/18章)。
          ・この場合、強制すると逆に遅くなる。

   【5】クエリ自体が非SARGableではないか                          → 18章
        書き換えで済むならノーコスト。強制よりはるかに良い。

   ── プランを強制することの長期的なリスク ──────────────

   ① データは変化し続ける。今日の最適プランは、行数が10倍になった半年後には
      最悪プランになりうる。強制はオプティマイザの判断を「永久に凍結」する。
   ② 統計を更新しても、インデックスを追加しても、プランが改善しなくなる。
      本来得られたはずの改善の芽を摘む。
   ③ 依存インデックスが削除されると NO_INDEX で静かに失敗する(Q11)。
      監視していなければ誰も気づかない。
   ④ 「なぜ強制されているのか誰も知らない」設定が数年残る。属人化・技術的負債。
   ⑤ 根本原因(統計・スニッフィング・設計)が温存されるため、
      同じ問題が別のクエリで再発する。

   ── 結論 ──────────────────────────────────
   プランの強制は「解熱剤」であって「治療」ではない。
   障害対応中の止血としては有効だが、必ず
     ・課題管理票に起票し、根本原因の調査タスクを立てる
     ・「いつ外すか」を決める
     ・強制中プランの一覧(Q10-2)を定期レビューする
   をセットにすること。それができないなら、そもそも強制すべきではない。

   なお 2017+ Enterprise なら
     ALTER DATABASE ... SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
   により、効果がなければ自動で解除される「安全な強制」も選べる。
   有効化していなくても sys.dm_db_tuning_recommendations は読めるので、
   まず推奨事項を眺めてみるとよい。
   2022+ なら sys.sp_query_store_set_hints でヒントだけを外付けする、
   より穏当な手段もある。
*/


------------------------------------------------------------
-- Q14. 【必須】後片付け — 演習前の状態に戻す
------------------------------------------------------------

-- Q14-1. 強制されているプランをすべて解除する
DECLARE @fq INT, @fp INT;
DECLARE force_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT query_id, plan_id
    FROM   sys.query_store_plan
    WHERE  is_forced_plan = 1;

OPEN force_cur;
FETCH NEXT FROM force_cur INTO @fq, @fp;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @fq, @plan_id = @fp;
    PRINT N'解除: query_id=' + CAST(@fq AS NVARCHAR(20))
        + N' plan_id=' + CAST(@fp AS NVARCHAR(20));
    FETCH NEXT FROM force_cur INTO @fq, @fp;
END
CLOSE force_cur;
DEALLOCATE force_cur;
GO

-- 確認: 0件になっていれば成功
SELECT query_id, plan_id, is_forced_plan
FROM   sys.query_store_plan
WHERE  is_forced_plan = 1;
GO

-- Q14-2. この演習で作成したインデックスを削除する
--        (DROP INDEX IF EXISTS は SQL Server 2016+)
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate ON dbo.OrdersBig;
GO

-- 確認: PK_OrdersBig(CLUSTERED)だけが残っていれば成功
SELECT i.name AS インデックス名, i.type_desc AS 種別
FROM   sys.indexes AS i
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
ORDER  BY i.index_id;
GO

-- Q14-3. Query Store の記録内容をすべて消す
--        ★必ず OFF にする「前」に CLEAR すること。
--          逆順だと記録データがDB内に残り、容量を占有し続ける。
ALTER DATABASE SalesLearning SET QUERY_STORE CLEAR;
GO

-- Q14-4. Q1 で記録した元の状態に戻す
--        SalesLearning はもともと Query Store が OFF だったはずなので OFF に戻す。
--        ★もし Q1 の時点で既に ON(SQL Server 2022 の新規DBなど)だった場合は、
--          この行を実行せず、Q1 で控えたオプション値に戻すこと。例:
--            ALTER DATABASE SalesLearning SET QUERY_STORE
--            ( OPERATION_MODE = READ_WRITE,
--              INTERVAL_LENGTH_MINUTES = 60,
--              DATA_FLUSH_INTERVAL_SECONDS = 900,
--              MAX_STORAGE_SIZE_MB = 1000,
--              QUERY_CAPTURE_MODE = AUTO,
--              SIZE_BASED_CLEANUP_MODE = AUTO,
--              STALE_QUERY_THRESHOLD_DAYS = 30 );
ALTER DATABASE SalesLearning SET QUERY_STORE = OFF;
GO

-- Q14-5. 元に戻ったことを確認する(Q1 の出力と見比べる)
SELECT desired_state_desc           AS 設定上の状態,
       actual_state_desc            AS 実際の状態,
       readonly_reason              AS 読取専用理由,
       current_storage_size_mb      AS 現在サイズMB,
       max_storage_size_mb          AS 上限MB,
       interval_length_minutes      AS 集計間隔分,
       query_capture_mode_desc      AS 収集モード
FROM   sys.database_query_store_options;
GO

/* 後片付けの補足:

   ・OFF にしただけでは記録データは消えない。CLEAR → OFF の順が正しい。
   ・逆に、本番環境では Query Store は「有効のまま運用する」のが正解。
     ここで OFF に戻すのは、あくまで学習環境を演習前の状態に揃えるため。

   ・本番運用で必ず監視すべき2点:
       ① actual_state_desc が READ_ONLY に落ちていないか
          (readonly_reason = 65536 なら MAX_STORAGE_SIZE_MB 到達)
       ② is_forced_plan = 1 のプランが放置されていないか

   ・演習をやり直したい / 途中でおかしくなった場合:
       ALTER DATABASE SalesLearning SET QUERY_STORE CLEAR;
     でいつでも記録を初期化できる。
     dbo.OrdersBig 自体を作り直したいなら sample-db/03_bulk_data.sql を再実行する。
     既存の小さいテーブル(Orders/OrderDetails 等)には一切影響しない。      */
