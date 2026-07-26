/* ============================================================
   解答例 23 — 待機統計とボトルネック特定
   対象演習: exercises/23_wait_statistics.md

   前提:
     - VIEW SERVER STATE 権限があること
     - sample-db/03_bulk_data.sql を実行済み(dbo.OrdersBig 100万行)
     - dbo.OrdersBig に非クラスタ化インデックスが1本も無い状態
       (18章 Q13 の後片付け済み。これがあるから大きなスキャンが起きる)
     - sample-db/05_workload.sql の【準備】セクションを実行済み
       (dbo.WorkloadTest 1000行)

   ★ SSMS のクエリウィンドウを5枚開いてから始めること。
       W1/W2 = 読み取り負荷(セクションA)
       W3    = 書き込み負荷(セクションB)/ ブロッカー(セクションC)
       W4    = 観測(セクションE)
       W5    = 計測(スナップショット差分)  ← このファイルの Q6/Q8 を流す窓

   ★ 最後の Q13(後片付け)まで必ず実行すること。
   ※ 数値はすべて「環境により前後する目安」。絶対値ではなく比率と傾向で読む。
   ============================================================ */
USE SalesLearning;
GO

SET NOCOUNT ON;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. サービス起動時刻と稼働時間
SELECT sqlserver_start_time                            AS 起動時刻,
       DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS 稼働時間H,
       DATEDIFF(DAY,  sqlserver_start_time, GETDATE()) AS 稼働日数
FROM   sys.dm_os_sys_info;
GO

/* Q1 の説明:
   sys.dm_os_wait_stats は「サービス起動時点(または最後の CLEAR)からの累計」。
   仮に稼働 30 日なら、そこに見えているのは 30 日ぶんを平均した姿でしかない。

     ・今日の 14:00 に起きた障害は、30 日ぶんの海に沈んで見えない
     ・月次バッチ・インデックス再構築・過去の一度きりの事故が
       いつまでも上位に居座る
     ・逆に「起動直後」だと、まだ何も溜まっておらず当てにならない

   → 「今」を診断したいなら、累計を見てはいけない。
     Q6 以降のスナップショット差分を取る。
     累計は「このサーバーの長期的な体質」を見るときにだけ使う。       */


-- Q2. フィルタなしの上位10件(= ノイズだらけの状態を体感する)
SELECT TOP (10)
       wait_type            AS 待機タイプ,
       waiting_tasks_count  AS 待機回数,
       wait_time_ms         AS 合計待機ms,
       signal_wait_time_ms  AS シグナル待機ms,
       max_wait_time_ms     AS 最大待機ms
FROM   sys.dm_os_wait_stats
ORDER  BY wait_time_ms DESC;
GO

/* Q2 の説明:
   ほぼ確実に、次のような「アイドル待機」が上位を占める。

     XE_TIMER_EVENT                    拡張イベントのタイマー
     SLEEP_TASK / SLEEP_SYSTEMTASK     定期起床タスクが次の起床まで寝ている
     LAZYWRITER_SLEEP                  遅延書き込みプロセスの休止
     BROKER_TASK_STOP / BROKER_TO_FLUSH  Service Broker のキュー待ち
     CHECKPOINT_QUEUE                  次のチェックポイント指示待ち
     DIRTY_PAGE_POLL                   ダーティページのポーリング
     REQUEST_FOR_DEADLOCK_SEARCH       5秒ごとのデッドラックモニター
     SQLTRACE_INCREMENTAL_FLUSH_SLEEP  既定トレースのフラッシュ間隔
     DISPATCHER_QUEUE_SEMAPHORE        ディスパッチャの仕事待ち

   なぜ上位に来るか:
     これらは「バックグラウンドのシステムタスクが、仕事が無いので寝ている」時間。
     ユーザーを一切待たせていないのに、アイドル時間ぶん延々と加算され続ける。
     したがって「暇なサーバーほど、これらが上位を独占する」。

   → 除外リストを持たない待機統計クエリは実務では使い物にならない。 */


-- Q3. アイドル待機を除外し、内訳・割合・累積割合まで出す【この章の主力クエリ】
WITH FilteredWaits AS
(
    SELECT wait_type,
           waiting_tasks_count,
           wait_time_ms,
           signal_wait_time_ms,
           max_wait_time_ms,
           wait_time_ms - signal_wait_time_ms AS resource_wait_ms
    FROM   sys.dm_os_wait_stats
    WHERE  waiting_tasks_count > 0
      AND  wait_time_ms > 0
      -- ▼ 無視してよい待機(アイドル/バックグラウンド)の除外リスト ▼
      AND  wait_type NOT IN
           (N'BROKER_EVENTHANDLER',      N'BROKER_RECEIVE_WAITFOR',
            N'BROKER_TASK_STOP',         N'BROKER_TO_FLUSH',
            N'BROKER_TRANSMITTER',       N'CHECKPOINT_QUEUE',
            N'CHKPT',                    N'CLR_AUTO_EVENT',
            N'CLR_MANUAL_EVENT',         N'CLR_SEMAPHORE',
            N'DBMIRROR_DBM_EVENT',       N'DBMIRROR_EVENTS_QUEUE',
            N'DBMIRROR_WORKER_QUEUE',    N'DBMIRRORING_CMD',
            N'DIRTY_PAGE_POLL',          N'DISPATCHER_QUEUE_SEMAPHORE',
            N'EXECSYNC',                 N'FSAGENT',
            N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
            N'HADR_CLUSAPI_CALL',        N'HADR_LOGCAPTURE_WAIT',
            N'HADR_NOTIFICATION_DEQUEUE',N'HADR_TIMER_TASK',
            N'HADR_WORK_QUEUE',          N'KSOURCE_WAKEUP',
            N'LAZYWRITER_SLEEP',         N'LOGMGR_QUEUE',
            N'MEMORY_ALLOCATION_EXT',    N'ONDEMAND_TASK_QUEUE',
            N'PWAIT_ALL_COMPONENTS_INITIALIZED',
            N'QDS_ASYNC_QUEUE',          N'QDS_SHUTDOWN_QUEUE',
            N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
            N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
            N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH',
            N'RESOURCE_QUEUE',           N'SERVER_IDLE_CHECK',
            N'SLEEP_BPOOL_FLUSH',        N'SLEEP_DBSTARTUP',
            N'SLEEP_DCOMSTARTUP',        N'SLEEP_MASTERDBREADY',
            N'SLEEP_MASTERMDREADY',      N'SLEEP_MASTERUPGRADED',
            N'SLEEP_MSDBSTARTUP',        N'SLEEP_SYSTEMTASK',
            N'SLEEP_TASK',               N'SLEEP_TEMPDBSTARTUP',
            N'SNI_HTTP_ACCEPT',          N'SP_SERVER_DIAGNOSTICS_SLEEP',
            N'SQLTRACE_BUFFER_FLUSH',    N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
            N'SQLTRACE_WAIT_ENTRIES',    N'WAIT_FOR_RESULTS',
            N'WAITFOR',                  N'WAITFOR_TASKSHUTDOWN',
            N'XE_DISPATCHER_JOIN',       N'XE_DISPATCHER_WAIT',
            N'XE_TIMER_EVENT')
      AND  wait_type NOT LIKE N'SLEEP[_]%'
      AND  wait_type NOT LIKE N'PREEMPTIVE[_]XE[_]%'
      AND  wait_type NOT LIKE N'PARALLEL[_]REDO[_]%'
      AND  wait_type NOT LIKE N'WAIT[_]XTP[_]%'
      AND  wait_type NOT LIKE N'PWAIT[_]DIRECTLOGCONSUMER[_]%'
      -- ※ HADR_SYNC_COMMIT はあえて除外しない(実際にユーザーを待たせている待機)
),
Ranked AS
(
    SELECT *,
           CAST(100.0 * wait_time_ms
                / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5, 2)) AS pct,
           ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)                AS rn
    FROM   FilteredWaits
)
SELECT rn                                                        AS 順位,
       wait_type                                                 AS 待機タイプ,
       pct                                                       AS 割合パーセント,
       SUM(pct) OVER (ORDER BY rn ROWS UNBOUNDED PRECEDING)      AS 累積パーセント,
       waiting_tasks_count                                       AS 待機回数,
       wait_time_ms                                              AS 合計待機ms,
       resource_wait_ms                                          AS リソース待機ms,
       signal_wait_time_ms                                       AS シグナル待機ms,
       CAST(wait_time_ms * 1.0
            / NULLIF(waiting_tasks_count, 0) AS DECIMAL(18, 2))  AS 平均待機ms,
       max_wait_time_ms                                          AS 最大待機ms
FROM   Ranked
WHERE  rn <= 15
ORDER  BY rn;
GO

/* Q3 の読み方(手順):
   ① 累積パーセントが 80% を超えるところまでを見る。それ以下は雑音。
      実務では上位 3〜5 種類で 80〜95% を占めるのが普通。
   ② 上位の待機タイプを「読み分け表」(docs 4節)で引く。
   ③ リソース待機 / シグナル待機の内訳で「資源側か CPU 側か」を決める。
   ④ 平均待機ms で「回数の問題か、1回の長さの問題か」を決める。

   ※ 学習環境(誰も使っていない開発機)では、そもそも実負荷の待機が
     ほとんど無いため上位が空っぽに近いこともある。それが正常。
     だから Q6 以降で実際に負荷を掛ける。                          */


-- Q4. シグナル待機の比率で CPU 圧迫を見る
SELECT SUM(signal_wait_time_ms)                        AS シグナル待機合計ms,
       SUM(wait_time_ms)                               AS 待機合計ms,
       CAST(100.0 * SUM(signal_wait_time_ms)
            / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5, 2)) AS シグナル比率パーセント
FROM   sys.dm_os_wait_stats
WHERE  waiting_tasks_count > 0;

-- Q4(裏取り). runnable queue の長さ = CPU の順番待ちの行列
SELECT scheduler_id         AS スケジューラ,
       cpu_id               AS 論理CPU,
       current_tasks_count  AS 担当タスク数,
       runnable_tasks_count AS CPU待ち行列,        -- ★ 常時 1 以上なら CPU 圧迫
       active_workers_count AS アクティブワーカー,
       work_queue_count     AS ワーカー不足の目印  -- ★ 0 より大 = ワーカー枯渇
FROM   sys.dm_os_schedulers
WHERE  status = 'VISIBLE ONLINE'
ORDER  BY scheduler_id;
GO

/* Q4 の判断基準(目安。絶対的な閾値ではない):
     〜10%    CPU に余裕あり。ボトルネックは資源側
     10〜25%  要注意。負荷が上がると CPU が先に詰まる可能性
     25%以上  CPU 圧迫を強く疑う

   ⚠ ただし「シグナル比率が高い = CPU を増設せよ」ではない。
     CPU が詰まる原因の大半は「CPU が少ない」ではなく
     「非効率なプランが CPU を浪費している」。
     18章(SARGability)・27章(統計)・29章(並列)を先に疑うこと。   */


-- Q5. wait_time_ms とリソース待機の関係(SQL は不要。式と解釈)
/* Q5 の解答:

   【式】
       wait_time_ms = リソース待機(SUSPENDED) + signal_wait_time_ms(RUNNABLE)

       ⇒ リソース待機ms = wait_time_ms - signal_wait_time_ms

   【なぜそうなるか】
     ① RUNNING   : 実行中。ページが無いと分かり、I/O を発行して自分から降りる
     ② SUSPENDED : waiter list に並ぶ。ここが「リソース待機」
     ③ RUNNABLE  : I/O 完了のシグナルを受けて行列の最後尾へ。ここが「シグナル待機」
     ④ RUNNING   : 順番が回って再開。このとき ②+③ が wait_stats に加算される

   【ケース1】wait 100万ms / signal 5万ms → リソース待機 95万ms(95%)
       資源(ディスク)そのものが遅い or 読みすぎ。
       打ち手: インデックス設計で読むページを減らす(18章) → メモリ増設 → ストレージ。
       sys.dm_io_virtual_file_stats の読み平均ms と Page Life Expectancy を裏取りする。

   【ケース2】wait 100万ms / signal 70万ms → シグナル待機 70万ms(70%)
       I/O 自体は速い(30万ms)。完了後に CPU に戻れず足止めされている。
       打ち手: ストレージを速くしても効果はほぼゼロ。
       CPU を食っているクエリを潰す(sys.dm_exec_query_stats の total_worker_time)、
       runnable_tasks_count を確認、並列度設定を見直す。

   → 同じ待機タイプ・同じ合計時間でも、内訳次第で打ち手が正反対になる。
     これが「wait_time_ms だけ見てはいけない」理由。                      */
GO


------------------------------------------------------------
-- 応用 — 実際に負荷を掛けて測る
--   ここからは W5(このウィンドウ)で ①→②→③ を順に実行する。
--   #WaitSnapshot は一時テーブルなので、必ず同じセッションで通すこと。
------------------------------------------------------------

-- Q6-①. 【W5】開始スナップショットを撮る
DROP TABLE IF EXISTS #WaitSnapshot;

SELECT wait_type,
       waiting_tasks_count,
       wait_time_ms,
       signal_wait_time_ms,
       CAST(SYSDATETIME() AS DATETIME2(3)) AS captured_at
INTO   #WaitSnapshot
FROM   sys.dm_os_wait_stats;

SELECT N'開始スナップショット取得' AS 状態, SYSDATETIME() AS 時刻;
GO

/* Q6-②. 【W1 と W2】ここで負荷を起動する
   05_workload.sql の「セクションA: 読み取り負荷(既定60秒)」の
   ブロックコメントの中身を W1 と W2 にコピーして、両方で F5。

     WHILE SYSDATETIME() < @End
     BEGIN
         SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'完了';
         SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;
     END;

   OrdersBig に非クラスタ化インデックスが無いので、どちらも
   100万行のフルスキャンになる(それが狙い)。
   2本目のクエリは YEAR() で包んだ非SARGable な書き方(18章)。       */

-- Q6-②(続き). 【W5】60秒待つ(手動で待ってもよい)
WAITFOR DELAY '00:01:00';
GO

-- Q6-③. 【W5】差分を取る = 「その60秒間に何を待ったか」
DECLARE @ElapsedMs BIGINT =
    (SELECT DATEDIFF(MILLISECOND, MIN(captured_at), SYSDATETIME()) FROM #WaitSnapshot);

SELECT @ElapsedMs AS 計測経過ms;

WITH Diff AS
(
    SELECT n.wait_type,
           n.waiting_tasks_count - ISNULL(o.waiting_tasks_count, 0) AS 待機回数,
           n.wait_time_ms        - ISNULL(o.wait_time_ms, 0)        AS 合計待機ms,
           n.signal_wait_time_ms - ISNULL(o.signal_wait_time_ms, 0) AS シグナル待機ms
    FROM   sys.dm_os_wait_stats AS n
    LEFT   JOIN #WaitSnapshot   AS o ON o.wait_type = n.wait_type
    WHERE  n.wait_type NOT LIKE N'SLEEP[_]%'
      AND  n.wait_type NOT LIKE N'XE[_]%'
      AND  n.wait_type NOT LIKE N'BROKER[_]%'
      AND  n.wait_type NOT LIKE N'QDS[_]%'
      AND  n.wait_type NOT LIKE N'PREEMPTIVE[_]XE[_]%'
      AND  n.wait_type NOT IN
           (N'CHECKPOINT_QUEUE', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
            N'DIRTY_PAGE_POLL',  N'REQUEST_FOR_DEADLOCK_SEARCH',
            N'DISPATCHER_QUEUE_SEMAPHORE', N'WAITFOR',
            N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SP_SERVER_DIAGNOSTICS_SLEEP',
            N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'CLR_AUTO_EVENT',
            N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'HADR_LOGCAPTURE_WAIT',
            N'REDO_THREAD_PENDING_WORK', N'SERVER_IDLE_CHECK',
            N'ONDEMAND_TASK_QUEUE', N'RESOURCE_QUEUE')
),
Positive AS
(
    SELECT * FROM Diff WHERE 合計待機ms > 0
)
SELECT TOP (15)
       wait_type                                                  AS 待機タイプ,
       CAST(100.0 * 合計待機ms
            / NULLIF(SUM(合計待機ms) OVER (), 0) AS DECIMAL(5, 2)) AS 割合パーセント,
       待機回数,
       合計待機ms,
       合計待機ms - シグナル待機ms                                 AS リソース待機ms,
       シグナル待機ms,
       CAST(合計待機ms * 1.0
            / NULLIF(待機回数, 0) AS DECIMAL(18, 2))               AS 平均待機ms,
       -- ★ 正規化: 計測期間中、常時何本のスレッドがこの待機で寝ていたか
       CAST(合計待機ms * 1.0
            / NULLIF(@ElapsedMs, 0) AS DECIMAL(10, 2))            AS 待機秒毎秒
FROM   Positive
ORDER  BY 合計待機ms DESC;
GO

/* Q6 のポイント:
   ・#WaitSnapshot は一時テーブル。①と③は必ず同じウィンドウ(セッション)で実行する。
     ウィンドウを閉じると消える。GO でバッチを区切っても消えない。
   ・DECLARE した @ElapsedMs はバッチをまたげないので、③の中で宣言している。
   ・「待機秒毎秒」が本番診断の主役。
       2.5 → 常時 2.5 本のワーカーがこの待機で止まっていた
     論理CPUが 8個のサーバーで PAGEIOLATCH_SH が 6.0 なら深刻。
     この形にすると同時実行数が違うサーバー同士でも比較できる。           */


-- Q7. Q6 の結果の解釈(SQL は不要。文章で答える)
/* Q7 の解答例:

   (1) 典型的には次のいずれかが1位になる。
       ・PAGEIOLATCH_SH   … メモリが少なく OrdersBig が乗り切らない環境
       ・SOS_SCHEDULER_YIELD … メモリが潤沢で全部バッファプールに乗っている環境
       ・CXPACKET / CXCONSUMER … 並列プランが選ばれた環境
       内訳は「合計待機ms - シグナル待機ms」で確認する。
       PAGEIOLATCH_SH は通常リソース待機が主体、
       SOS_SCHEDULER_YIELD はほぼ全部がシグナル待機になる。

   (2) 待機タイプごとの「疑うこと / 次に見るもの」

       PAGEIOLATCH_SH
         疑う  : ① メモリ不足(同じページを何度も読み直している)
                 ② 読みすぎ(インデックスが無い/SELECT * )
                 ③ ストレージが本当に遅い
         次に  : sys.dm_io_virtual_file_stats の読み平均ms(Q10)、
                 sys.dm_os_performance_counters の Page life expectancy、
                 対象クエリの実行プランと論理読み取り数(18章)
         打ち手: まずインデックスで読むページ数を減らす。次にメモリ、最後にストレージ。

       SOS_SCHEDULER_YIELD
         疑う  : 平均待機ms が 0.1ms 未満 → CPU 不足ではなく「CPU の無駄遣い」
                 平均待機ms が数ms以上   → 本当に CPU 圧迫
         次に  : シグナル比率(Q4)、sys.dm_os_schedulers.runnable_tasks_count、
                 sys.dm_exec_query_stats の total_worker_time 上位
         打ち手: 非SARGable な条件の解消、不足インデックス、スカラーUDFの排除。

       CXPACKET / CXCONSUMER
         疑う  : CXCONSUMER 中心ならほぼ無害。CXPACKET 中心なら並列の歪み(skew)。
         次に  : 実際の実行プランでスレッドごとの実行行数、
                 sys.configurations の MAXDOP / cost threshold for parallelism
         打ち手: 推定行数の誤り(27章)を直すのが本筋。設定変更は対症療法。

   (3) PAGEIOLATCH_SH が出ず SOS_SCHEDULER_YIELD が支配的だった場合

       理由: 2回目以降の実行では OrdersBig の全ページがバッファプールに乗っており、
             ディスクを一切読まない。I/O 待ちが発生しないまま CPU を回し続けるので、
             4ms の quantum を使い切って何度も RUNNABLE に並び直す。
             → 「回数は膨大だが平均待機ms はほぼ 0」という形になる。

       CPU を増設すべきか: いいえ。
             これは「CPU が足りない」のではなく「クエリが CPU を無駄遣いしている」状態。
             セクションA の 2本目は WHERE YEAR(OrderDate) = 2020 という非SARGable な
             書き方で、100万行すべてに関数を適用している。
             IX_OrdersBig_OrderDate を作り、範囲条件に書き換えれば CPU 消費は激減する。
             → ハードウェアを買う前に、まず 18章に戻るのが正解。               */
GO


-- Q8-①. 【W5】書き込み負荷を測る — 開始スナップショット
DROP TABLE IF EXISTS #WaitSnapshot;

SELECT wait_type,
       waiting_tasks_count,
       wait_time_ms,
       signal_wait_time_ms,
       CAST(SYSDATETIME() AS DATETIME2(3)) AS captured_at
INTO   #WaitSnapshot
FROM   sys.dm_os_wait_stats;

SELECT N'開始スナップショット取得(書き込み負荷用)' AS 状態, SYSDATETIME() AS 時刻;
GO

/* Q8-②. 【W3】05_workload.sql の「セクションB: 書き込み負荷(既定60秒)」を実行する。
   dbo.WorkloadTest の 1000 行を 1 行ずつ、自動コミットで延々と UPDATE し続ける。
   ※ 業務テーブルは一切触らない。                                            */

WAITFOR DELAY '00:01:00';
GO

-- Q8-③. 【W5】差分(Q6-③ とまったく同じクエリを再実行する)
DECLARE @ElapsedMs BIGINT =
    (SELECT DATEDIFF(MILLISECOND, MIN(captured_at), SYSDATETIME()) FROM #WaitSnapshot);

WITH Diff AS
(
    SELECT n.wait_type,
           n.waiting_tasks_count - ISNULL(o.waiting_tasks_count, 0) AS 待機回数,
           n.wait_time_ms        - ISNULL(o.wait_time_ms, 0)        AS 合計待機ms,
           n.signal_wait_time_ms - ISNULL(o.signal_wait_time_ms, 0) AS シグナル待機ms
    FROM   sys.dm_os_wait_stats AS n
    LEFT   JOIN #WaitSnapshot   AS o ON o.wait_type = n.wait_type
    WHERE  n.wait_type NOT LIKE N'SLEEP[_]%'
      AND  n.wait_type NOT LIKE N'XE[_]%'
      AND  n.wait_type NOT LIKE N'BROKER[_]%'
      AND  n.wait_type NOT LIKE N'QDS[_]%'
      AND  n.wait_type NOT LIKE N'PREEMPTIVE[_]XE[_]%'
      AND  n.wait_type NOT IN
           (N'CHECKPOINT_QUEUE', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
            N'DIRTY_PAGE_POLL',  N'REQUEST_FOR_DEADLOCK_SEARCH',
            N'DISPATCHER_QUEUE_SEMAPHORE', N'WAITFOR',
            N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SP_SERVER_DIAGNOSTICS_SLEEP',
            N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'CLR_AUTO_EVENT',
            N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'HADR_LOGCAPTURE_WAIT',
            N'REDO_THREAD_PENDING_WORK', N'SERVER_IDLE_CHECK',
            N'ONDEMAND_TASK_QUEUE', N'RESOURCE_QUEUE')
),
Positive AS
(
    SELECT * FROM Diff WHERE 合計待機ms > 0
)
SELECT TOP (15)
       wait_type                                                  AS 待機タイプ,
       CAST(100.0 * 合計待機ms
            / NULLIF(SUM(合計待機ms) OVER (), 0) AS DECIMAL(5, 2)) AS 割合パーセント,
       待機回数,
       合計待機ms,
       合計待機ms - シグナル待機ms                                 AS リソース待機ms,
       シグナル待機ms,
       CAST(合計待機ms * 1.0
            / NULLIF(待機回数, 0) AS DECIMAL(18, 2))               AS 平均待機ms,
       CAST(合計待機ms * 1.0
            / NULLIF(@ElapsedMs, 0) AS DECIMAL(10, 2))            AS 待機秒毎秒
FROM   Positive
ORDER  BY 合計待機ms DESC;
GO

/* Q8 の解答例:

   読み取り負荷との違い:
     読み取り(A) … PAGEIOLATCH_SH / SOS_SCHEDULER_YIELD / CXPACKET が上位
     書き込み(B) … WRITELOG が急上昇。PAGELATCH_EX、LCK_M_U/LCK_M_X も現れる

   WRITELOG が上位のとき

     意味  : コミット時、ログレコードをディスクに書き終えるまでコミットは完了しない
             (WAL: Write-Ahead Logging)。その書き込み完了待ち。

     疑う  : ① ログファイルのディスクが遅い
             ② トランザクションが細かすぎる
                → セクションB はまさにこれ。1行ずつ自動コミットで UPDATE しているので、
                  1行ごとにログフラッシュ(ディスク往復)が発生する。
                  「待機回数が数十万〜数百万、平均待機ms は 1ms 未満」という形になる。
             ③ インデックスが多すぎる(更新のたびに全索引のログも書かれる)

     次に見る:
             ・sys.dm_io_virtual_file_stats で type_desc = 'LOG' の書き平均ms
               → ログはシーケンシャル書き込みなので 1〜5ms 以内が目標
             ・waiting_tasks_count(≒ コミット回数)と平均待機ms の組み合わせ
               → 平均が小さく回数が膨大 = ディスクではなくコミット粒度の問題

     打ち手: ・バッチ化する(1000〜5000行単位で BEGIN TRAN 〜 COMMIT)
               ただし大きすぎると今度はロック保持時間が伸びて LCK_M_* を招く
             ・ログファイルを単独の高速ディスクへ
             ・遅延持続性 Delayed Durability(2014+)は
               クラッシュ時に直近コミットを失う可能性があるので用途を選ぶ
             ・VLF が多すぎないか確認(sys.dm_db_log_info / 2016 SP2+)

   PAGELATCH_EX が出た場合:
     WorkloadTest は Id の連番クラスタ化主キーなので、
     同じページに複数セッションが集中すると「最終ページ挿入競合」に近い形になる。
     PAGEIOLATCH_* とは別物(メモリ上のページの競合)である点に注意。      */


-- Q9. ブロッキングを発生させて犯人を特定する
/* Q9-①. 【W3】05_workload.sql の「セクションC: ブロッカー」を実行
       BEGIN TRANSACTION;
       UPDATE dbo.WorkloadTest SET Val = Val + 1000 WHERE Id BETWEEN 1 AND 10;
       WAITFOR DELAY '00:00:30';
       ROLLBACK TRANSACTION;

   Q9-②. 【W1】すぐに「セクションD: ブロックされる側」を実行
       SELECT Id, Val, UpdatedAt FROM dbo.WorkloadTest WHERE Id BETWEEN 1 AND 10;
     → 返ってこない(排他ロックが解放されるまで共有ロックが取れない)

   Q9-③. 【W4】以下を実行して犯人を特定する                                 */

-- 【W4】ブロッキングチェーンの可視化
SELECT  wt.session_id           AS 待っている人,
        wt.exec_context_id      AS 実行コンテキスト,
        wt.wait_type            AS 待機タイプ,        -- ★ LCK_M_S になるはず
        wt.wait_duration_ms     AS 待機ms,
        wt.blocking_session_id  AS ブロックしている人,
        wt.resource_description AS リソース詳細,
        s.login_name            AS ログイン,
        s.host_name             AS ホスト,
        s.program_name          AS プログラム,
        r.status                AS 要求状態,
        DB_NAME(r.database_id)  AS データベース,
        t.text                  AS 待っている人のSQL
FROM    sys.dm_os_waiting_tasks AS wt
LEFT    JOIN sys.dm_exec_sessions AS s ON s.session_id = wt.session_id
LEFT    JOIN sys.dm_exec_requests AS r ON r.session_id = wt.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   wt.session_id > 50
  AND   wt.session_id <> @@SPID
ORDER   BY wt.wait_duration_ms DESC;

-- 【W4】ブロックしている側(犯人)が何を投げたのかを見る(2016+)
--        上のクエリで得た blocking_session_id をここに入れる
DECLARE @Blocker INT = 0;   -- ★ 実際の blocking_session_id に書き換えて実行する

IF @Blocker > 0
BEGIN
    SELECT ib.session_id, ib.event_info AS 実行した文
    FROM   sys.dm_exec_input_buffer(@Blocker, NULL) AS ib;

    SELECT s.session_id, s.login_name, s.host_name, s.program_name,
           s.status                AS セッション状態,   -- sleeping なら「放置トランザクション」
           s.last_request_start_time,
           s.last_request_end_time,
           t.open_transaction_count AS 開いているトランザクション数
    FROM   sys.dm_exec_sessions AS s
    LEFT   JOIN sys.dm_tran_session_transactions AS t
           ON  t.session_id = s.session_id
    WHERE  s.session_id = @Blocker;
END;
GO

-- 【W4】保持されているロックの一覧(19章の復習)
SELECT l.request_session_id      AS セッション,
       l.resource_type           AS リソース種別,
       l.request_mode            AS ロックモード,      -- X / S / U / IX / IS
       l.request_status          AS 状態,              -- GRANT / WAIT / CONVERT
       DB_NAME(l.resource_database_id) AS データベース,
       OBJECT_NAME(p.object_id)  AS オブジェクト
FROM   sys.dm_tran_locks AS l
LEFT   JOIN sys.partitions AS p
       ON  l.resource_associated_entity_id = p.hobt_id
WHERE  l.request_session_id <> @@SPID
  AND  l.resource_type <> 'DATABASE'
ORDER  BY l.request_session_id, l.request_status DESC;
GO

/* Q9 の解答:

   観測できる待機タイプ: LCK_M_S(共有ロックの取得待ち)
     セクションD は SELECT なので S ロックを要求する。
     セクションC が同じ 10 行に X(排他)ロックを保持しているため、
     S と X は互換性が無く、待たされる。

   分類: 「リソース待機(SUSPENDED)」。しかも待たされている相手は
         ディスクでもメモリでもなく「他のセッション」。

   読み方のポイント:
     ・blocking_session_id が「真犯人」を指す。
       blocking_session_id が NULL または自分を指さないセッションが
       ブロックチェーンの根元。
     ・wait_duration_ms が数十秒に達する = ユーザー体感で「固まった」状態。
       累計統計では max_wait_time_ms として現れる。
       「待機回数は少ないのに max_wait_time_ms が突出」はブロッキングの典型的な指紋。
     ・sys.dm_exec_sessions.status が 'sleeping' なのに
       open_transaction_count > 0 なら、
       アプリがコミットもロールバックもせず放置している最悪のパターン。

   打ち手(docs 4-3節):
     ・トランザクションを短くする。トランザクション内で外部呼び出しや人間の操作を待たない
     ・更新条件の列にインデックスを張り、ロック範囲を狭める
     ・読み取りが更新をブロックしているなら READ COMMITTED SNAPSHOT(RCSI)を検討(19章)
     ・NOLOCK は解決策ではない(ダーティリード・重複読み・読み飛ばし)

   ※ 30秒経つとセクションC は自動で ROLLBACK し、W1 の SELECT が返ってくる。
     データは元に戻る(Val + 1000 は取り消される)。                        */


-- Q10. ファイル I/O レイテンシの裏取り
SELECT DB_NAME(vfs.database_id)                    AS データベース,
       mf.name                                     AS 論理ファイル名,
       mf.type_desc                                AS 種別,            -- ROWS / LOG
       vfs.num_of_reads                            AS 読み取り回数,
       vfs.num_of_bytes_read / 1024 / 1024         AS 読み取りMB,
       CAST(vfs.io_stall_read_ms * 1.0
            / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(18, 2))  AS 読み平均ms,
       vfs.num_of_writes                           AS 書き込み回数,
       vfs.num_of_bytes_written / 1024 / 1024      AS 書き込みMB,
       CAST(vfs.io_stall_write_ms * 1.0
            / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(18, 2)) AS 書き平均ms,
       mf.physical_name                            AS 物理パス
FROM   sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN   sys.master_files AS mf
       ON  mf.database_id = vfs.database_id
       AND mf.file_id     = vfs.file_id
ORDER  BY 読み平均ms DESC;

-- SalesLearning のファイルだけに絞る場合
SELECT mf.name          AS 論理ファイル名,
       mf.type_desc     AS 種別,
       CAST(vfs.io_stall_read_ms * 1.0
            / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(18, 2))  AS 読み平均ms,
       CAST(vfs.io_stall_write_ms * 1.0
            / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(18, 2)) AS 書き平均ms
FROM   sys.dm_io_virtual_file_stats(DB_ID(N'SalesLearning'), NULL) AS vfs
JOIN   sys.master_files AS mf
       ON  mf.database_id = vfs.database_id
       AND mf.file_id     = vfs.file_id;
GO

/* Q10 の判断目安(環境により前後する。あくまで傾向を見るための経験則):

   データファイル(ROWS)のランダム読み:
       〜5ms    良好(NVMe / 高速SAN)
       5〜20ms  許容範囲
       20ms超   遅い。ストレージまたは I/O キューイングを疑う

   ログファイル(LOG)の書き込み:
       シーケンシャル書き込みなので 1〜5ms 以内が目標。
       10ms を超えていたら WRITELOG が上位に来る大きな要因になる。

   ⚠ この DMV も「サービス起動からの累計」。
     ここでも本当は「差分」を取るのが正しい。累計だと
     過去のバックアップや再構築の I/O が混ざる。

   ⚠ 待機統計で PAGEIOLATCH_SH が高いのに、ここの読み平均ms が 3ms 程度なら
     「ストレージは速い。読みすぎているだけ」と結論できる。
     → ディスクを買う前に 18章のインデックス設計に戻る。          */


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q11. sys.dm_exec_session_wait_stats(2016+)で 1本のクエリだけを測る
DROP TABLE IF EXISTS #Before;

SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO   #Before
FROM   sys.dm_exec_session_wait_stats
WHERE  session_id = @@SPID;
GO

-- 測りたいクエリ(OrdersBig 100万行の全件集計)
SELECT Status      AS 状態,
       COUNT(*)    AS 件数,
       SUM(Amount) AS 合計
FROM   dbo.OrdersBig
GROUP  BY Status;
GO

-- 差分 = このクエリが待ったもの
SELECT a.wait_type                                              AS 待機タイプ,
       a.waiting_tasks_count - ISNULL(b.waiting_tasks_count, 0) AS 待機回数,
       a.wait_time_ms        - ISNULL(b.wait_time_ms, 0)        AS 合計待機ms,
       (a.wait_time_ms        - ISNULL(b.wait_time_ms, 0))
     - (a.signal_wait_time_ms - ISNULL(b.signal_wait_time_ms, 0)) AS リソース待機ms,
       a.signal_wait_time_ms - ISNULL(b.signal_wait_time_ms, 0) AS シグナル待機ms
FROM   sys.dm_exec_session_wait_stats AS a
LEFT   JOIN #Before AS b ON b.wait_type = a.wait_type
WHERE  a.session_id = @@SPID
  AND  a.wait_time_ms - ISNULL(b.wait_time_ms, 0) > 0
ORDER  BY 合計待機ms DESC;
GO

/* Q11 の解答:

   【利点】
     ① インスタンス全体のノイズ(他人のバッチ、バックグラウンドタスク)が
        混ざらないので、「このクエリが何を待ったか」を直接見られる。
        sys.dm_os_wait_stats だと、同時に動いている他の処理の待機と
        区別がつかない。
     ② 他人のセッションも session_id を指定して見られる。
        「あの遅い夜間バッチ(session_id = 88)が何を待っているのか」を
        本人に何もさせずに調べられる。
     ③ (おまけ)DBCC SQLPERF の CLEAR の影響を受けないので、
        共有環境でも安全に測れる。

   【注意点】
     ・SQL Server 2016 以降でのみ利用可能。
     ・「セッションが接続してからの累計」であり、
       切断すると消える(再接続すると 0 から数え直し)。
       SSMS で「接続の変更」や自動再接続が起きると値が飛ぶ。
     ・クリアする手段が無い。だから 1本ぶんを測るには
       上のように前後スナップショットの差分を取るしかない。
     ・並列クエリでは子スレッドぶんも合算されるので、
       DOP 8 なら CXPACKET/CXCONSUMER が実時間より大きく出る。

   【期待される結果】
     ・1回目の実行  : PAGEIOLATCH_SH(ディスクから読み込む)
     ・2回目以降    : キャッシュに乗るので PAGEIOLATCH_SH は消え、
                      CXPACKET/CXCONSUMER と SOS_SCHEDULER_YIELD が残る
     ・SSMS で結果グリッドが大きいと ASYNC_NETWORK_IO も出る
       (ここでは 2 行しか返らないのでほぼ出ない)                        */


-- Q12. 待機タイプの読み分け(SQL は不要。文章で答える)
/* Q12 の解答:

  ────────────────────────────────────────────────────────────
  (1) PAGEIOLATCH_SH 60% / 平均25ms / シグナル比率5%
  ────────────────────────────────────────────────────────────
   ① 疑う : データページのディスク読み込み待ちが支配的。
             シグナル比率が低いので CPU ではなく資源側の問題。
             平均25ms は「遅いストレージ」の水準。
             ただし真因はメモリ不足(同じページを読み直している)か
             読みすぎ(インデックス不足)のことが多い。
   ② 次に : sys.dm_io_virtual_file_stats の読み平均ms、
             Page life expectancy(急落や慢性的な低値)、
             sys.dm_exec_query_stats の total_logical_reads 上位クエリ、
             その実行プラン(18章)。
   ③ 打ち手: まずインデックス設計で読むページ数を減らす。
             次にメモリ増設、最後にストレージ。分析系なら列ストア(30章)。

  ────────────────────────────────────────────────────────────
  (2) WRITELOG 45% / 回数800万 / 平均0.4ms
  ────────────────────────────────────────────────────────────
   ① 疑う : 平均0.4ms はむしろ速い。問題はディスクではなく「回数」。
             = トランザクションが細かすぎる。1行ずつ自動コミットしている。
   ② 次に : type_desc='LOG' の書き平均ms(1〜5ms 以内か)、
             どのクエリが何回コミットしているか(sys.dm_exec_query_stats の
             execution_count)、アプリのループ処理。
   ③ 打ち手: バッチ化(1000〜5000行単位でトランザクションにまとめる)。
             大きくしすぎるとロック保持時間が伸びるのでバランスを取る。
             ログを高速ディスクへ。用途が許せば遅延持続性(2014+)。

  ────────────────────────────────────────────────────────────
  (3) LCK_M_S 50% / 回数120 / max_wait 45,000ms
  ────────────────────────────────────────────────────────────
   ① 疑う : 「回数は少ないのに1回が45秒」= 典型的な長時間ブロッキング。
             長すぎるトランザクション、放置されたトランザクション、
             更新条件の列にインデックスが無く広範囲をロックしている、
             ロックエスカレーション(5000ロック超でテーブルロック)。
   ② 次に : sys.dm_os_waiting_tasks の blocking_session_id と
             resource_description、sys.dm_tran_locks、
             sys.dm_exec_sessions.status が 'sleeping' で
             open_transaction_count > 0 のセッション、
             拡張イベントの blocked_process_report(25章)。
   ③ 打ち手: トランザクションを短くする。更新条件にインデックスを張る。
             RCSI の検討(19章)。NOLOCK は解決策ではない。

  ────────────────────────────────────────────────────────────
  (4) SOS_SCHEDULER_YIELD 40% / 回数3000万 / 平均0.02ms
  ────────────────────────────────────────────────────────────
   ① 疑う : 平均0.02ms = 譲ってもすぐ戻れている = CPU の行列は短い。
             つまり CPU 不足ではなく「メモリ上の大量スキャンで
             CPU を回し続け、4ms の quantum を使い切っている」状態。
             = クエリが CPU を無駄遣いしている。
   ② 次に : sys.dm_os_schedulers.runnable_tasks_count(短いはず)、
             シグナル比率、sys.dm_exec_query_stats の total_worker_time 上位、
             そのクエリの実行プランと論理読み取り数。
   ③ 打ち手: CPU 増設ではない。非SARGable な条件の解消(18章)、
             不足インデックス、行単位で呼ばれるスカラーUDFの排除、
             大量スキャンなら列ストア(30章)。
             ※ 逆に平均が数ms以上なら本当に CPU 圧迫。その場合は
               CPU を食う上位クエリを潰し、それでも足りなければ増設。

  ────────────────────────────────────────────────────────────
  (5) RESOURCE_SEMAPHORE が上位
  ────────────────────────────────────────────────────────────
   ① 疑う : メモリ許可(memory grant)待ち。クエリは1行も処理を始められていない。
             最多の原因は「推定行数の過大見積もり」。
             予約したメモリは実際に使わなくても占有される。
             ほかに巨大なソート/ハッシュ、同時実行数過多、max server memory 不足。
   ② 次に : sys.dm_exec_query_memory_grants
               → granted_memory_kb >> max_used_memory_kb なら過大見積もり確定。
                 grant_time が NULL の行が「待っている人」。
             sys.dm_exec_query_resource_semaphores の waiter_count。
             実際のプランの「過剰な許可メモリ」警告(2016 SP1+)。
   ③ 打ち手: 統計情報の更新・推定改善(27章)が本筋。
             OPTION (MAX_GRANT_PERCENT = n) で上限を掛ける。
             2017+/2019+ のメモリ許可フィードバック(互換性レベル150)。
             ※ 逆に許可が小さすぎると tempdb への spill が起きるので
               「大きすぎ」も「小さすぎ」も問題になる。

  ────────────────────────────────────────────────────────────
  (6) PAGELATCH_UP 上位 / resource_description が 2:1:1 や 2:1:3
  ────────────────────────────────────────────────────────────
   ① 疑う : 「2:」= database_id 2 = tempdb。1:1 は PFS、1:2 は GAM、1:3 は SGAM。
             = tempdb の割り当てページ競合。
             多数のセッションが同時に一時テーブル/テーブル変数/
             ワークテーブルを作成・破棄している。
             ★ PAGEIOLATCH ではないので、ディスクの問題ではない。
               メモリ上のページを取り合っている「同時実行の競合」。
   ② 次に : sys.dm_os_waiting_tasks の resource_description、
             tempdb のデータファイル数とサイズ(sys.master_files)、
             一時テーブルを多用しているクエリ(15章)。
   ③ 打ち手: tempdb データファイルを複数用意し、すべて同サイズ・同自動拡張量にする
             (論理コア数と同数、最大8が出発点)。2016以降はセットアップで自動提案。
             2016+ では TF 1117/1118 相当が tempdb で既定動作なので付ける必要はない。
             2019+ なら メモリ最適化 tempdb メタデータ
               ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
               → 再起動が必要。戻すときは OFF にして再度再起動。
             そもそも一時テーブルの作りすぎを見直す。

             ※ resource_description が tempdb ではなくユーザーテーブルのページなら
               「最終ページ挿入競合」。連番クラスタ化キーへの同時 INSERT が原因。
               2019+ なら OPTIMIZE_FOR_SEQUENTIAL_KEY = ON。

  ────────────────────────────────────────────────────────────
  (7) ASYNC_NETWORK_IO 55%
  ────────────────────────────────────────────────────────────
   ① 疑う : SQL Server は結果を用意し終えているのに、
             クライアントが受け取ってくれない。
             名前に反して、ネットワーク帯域が原因であることは稀。
               ・アプリが1行ずつ処理しながら読んでいる(RBAR)
               ・返す行数が多すぎ、アプリ側で絞り込んでいる
               ・SSMS で巨大な結果セットをグリッド表示している
   ② 次に : そのクエリが何行返しているか(sys.dm_exec_query_stats の total_rows)、
             sys.dm_exec_connections の client_net_address / net_packet_size、
             アプリケーション側のコード。
   ③ 打ち手: 必要な行・列だけを返す。集計は SQL Server 側で行う。
             アプリは結果を全部読み切ってから加工する。
             ★ DB をいくらチューニングしても直らない。
               「調査対象をアプリに移す」という判断そのものが成果。

  ────────────────────────────────────────────────────────────
  (8) THREADPOOL 出現 / 新規接続もできない
  ────────────────────────────────────────────────────────────
   ① 疑う : ワーカースレッド枯渇。緊急事態。
             真犯人はほぼ常に「大規模なブロッキングチェーン」。
             数百セッションが1つのロックを待って SUSPENDED のまま滞留し、
             ワーカーを掴んだまま離さない。
             ほかに同時接続数過多(接続プール暴走・リトライ嵐)、並列クエリ多発。
   ② 次に : DAC(専用管理者接続)で入る: sqlcmd -S サーバー名 -A
             sys.dm_os_sys_info.max_workers_count、
             sys.dm_os_schedulers の work_queue_count(0より大 = 枯渇)、
             sys.dm_os_waiting_tasks でブロックチェーンの根元を特定。
   ③ 打ち手: 根元のブロッカーを KILL してブロッキングを解消する。
             max worker threads を増やすのは対症療法で、
             メモリを圧迫してむしろ悪化することがある。
             恒久対策は (3) と同じくトランザクション設計の見直し。       */


-- Q13-1. DBCC SQLPERF(CLEAR)の説明(実行前に必ず読むこと)
/* Q13-1 の解答:

   【何が起きるか】
       DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

     ・インスタンス全体・全データベース共通の累計がゼロに戻る。
       自分のセッションだけ、自分のデータベースだけ、ではない。
     ・同居している他システムや、監視ツールのベースライン収集にも影響する。
       「昨日と比べて増えた/減った」を見ている監視がその瞬間から狂う。

   【元に戻せるか】
     ・戻せない。消えた累計を復元する方法は存在しない。
       サービスを再起動しても復活しない(再起動でも同様にゼロになる)。

   【必要な権限】
     ・ALTER SERVER STATE。
       (単に DMV を読むだけなら VIEW SERVER STATE で足りる)

   【本番で CLEAR を使わずに「今」を診断する方法】
     ・スナップショット差分。Q6/Q8 でやったとおり、
       計測開始時点の sys.dm_os_wait_stats を一時テーブルに退避し、
       計測終了時点との差を取る。
       誰にも影響を与えず、他の監視ツールとも共存できる。
       さらに「差分待機ms ÷ 経過ms」で正規化すれば、
       同時実行数の異なるサーバー同士でも比較できる。
     ・継続的にやるなら、定期ジョブでスナップショットを恒久テーブルに蓄積し、
       時間帯別のベースラインを持っておくのが定石。                     */

-- Q13-2. 【自分専用の開発機の場合のみ】実際にクリアしてみる
--        ★ 共有サーバー・本番では絶対に実行しないこと。
--        ★ 実行する場合は、必ずクリア時刻を記録しておくこと。
/*
SELECT SYSDATETIME() AS クリア実行時刻;

DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

-- 直後は合計がほぼ 0 になる(バックグラウンドタスクぶんだけ即座に積み始める)
SELECT SUM(wait_time_ms)        AS 待機合計ms,
       SUM(waiting_tasks_count) AS 待機回数合計
FROM   sys.dm_os_wait_stats;
*/
GO

------------------------------------------------------------
-- Q13-3. 【必須】後片付け
------------------------------------------------------------

-- ① 全ウィンドウ(W1〜W5)で、開いたままのトランザクションが無いか確認する
SELECT @@TRANCOUNT AS 未完了トランザクション数;   -- 0 であること

-- 0 でなければ次を実行する(セクションC を途中で止めた場合など)
-- ROLLBACK TRANSACTION;

-- ② インスタンス全体で放置トランザクションが無いか確認
SELECT s.session_id,
       s.login_name,
       s.host_name,
       s.program_name,
       s.status                        AS セッション状態,
       st.open_transaction_count       AS 開いているトランザクション数,
       s.last_request_end_time         AS 最終要求終了時刻
FROM   sys.dm_tran_session_transactions AS st
JOIN   sys.dm_exec_sessions AS s ON s.session_id = st.session_id
WHERE  st.session_id > 50;
GO

-- ③ 一時テーブルの削除
DROP TABLE IF EXISTS #WaitSnapshot;
DROP TABLE IF EXISTS #Before;
GO

-- ④ 負荷生成用テーブルの削除(05_workload.sql の【後片付け】と同じ)
DROP TABLE IF EXISTS dbo.WorkloadTest;
GO

-- ⑤ 確認: WorkloadTest が消えていること(0行なら成功)
SELECT name, type_desc
FROM   sys.objects
WHERE  name = N'WorkloadTest';
GO

/* 後片付けの注意:
   ・セクションC は WAITFOR DELAY '00:00:30' のあと必ず ROLLBACK するので、
     最後まで流せばデータは元に戻る(WorkloadTest.Val の +1000 は取り消される)。
   ・途中で「クエリのキャンセル」を押すと、ROLLBACK の行が実行されずに
     トランザクションが開いたままロックを保持し続ける。必ず @@TRANCOUNT を確認すること。
   ・ウィンドウを閉じれば接続が切れて自動的にロールバックされるが、
     「明示的に確認する」習慣をつけること。
   ・dbo.OrdersBig / dbo.Orders などの既存テーブルは一切変更していない。
     05_workload.sql の書き込み対象は dbo.WorkloadTest だけ。            */


-- Q14. 待機プロファイル報告書(記述式のテンプレート)
/* Q14 の解答例(自分の実測値で埋めること):

   ────────────────────────────────────────────
   待機プロファイル報告書
   ────────────────────────────────────────────
   ■ 対象
       インスタンス: (サーバー名)
       データベース: SalesLearning
       サービス起動: (Q1 の値) / 稼働 (Q1 の値) 日

   ■ 計測方法
       sys.dm_os_wait_stats のスナップショット差分。
       計測期間: 60 秒(セクションA を 2 セッションで実行中)
       ※ 累計値ではなく差分を採用した理由:
         累計は稼働 N 日ぶんの平均であり、「今」の姿を示さないため。

   ■ 上位3件(例。数値は環境により大きく変わる)
     ┌──┬──────────────────┬──────┬────────┬──────────┬──────────┐
     │順│ 待機タイプ         │ 割合 │平均待機ms│リソース待機│シグナル待機│
     ├──┼──────────────────┼──────┼────────┼──────────┼──────────┤
     │ 1│ SOS_SCHEDULER_YIELD│ 52%  │  0.03    │   4%       │   96%     │
     │ 2│ CXCONSUMER         │ 28%  │  12.5    │  98%       │    2%     │
     │ 3│ PAGEIOLATCH_SH     │ 11%  │  3.2     │  91%       │    9%     │
     └──┴──────────────────┴──────┴────────┴──────────┴──────────┘
       待機秒毎秒: SOS_SCHEDULER_YIELD = 3.8(常時3.8本のワーカーが待機)
       シグナル比率(全体) = 約 50%

   ■ ボトルネックの仮説
       ・SOS_SCHEDULER_YIELD が支配的で、かつ平均待機が 0.03ms と極小。
         → CPU の行列が長いのではなく、CPU を回し続けるクエリがある。
         → セクションA の「WHERE YEAR(OrderDate) = 2020」が非SARGable で、
           100万行すべてに関数を適用している(18章)。
       ・PAGEIOLATCH_SH が小さいのは、OrdersBig が全部バッファプールに
         乗っているため。ストレージは問題ではない。
       ・CXCONSUMER は並列プランに伴う正常な待機であり、無害と判断。
         (CXPACKET 側が大きければ並列の歪みを疑うが、今回は該当しない)

   ■ 次に実施する調査
       ① sys.dm_exec_query_stats の total_worker_time 上位クエリを特定(26章)
       ② そのクエリの実際の実行プランと STATISTICS IO を確認(18章)
       ③ IX_OrdersBig_OrderDate を作成し、範囲条件に書き換えて再計測
       ④ Query Store を有効化し、変更前後をクエリ単位で比較(24章)
       ⑤ 並列度が問題になるなら sys.configurations と実プランを確認(29章)

   ■ 待機統計だけでは分からないこと
       ・待機統計はインスタンス全体の合算であり、
         「どのクエリが原因か」までは特定できない。
         上位の待機タイプが、困っているクエリの原因とは限らない。
         → sys.dm_exec_query_stats(26章)や Query Store(24章)で
           クエリ単位に落とし込む必要がある。
       ・純粋な CPU バウンドのクエリはずっと RUNNING なので待機を積まない。
         10分掛かっていても待機統計には現れない。
         → 論理読み取り数・CPU時間と併せて見る必要がある。
       ・「いつからプランが変わって遅くなったのか」という時系列は追えない。
         → Query Store(2016+)の役目。
           sys.query_store_wait_stats(2017+)なら
           クエリ単位の待機カテゴリまで記録される。
       ・単発のスパイクは平均に埋もれる。
         → 拡張イベント(25章)で狙って捕まえる。

   ■ 結論
       推測しない。測る。直す。また測る。
   ──────────────────────────────────────── */
