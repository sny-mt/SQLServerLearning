# 23 待機統計とボトルネック特定

> **このトピックのゴール**: 「なんか遅い」を **推測でなく特定** できるようになる。
> SQL Server のワーカースレッドが **どこで、何を待って止まっていたのか** を
> `sys.dm_os_wait_stats` から読み取り、**次に見るべき場所**を自分で決められるようにする。
> この章の合言葉は **「待機統計は、サーバーが自分で書いた被害届である」**。
>
> **前提**: [22 JSON 操作](22_json.md) までを済ませていること。
> さらに [18 インデックスと実行プラン](18_indexes_execution_plans.md) の
> 「論理読み取り数で比較する」感覚と、[19 トランザクションと分離レベル](19_transactions_isolation.md) の
> ロックの知識を前提にします。
>
> **この章は上級編(第3弾)の入口であり、いちばん重要な章**です。
> 以降の 24〜36 章は、すべて「ここで特定したボトルネックを掘り下げる道具」だと思ってください。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ この章の DMV を読むには **`VIEW SERVER STATE`** 権限が必要です。
> `DBCC SQLPERF(..., CLEAR)` にはさらに **`ALTER SERVER STATE`** が要ります。
> 開発機なら `sysadmin` で問題ありませんが、**本番の共有サーバーで CLEAR は原則実行しない**でください(5-1 節)。

---

## 0. なぜ待機統計から始めるのか

チューニングの相談で最も多いのが、次のパターンです。

> 「本番が遅いんです。とりあえずインデックスを足しました。CPU も増やしました。まだ遅いです」

これは **推測でチューニングしている** 状態です。18 章で「速くなった気がする、は当てにならない」と
学びましたが、それは**1本のクエリ**の話でした。**サーバー全体**では、そもそも
「何が足りていないのか」を先に決めないと、打ち手を選べません。

SQL Server は親切なことに、**自分のスレッドが止まるたびに「何を待って止まったか」を
自分で記録し続けています**。それが待機統計 (wait statistics) です。

```
     「遅い」
        ↓
     何を待っていた?  ← sys.dm_os_wait_stats(この章)
        ↓
   ┌────┼────┬─────────┬──────────┐
  I/O   ロック  CPU      メモリ      並列
   ↓     ↓     ↓         ↓          ↓
  18章   19章  29章      27章       29章
  26章   25章                       30章
```

**待機統計は「診断の入口」であって「答え」ではありません**。
入口を間違えなければ、その先の調査(24 章 Query Store、25 章 拡張イベント、26 章 DMV)が
一直線に進みます。逆に入口を間違えると、何日でも空振りできます。

---

## 1. スレッドはどこで止まっているのか — RUNNING / RUNNABLE / SUSPENDED

待機統計を正しく読むには、**SQL Server のスケジューラの仕組み**を先に知る必要があります。
ここが分かっていないと、後で出てくる `signal_wait_time_ms` の意味が絶対に腑に落ちません。

### 1-1. SQLOS スケジューラと3つの状態

SQL Server は OS にスレッドの割り当てを丸投げせず、**SQLOS** という自前の仕組みで
**協調的スケジューリング (cooperative scheduling)** を行います。

- **論理 CPU 1個につきスケジューラ 1個**(`sys.dm_os_schedulers` で見える)。
- **1つのスケジューラ上で、同時に RUNNING になれるワーカーはたった1つ**。
- ワーカーは「自分から譲る」のが原則(**4ms の quantum** を使い切ったら自主的に譲る)。

ワーカースレッドは次の3つの状態を巡ります。

```
                  ┌──────────────────────────────────────────┐
                  │                                          │
                  ↓                                          │
          ┌───────────────┐   quantum を使い切る/資源が要る   │
          │   RUNNING     │ ─────────────────────────────┐   │
          │  (CPU 実行中) │                              │   │
          └───────────────┘                              ↓   │
                  ↑                            ┌──────────────────┐
                  │ 順番が回ってきた            │   SUSPENDED      │
                  │                            │ (資源待ち・待機者 │
          ┌───────────────┐                    │  リストに並ぶ)   │
          │   RUNNABLE    │ ←─────────────---──└──────────────────┘
          │ (CPU 待ちの行列)│   資源が手に入った(= シグナルを受けた)
          └───────────────┘
```

| 状態 | 意味 | どこに並んでいるか | 待っている相手 |
|---|---|---|---|
| **RUNNING** | いま CPU 上で実際に動いている | — | 誰も待っていない |
| **RUNNABLE** | **やることはあるが CPU の順番待ち** | runnable queue(行列) | **CPU** |
| **SUSPENDED** | **資源が手に入るまで動けない** | waiter list(待機者リスト) | ページ・ロック・メモリ・ネットワーク等 |

### 1-2. 待機はいつ、どう記録されるか(最重要)

1本のクエリが「ディスクからページを読む」場面を追いかけます。

```
① RUNNING   … 実行中。必要なページがバッファプールに無いと分かる
      ↓      I/O を発行して自分から降りる
② SUSPENDED … waiter list に並ぶ。ここで待った時間 = ★リソース待機
      ↓      I/O 完了。「資源が手に入ったよ」というシグナルを受け取る
③ RUNNABLE  … runnable queue の最後尾に並ぶ。ここで待った時間 = ★シグナル待機
      ↓      順番が回ってくる
④ RUNNING   … 実行再開。このとき ②+③ の合計が sys.dm_os_wait_stats に加算される
```

ここから、**この章でいちばん大事な等式**が出てきます。

```
    wait_time_ms  =  リソース待機 (SUSPENDED)  +  signal_wait_time_ms (RUNNABLE)

    ⇒  リソース待機 ms  =  wait_time_ms - signal_wait_time_ms
```

- **リソース待機**が大きい → **その資源そのものが足りない・遅い**(ディスク、ロック、メモリ…)。
- **シグナル待機**が大きい → **資源はすぐ手に入るのに、CPU の順番待ちで足止め**されている
  → **CPU 圧迫**を疑う。

> ⚠️ **「CPU 待ち(RUNNABLE=シグナル待機)」と「リソース待ち(SUSPENDED)」を分けること。
> これが待機統計による診断の出発点です。** 分けずに `wait_time_ms` だけを眺めると、
> 「PAGEIOLATCH が上位だからディスクを速くしよう」と判断したのに、実は
> その大半がシグナル待機(= CPU が足りずに再開できていないだけ)だった、という誤診が起きます。

### 1-3. 待機の「種類」ではなく「場所」で覚える

| 分類 | 状態 | 代表的な待機タイプ | 本質 |
|---|---|---|---|
| **リソース待機** | SUSPENDED | `PAGEIOLATCH_*`, `LCK_M_*`, `WRITELOG`, `RESOURCE_SEMAPHORE`, `ASYNC_NETWORK_IO` | 資源が来ない |
| **シグナル待機** | RUNNABLE | (待機タイプは元のまま。`signal_wait_time_ms` に計上される) | CPU が空かない |
| **CPU 譲渡** | RUNNABLE | `SOS_SCHEDULER_YIELD` | **資源は要らないのに**行列に並び直した |
| **アイドル** | SUSPENDED | `SLEEP_*`, `XE_TIMER_EVENT`, `BROKER_*` | **仕事が無いので寝ているだけ**(ノイズ) |

最後の「アイドル」が曲者です。**何も起きていないサーバーでも、これらは秒単位で溜まり続けます**。
だから 3 節のフィルタが必須になります。

---

## 2. `sys.dm_os_wait_stats` の読み方

まずは素のまま見てみましょう。

```sql
SELECT TOP (20)
       wait_type            AS 待機タイプ,
       waiting_tasks_count  AS 待機回数,
       wait_time_ms         AS 合計待機ms,
       signal_wait_time_ms  AS シグナル待機ms,
       max_wait_time_ms     AS 最大待機ms
FROM   sys.dm_os_wait_stats
ORDER  BY wait_time_ms DESC;
```

### 2-1. 列の意味

| 列 | 意味 | 読み方のコツ |
|---|---|---|
| `wait_type` | 待機タイプの名前 | これが「何を待ったか」。4 節の読み分け表が本体 |
| `waiting_tasks_count` | **その待機が発生した回数**(タスク単位) | 「回数は多いが1回は短い」のか「稀だが1回が長い」のかを分ける |
| `wait_time_ms` | **合計待機時間**。シグナル待機を **含む** | 単独では使わない。必ず下2つと組で読む |
| `signal_wait_time_ms` | **RUNNABLE で並んでいた時間**(CPU 待ち) | 全体に占める比率が **CPU 圧迫の指標** |
| `max_wait_time_ms` | 1回あたりの最長待機 | ここだけ突出 → **たまに起きる長時間ブロッキング**の匂い |

そして、必ず自分で計算する派生値が2つあります。

```sql
SELECT TOP (20)
       wait_type                                    AS 待機タイプ,
       waiting_tasks_count                          AS 待機回数,
       wait_time_ms                                 AS 合計待機ms,
       wait_time_ms - signal_wait_time_ms           AS リソース待機ms,   -- ★ SUSPENDED
       signal_wait_time_ms                          AS シグナル待機ms,   -- ★ RUNNABLE
       CAST(wait_time_ms * 1.0
            / NULLIF(waiting_tasks_count, 0) AS DECIMAL(18, 2)) AS 平均待機ms
FROM   sys.dm_os_wait_stats
WHERE  waiting_tasks_count > 0
ORDER  BY wait_time_ms DESC;
```

- **リソース待機 ms = `wait_time_ms - signal_wait_time_ms`**
  … 純粋に「資源が来なくて止まっていた」時間。**打ち手を決めるのはこちら**。
- **平均待機 ms = `wait_time_ms / waiting_tasks_count`**
  … 1回あたり何ミリ秒待ったか。**合計が同じでも意味がまったく違います**。

| パターン | 平均待機 | 解釈 |
|---|---|---|
| 回数 1,000万・合計 100 万ms | 0.1ms | **1回は一瞬。回数が異常**。クエリを減らす/効率化する方向 |
| 回数 100・合計 100 万ms | 10,000ms | **1回が10秒**。ブロッキングやタイムアウト級の事故を疑う |

### 2-2. シグナル待機の比率で CPU 圧迫を見る

```sql
SELECT SUM(signal_wait_time_ms)                        AS シグナル待機合計ms,
       SUM(wait_time_ms)                               AS 待機合計ms,
       CAST(100.0 * SUM(signal_wait_time_ms)
            / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5, 2)) AS シグナル比率パーセント
FROM   sys.dm_os_wait_stats
WHERE  waiting_tasks_count > 0;
```

**目安**(絶対的な閾値ではなく、あくまで傾向を見るための経験則です):

| シグナル比率 | 解釈 |
|---|---|
| **〜10%** | CPU には余裕がある。ボトルネックは資源側 |
| **10〜25%** | 要注意。負荷が上がると CPU が先に詰まる可能性 |
| **25% 以上** | **CPU 圧迫を強く疑う**。`sys.dm_os_schedulers` の `runnable_tasks_count` を確認 |

```sql
-- runnable queue の長さ = CPU の順番待ちの行列
SELECT scheduler_id            AS スケジューラ,
       cpu_id                  AS 論理CPU,
       current_tasks_count     AS 担当タスク数,
       runnable_tasks_count    AS CPU待ち行列,      -- ★ 常時 1 以上なら CPU 圧迫
       work_queue_count        AS ワーカー不足の目印
FROM   sys.dm_os_schedulers
WHERE  status = 'VISIBLE ONLINE'          -- ユーザー用スケジューラだけ
ORDER  BY scheduler_id;
```

> ⚠️ **シグナル比率だけで「CPU を増やせ」と結論しないこと**。
> CPU が詰まる原因の大半は「CPU が少ない」ではなく、**非効率なプランが CPU を浪費している**ことです。
> 18 章の SARGability、27 章の統計情報、29 章の並列処理を先に疑ってください。

### 2-3. これは「サーバー起動からの累計」である(致命的な落とし穴)

```sql
SELECT sqlserver_start_time                                   AS 起動時刻,
       DATEDIFF(HOUR, sqlserver_start_time, GETDATE())        AS 稼働時間H,
       DATEDIFF(DAY,  sqlserver_start_time, GETDATE())        AS 稼働日数
FROM   sys.dm_os_sys_info;
```

`sys.dm_os_wait_stats` は **SQL Server サービスの起動時点(または最後の `CLEAR`)からの累計**です。
これが意味するのは:

- **稼働 300 日のサーバーで見えるのは「300日ぶんの平均」**。
  今日の 14:00 に起きた障害は、300日ぶんの海に沈んで見えません。
- **月次バッチ・再構築ジョブ・過去の一度きりの事故** が、いつまでも上位に居座ります。
- **「起動直後」に見ると、まだ何も溜まっていないので当てになりません**。

> ⚠️ **累計値をそのまま眺めるのは、待機統計の最も一般的な誤用です。**
> 「今この現象が起きているとき、何を待っているか」を知りたいなら、
> **必ず 5 節のスナップショット差分**を取ってください。累計は「このサーバーの長期的な体質」を
> 見るときにだけ使います。

### 2-4. もう一つの落とし穴 — 待機時間は「タスク単位」で積み上がる

`wait_time_ms` は **ワーカータスクごとに**加算されます。したがって:

- **並列クエリ (DOP 8) が 1 秒待つと、最大 8 秒ぶん**の待機が計上され得ます。
- **同時に 50 セッションが動いていれば、1分間の実測でも待機合計が数十分ぶん**になります。

そのため「待機合計 ms」の絶対値には意味がありません。**必ず割合(%)で見る**か、
次の「秒/秒」に正規化して読みます。

```
    正規化待機 = 差分の待機時間ms ÷ 計測した経過時間ms
              = 「計測期間中、平均して何本のスレッドが常にその待機で止まっていたか」
```

例: 60 秒計測して `PAGEIOLATCH_SH` の差分が 120,000ms なら 120,000 ÷ 60,000 = **2.0**。
「常時 2 本のワーカーがディスク読み待ちで寝ていた」と読めます。この形にすると、
**同時実行数の違うサーバー同士でも比較できる**ようになります。

---

## 3. ノイズを除外する — 実用クエリ(これが無いと読めない)

2 節の素のクエリを実行すると、上位はほぼ確実にこうなります。

```
XE_TIMER_EVENT
SLEEP_TASK
BROKER_TASK_STOP
LAZYWRITER_SLEEP
CHECKPOINT_QUEUE
DIRTY_PAGE_POLL
REQUEST_FOR_DEADLOCK_SEARCH
SQLTRACE_INCREMENTAL_FLUSH_SLEEP
...
```

これらは **バックグラウンドのシステムタスクが「仕事が無いので寝ている」だけ**で、
性能とは一切関係ありません。しかも**アイドル時間ぶんずっと溜まり続ける**ので、
暇なサーバーほど上位を独占します。

**除外リストを持たない待機統計クエリは、実務では使い物になりません。**
以下を「自分の道具」としてスニペットに保存してください。

### 3-1. 無視してよい主な待機タイプ

| グループ | 例 | 何をしているか |
|---|---|---|
| **スリープ系** | `SLEEP_TASK`, `SLEEP_SYSTEMTASK`, `SLEEP_BPOOL_FLUSH`, `LAZYWRITER_SLEEP` | 定期起床タスクが次の起床まで寝ている |
| **拡張イベント系** | `XE_TIMER_EVENT`, `XE_DISPATCHER_WAIT`, `XE_DISPATCHER_JOIN` | XEvent のディスパッチャが待機中 |
| **Service Broker 系** | `BROKER_TASK_STOP`, `BROKER_TO_FLUSH`, `BROKER_EVENTHANDLER`, `BROKER_RECEIVE_WAITFOR` | Broker のキュー待ち。使っていなくても溜まる |
| **チェックポイント/ログ** | `CHECKPOINT_QUEUE`, `LOGMGR_QUEUE`, `DIRTY_PAGE_POLL` | 次の仕事が来るのを待っている |
| **明示的な待ち** | `WAITFOR`, `WAIT_FOR_RESULTS` | **`WAITFOR DELAY` は「自分で寝ろと書いた」もの**。当然ノイズ |
| **Query Store** | `QDS_ASYNC_QUEUE`, `QDS_SHUTDOWN_QUEUE`, `QDS_PERSIST_TASK_MAIN_LOOP_SLEEP` | Query Store のバックグラウンドタスク |
| **可用性グループ** | `HADR_*`(一部。`HADR_SYNC_COMMIT` は**除外しない**) | AG のポーリング系 |
| **その他** | `REQUEST_FOR_DEADLOCK_SEARCH`, `SQLTRACE_INCREMENTAL_FLUSH_SLEEP`, `CLR_AUTO_EVENT`, `FT_IFTS_SCHEDULER_IDLE_WAIT`, `DISPATCHER_QUEUE_SEMAPHORE`, `SERVER_IDLE_CHECK`, `ONDEMAND_TASK_QUEUE` | いずれもアイドル |

> ⚠️ **`HADR_SYNC_COMMIT` だけは除外してはいけません**。
> これは「同期コミットの可用性グループで、セカンダリからの応答を待っている」時間、
> つまり **実際にユーザーを待たせている待機**です。名前が `HADR_` で始まるからと
> 一括除外すると、AG 構成の最大のボトルネックを見落とします。

### 3-2. 実用クエリ(累計版)

```sql
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
      -- ▼ ここから「無視してよい待機」の除外リスト ▼
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
      -- パターンでまとめて除外(前方一致)
      AND  wait_type NOT LIKE N'SLEEP[_]%'
      AND  wait_type NOT LIKE N'PREEMPTIVE[_]XE[_]%'
      AND  wait_type NOT LIKE N'PARALLEL[_]REDO[_]%'
      AND  wait_type NOT LIKE N'WAIT[_]XTP[_]%'
      AND  wait_type NOT LIKE N'PWAIT[_]DIRECTLOGCONSUMER[_]%'
      -- ※ CXCONSUMER は「並列の消費側」で通常は無害だが、
      --    ここではあえて残して CXPACKET と比較できるようにしておく
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
```

**読み方の手順**:

1. **累積パーセントが 80% を超えるところまで**を見る。それ以下は基本的に雑音です。
   実務では **上位 3〜5 種類で 80〜95% を占める**のが普通です。
2. 上位の待機タイプについて、4 節の表で「疑うこと」と「次に見るもの」を確認する。
3. **リソース待機とシグナル待機の内訳**を見て、資源側か CPU 側かを決める。
4. **平均待機 ms** を見て、「回数が多い」問題か「1回が長い」問題かを決める。

> ⚠️ 除外リストは **バージョンによって新しい待機タイプが増えます**。
> 見慣れない待機タイプが上位に来たら、まず `sys.dm_os_wait_stats` の公式ドキュメント
> (「sys.dm_os_wait_stats (Transact-SQL)」)で意味を確認してください。
> 名前だけで「たぶんアイドルだろう」と判断して除外するのが、いちばん危険です。

---

## 4. 主要な待機タイプの読み分け(この章の本体)

ここが本章の中心です。**「上位に来たら何を疑い、次に何を見るか」** をセットで覚えてください。

### 4-0. 早見表

| 待機タイプ | 一言でいうと | 主な疑い | 次に見るもの |
|---|---|---|---|
| `PAGEIOLATCH_SH` / `_EX` | **データページのディスク読み待ち** | I/O が遅い / **メモリ不足** / 読みすぎ | `sys.dm_io_virtual_file_stats`、PLE、不足インデックス |
| `WRITELOG` | **トランザクションログの書き込み待ち** | ログディスクが遅い / 細かすぎるトランザクション | ログファイルの I/O レイテンシ、コミット回数 |
| `LCK_M_*` | **ロック待ち = ブロッキング** | 長トランザクション / 不適切な分離レベル / 索引不足 | `sys.dm_os_waiting_tasks`、`sys.dm_tran_locks`、19 章 |
| `CXPACKET` / `CXCONSUMER` | **並列処理の同期待ち** | 歪んだ並列 / MAXDOP 設定 / 推定ミス | 実際のプラン、`sys.dm_exec_query_stats`、29 章 |
| `SOS_SCHEDULER_YIELD` | **CPU の自主的な譲渡** | CPU 圧迫 / メモリ内の大量スキャン | シグナル比率、`runnable_tasks_count`、プラン |
| `RESOURCE_SEMAPHORE` | **メモリ許可(memory grant)待ち** | 過大なソート/ハッシュ、推定行数の誤り | `sys.dm_exec_query_memory_grants`、27 章 |
| `PAGELATCH_*` | **メモリ上のページの短期ラッチ待ち** | **tempdb 競合** / 最終ページ挿入競合 | `resource_description`(`2:1:1` 等)、tempdb ファイル数 |
| `ASYNC_NETWORK_IO` | **クライアントが結果を受け取ってくれない** | **アプリ側が遅い**(SQL Server は無実のことが多い) | アプリのフェッチ方法、返す行数 |
| `THREADPOOL` | **ワーカースレッド枯渇** | 大規模ブロッキング / 同時接続過多 | ブロッキングチェーン、`sys.dm_os_schedulers` |

以下、それぞれを詳しく見ます。

---

### 4-1. `PAGEIOLATCH_SH` / `PAGEIOLATCH_EX` — データページのディスク読み待ち

**意味**
バッファプールに無いデータページを、**ディスクから読み込むあいだ**待っている状態です。
「ページを入れるバッファ用のスロットにラッチを掛け、I/O 完了までそのラッチを保持して待つ」
という仕組みなので、名前に `IOLATCH` が付きます。

- `_SH`(共有) … **`SELECT` によるページ読み込み**。圧倒的に多いのはこちら。
- `_EX`(排他) … **更新のためのページ読み込み**。

**これが上位なら疑うこと**

1. **メモリ不足**(最も多い)。バッファプールが小さすぎて、同じページを何度も読み直している。
2. **読みすぎ**。インデックスが無くて全件走査している、`SELECT *` で余計な列を運んでいる。
3. **ストレージが本当に遅い**。

**次に見るもの**

```sql
-- ファイルごとの I/O レイテンシ(読み書き 1回あたりの平均ミリ秒)
SELECT DB_NAME(vfs.database_id)                    AS データベース,
       mf.name                                     AS 論理ファイル名,
       mf.type_desc                                AS 種別,          -- ROWS / LOG
       vfs.num_of_reads                            AS 読み取り回数,
       CAST(vfs.io_stall_read_ms * 1.0
            / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(18, 2))  AS 読み平均ms,
       vfs.num_of_writes                           AS 書き込み回数,
       CAST(vfs.io_stall_write_ms * 1.0
            / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(18, 2)) AS 書き平均ms
FROM   sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN   sys.master_files AS mf
       ON  mf.database_id = vfs.database_id
       AND mf.file_id     = vfs.file_id
ORDER  BY 読み平均ms DESC;
```

**判断の目安**(環境により前後します):

| 平均ms | 評価 |
|---|---|
| 〜5ms | 良好(NVMe / 高速 SAN) |
| 5〜20ms | 許容範囲 |
| 20ms 超 | **遅い**。ストレージかキューイングを疑う |

```sql
-- Page Life Expectancy(PLE): ページがバッファプールに留まる秒数
SELECT object_name, counter_name, cntr_value AS PLE秒
FROM   sys.dm_os_performance_counters
WHERE  counter_name = 'Page life expectancy'
  AND  object_name LIKE '%Buffer Manager%';
```

- PLE が **数百秒しかない** / **急降下を繰り返す** → **バッファプールが足りていない**サイン。
  (よく言われる「300 秒」という閾値は 4GB 時代の遺物です。**絶対値より「傾向と急落」を見る**こと。)

**打ち手**

- **まず 18 章に戻る**。適切なインデックスで読むページ数を減らすのが、最も安く効く対策です。
  **「ディスクが遅い」の 8 割は「読みすぎ」**です。
- `SELECT` の列を絞る、カバリングインデックスにする。
- それでも足りなければメモリ増設、最後にストレージ。
- 分析系のスキャンが原因なら、**列ストアインデックス**(30 章)で読むデータ量そのものを1桁減らせます。

> ⚠️ `PAGEIOLATCH_*` の `signal_wait_time_ms` が大きい場合、
> **「I/O は速いのに、完了後 CPU に戻れなくて待っている」**という意味になります。
> このときストレージを速くしても効果はゼロです。必ず内訳を見てください。

---

### 4-2. `WRITELOG` — トランザクションログの書き込み待ち

**意味**
コミット時、SQL Server は **ログレコードをディスクに書き終えるまでコミットを完了させません**
(**WAL: Write-Ahead Logging**)。その書き込み完了を待っている時間です。

**これが上位なら疑うこと**

1. **ログファイルのディスクが遅い**。
2. **トランザクションが細かすぎる**。1行ずつ `INSERT` して毎回コミットすると、
   **1行ごとにログフラッシュ(= ディスク往復)** が発生します。
   → これが「ループで1行ずつ入れると異常に遅い」の正体です。
3. **インデックスが多すぎる**。更新のたびに全インデックスのログも書かれます(18 章 9 節)。

**次に見るもの**

- 4-1 のファイル I/O クエリで、**`type_desc = 'LOG'` の行の書き平均ms**。
  ログは **シーケンシャル書き込み**なので、**1〜5ms 以内が目標**です。
- `waiting_tasks_count`(= 概ねコミット回数)。**平均待機は 1ms 未満なのに回数が数百万** なら、
  問題はディスクではなく **コミットの粒度** です。

**打ち手**

- **バッチ化する**。1行ずつのコミットをやめ、`BEGIN TRAN` ... 数百〜数千行 ... `COMMIT` にまとめる。
  ただし **大きすぎるトランザクションはロック保持時間を伸ばして `LCK_M_*` を招く**ので、
  1000〜5000 行程度を目安に分割するのが実務的です。
- ログファイルを**単独の高速ディスク**に置く。
- **遅延持続性 (Delayed Durability, 2014+)** … コミット時のログフラッシュを非同期化する。
  **クラッシュ時に直近のコミットを失う可能性がある**ので、監査ログ等の
  「多少失っても再生成できるデータ」に限って検討します。
- ログファイルの **VLF が多すぎる**(自動拡張を小刻みに繰り返した結果)場合も遅くなります。
  `DBCC LOGINFO`(または 2016 SP2+ の `sys.dm_db_log_info`)で確認します。

---

### 4-3. `LCK_M_*` — ロック待ち(= ブロッキング)

**意味**
**他のセッションが持っているロックと衝突して待たされている**状態。
「遅い」の中でユーザー体感がいちばん悪いのがこれです(19 章の内容がそのまま出てきます)。

| 待機タイプ | 要求しているロック | 典型的な場面 |
|---|---|---|
| `LCK_M_S` | 共有 (S) | **読み取りが、更新中の行を待っている** |
| `LCK_M_X` | 排他 (X) | 更新が、他の更新/読み取りを待っている |
| `LCK_M_U` | 更新 (U) | `UPDATE` の探索フェーズ |
| `LCK_M_IS` / `LCK_M_IX` | 意図共有/意図排他 | 上位レベル(ページ・テーブル)の意図ロック |
| `LCK_M_SCH_S` / `LCK_M_SCH_M` | スキーマ安定 / スキーマ変更 | **`ALTER TABLE` が実行中クエリに阻まれている** |
| `LCK_M_RS_S`, `LCK_M_RX_X` 等 | 範囲ロック | `SERIALIZABLE` 分離レベル |

**これが上位なら疑うこと**

1. **トランザクションが長すぎる**(トランザクション内でアプリの処理やユーザー入力を待っている)。
2. **インデックスが無く、更新が余計な行までロックしている**。
   `UPDATE ... WHERE 非索引列 = @x` は **全行を走査しながらロックを取る**ので、
   1行を更新するだけで全テーブルがブロックされ得ます。
3. **分離レベルが強すぎる**(不必要な `SERIALIZABLE`、あるいは既定 `READ COMMITTED` のロック待ち)。
4. **ロックエスカレーション**(5000 ロックを超えるとテーブルロックに昇格)。

**次に見るもの**

**まず「今まさに誰が誰をブロックしているか」**を見ます(6-2 節の `sys.dm_os_waiting_tasks`)。

```sql
-- ブロッキングの発生源(ブロックチェーンの根元)を特定する
SELECT  wt.session_id           AS 待っている人,
        wt.wait_type            AS 待機タイプ,
        wt.wait_duration_ms     AS 待機ms,
        wt.blocking_session_id  AS ブロックしている人,
        wt.resource_description AS リソース,
        DB_NAME(r.database_id)  AS DB,
        t.text                  AS 待っている人のSQL
FROM    sys.dm_os_waiting_tasks AS wt
LEFT    JOIN sys.dm_exec_requests AS r
        ON  r.session_id = wt.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   wt.blocking_session_id IS NOT NULL
  AND   wt.session_id <> @@SPID
ORDER   BY wt.wait_duration_ms DESC;
```

- **`blocking_session_id` が自分を指していないセッション**が、チェーンの根元(真犯人)です。
- 犯人のセッションが何をしているかは `sys.dm_exec_sessions` / `sys.dm_exec_connections` /
  `sys.dm_exec_input_buffer`(2016+)で確認します。
- **`status = 'sleeping'` なのにトランザクションを持っている**なら、
  **アプリがコミットもロールバックもせずに放置している**典型です。

**打ち手**

- トランザクションを **短く**する。トランザクション内で外部 API 呼び出しや人間の操作を待たない。
- 更新条件の列に **インデックスを張る**(ロック範囲が狭くなる)。
- 読み取り専用の集計が更新をブロックしているなら、**`READ COMMITTED SNAPSHOT` (RCSI)** を検討(19 章)。
  ただし tempdb のバージョンストアを消費します。
- **`NOLOCK` は解決策ではありません**。ダーティリード・行の重複読み・行の読み飛ばしが起きます(19 章)。

---

### 4-4. `CXPACKET` / `CXCONSUMER` — 並列処理の同期待ち

**意味**
並列プランでは、複数のワーカースレッドが分担して仕事をし、**Exchange 演算子**で待ち合わせます。
その待ち合わせ時間です。

> **バージョン注意**: **SQL Server 2016 SP2 / 2017 CU3 以降**、`CXPACKET` は2つに分割されました。
> - **`CXCONSUMER`** … **消費側が生産側の到着を待っている**。
>   **これはほぼ常に無害**です(並列である以上必ず発生する)。
> - **`CXPACKET`** … 分割後は **生産側の待機**が中心。**歪んだ並列 (skew)** の兆候になり得ます。
>
> 分割前のバージョンでは両者が `CXPACKET` に混ざるため、**「`CXPACKET` が1位=悪」ではありません**。

**これが上位なら疑うこと**

1. **`CXCONSUMER` が中心** → 単に並列クエリが多いだけ。**何もしなくてよい**ことが多い。
2. **`CXPACKET` が中心** → **並列度が不均衡**。あるスレッドだけが大量の行を担当している。
   原因は **推定行数の誤り**(27 章)や、パーティション/統計の偏り。
3. **`MAXDOP` が既定の 0(= 全 CPU)のまま**。OLTP ワークロードでは並列の管理コストが勝ちがち。
4. **`cost threshold for parallelism` が既定の 5 のまま**。
   1997 年のハードウェア基準の値で、**現代では小さすぎて些細なクエリまで並列化されます**。

**次に見るもの**

- **実際の実行プラン**で、並列演算子の各スレッドの行数を見る
  (SSMS のプロパティ → `Actual Number of Rows` をスレッドごとに展開)。
  **1スレッドだけ桁違いに多ければ skew 確定**です。
- 現在の設定:

```sql
SELECT name, value_in_use, description
FROM   sys.configurations
WHERE  name IN ('max degree of parallelism', 'cost threshold for parallelism');
```

**打ち手**

> ⚠️ **サーバー全体の設定変更は影響が大きい**ので、必ず**元の値をメモしてから**変更し、
> 効果が無ければ**戻してください**。以下は「戻す手順つき」の書き方です。

```sql
-- ① 変更前の値を必ず控える
SELECT name, value_in_use FROM sys.configurations
WHERE  name IN ('max degree of parallelism', 'cost threshold for parallelism');
-- 例: max degree of parallelism = 0, cost threshold for parallelism = 5

-- ② 変更(NUMA ノードあたりの論理コア数、最大8 が一般的な出発点)
EXEC sp_configure 'show advanced options', 1;  RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 50;  RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;        RECONFIGURE;

-- ③ 【必ず実施】元に戻す手順(効果が無かった場合)
EXEC sp_configure 'cost threshold for parallelism', 5;   RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 0;        RECONFIGURE;
EXEC sp_configure 'show advanced options', 0;            RECONFIGURE;
```

- サーバー全体を変えたくないなら、**クエリ単位で `OPTION (MAXDOP 1)`**、
  あるいはデータベーススコープ構成 `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;`(2016+)。
- **根本原因が推定行数の誤りなら、統計を直すのが本筋**です(27 章)。並列度をいじるのは対症療法。

詳細は [29 結合アルゴリズムと並列処理](29_join_algorithms_parallelism.md) で扱います。

---

### 4-5. `SOS_SCHEDULER_YIELD` — CPU の自主的な譲渡

**意味**
1-1 節で見たとおり、SQL Server は協調的スケジューリングです。
**ワーカーは 4ms の quantum を使い切ると、自分から RUNNABLE キューの最後尾に並び直します**。
そのときに記録されるのがこの待機です。

**ここが重要**: これは **資源を待っているのではありません**。
「やることはあるが、順番を譲った」だけです。だから **ほぼ全部がシグナル待機**になります。

**これが上位なら疑うこと**

1. **CPU 圧迫**。行列が長いので、譲ったあと戻ってくるまでに時間がかかっている。
   → **平均待機 ms が大きい** なら、これ。
2. **メモリ上の大量スキャン**。全ページがバッファプールに乗っている状態で
   数百万行を走査すると、I/O 待ちが一切発生せず **CPU を回し続けて quantum を使い切る**。
   → **回数は膨大だが平均待機 ms がほぼ 0** なら、これ。
   **CPU が足りないのではなく、クエリが CPU を無駄遣いしている**のです。
3. (稀に)スピンロック競合など内部競合。

**次に見るもの**

- **平均待機 ms**(`wait_time_ms / waiting_tasks_count`)。**0.1ms 未満なら (2)、数 ms 以上なら (1)**。
- 2-2 節の **シグナル比率** と `sys.dm_os_schedulers.runnable_tasks_count`。
- **CPU を最も食っているクエリ**(26 章 / 24 章 Query Store):

```sql
SELECT TOP (10)
       qs.total_worker_time / 1000                  AS 累計CPU_ms,
       qs.execution_count                           AS 実行回数,
       qs.total_worker_time / qs.execution_count / 1000 AS 平均CPU_ms,
       SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1
                        THEN DATALENGTH(t.text)
                        ELSE qs.statement_end_offset END
                   - qs.statement_start_offset) / 2) + 1) AS クエリ
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
ORDER  BY qs.total_worker_time DESC;
```

**打ち手**

- **(2) の場合が圧倒的に多い**。18 章に戻って、**読む行数そのものを減らす**。
  非 SARGable な条件、不足インデックス、スカラー UDF の行単位呼び出しが主犯です。
- (1) なら、CPU を食っているクエリの上位から潰す。それでも足りなければ CPU 増設。

---

### 4-6. `RESOURCE_SEMAPHORE` — メモリ許可(memory grant)待ち

**意味**
**ソート**と**ハッシュ結合/ハッシュ集計**は、作業用メモリを **実行前に予約(memory grant)** します。
予約枠が空くのを待っているのがこの待機です。

**これが上位なら深刻**です。**クエリは1行も処理を始められずに待たされています**。

**これが上位なら疑うこと**

1. **推定行数の過大見積もり**。「1000万行返る」と思い込んで巨大なメモリを予約し、
   実際は 100 行しか返さない。**予約したメモリは実際に使わなくても占有されます**。
2. **巨大なソート**。`ORDER BY` や `DISTINCT` を大量データに掛けている。
3. **同時実行数が多すぎる**。1本ずつなら足りるが、50 本同時だと枠が尽きる。
4. サーバーの **`max server memory`** が小さすぎる。

**次に見るもの**

```sql
-- いま誰がメモリ許可を待っている / 掴んでいるか
SELECT session_id                        AS セッション,
       request_time                      AS 要求時刻,
       grant_time                        AS 許可時刻,      -- NULL = まだ待っている
       requested_memory_kb               AS 要求KB,
       granted_memory_kb                 AS 許可KB,
       used_memory_kb                    AS 実使用KB,     -- ★ 許可 >> 実使用 なら過大見積もり
       max_used_memory_kb                AS 最大使用KB,
       queue_id, wait_order, is_next_candidate
FROM   sys.dm_exec_query_memory_grants
ORDER  BY requested_memory_kb DESC;

-- セマフォ(枠)そのものの状態
SELECT resource_semaphore_id, target_memory_kb, granted_memory_kb,
       available_memory_kb, grantee_count, waiter_count
FROM   sys.dm_exec_query_resource_semaphores;
```

- **`granted_memory_kb` が `max_used_memory_kb` の何倍もある** → **典型的な過大見積もり**。

**打ち手**

- **統計情報を更新する / 推定を改善する**(27 章)。これが本筋。
- 実際のプランに出る **「過剰な許可メモリ」の警告**(2016 SP1+)を確認する。
- **`OPTION (MAX_GRANT_PERCENT = n)`**(2012 SP3 / 2014 SP2 / 2016+)で上限を掛ける。
- **2017+ / 2019+ のバッチモード メモリ許可フィードバック**、
  **2019+ の行モード メモリ許可フィードバック** が自動で補正してくれます
  (互換性レベル 150 が必要)。
- 逆に **メモリ許可が足りないと tempdb への spill(こぼれ)** が起きて `IO_COMPLETION` 等が増えます。
  「大きすぎ」も「小さすぎ」も問題になる点に注意。

---

### 4-7. `PAGELATCH_*` — メモリ上のページの短期ラッチ待ち(`PAGEIOLATCH_*` との違い)

**この2つを混同するのが、待機統計の最頻出の誤読です。**

| | `PAGEIOLATCH_*` | `PAGELATCH_*` |
|---|---|---|
| **待っている相手** | **ディスク I/O の完了** | **メモリ上のページへの他スレッドのアクセス** |
| ページはどこにある | **まだバッファプールに無い** | **すでにバッファプールにある** |
| 意味 | ストレージ/メモリ不足の問題 | **同時実行の競合**の問題 |
| 打ち手の方向 | I/O を減らす、メモリを増やす | **競合を分散する**(ファイル分割、キー設計) |

**`IO` の2文字があるかどうかで、まったく別の問題**です。
「`PAGELATCH_UP` が多いからディスクを速くしよう」は完全な誤診になります。

**代表的な2つのパターン**

**(a) tempdb の割り当てページ競合**

`PAGELATCH_UP` / `PAGELATCH_EX` が **tempdb (database_id = 2)** の
**PFS / GAM / SGAM** ページに集中するパターン。
`resource_description` が **`2:1:1`(PFS)、`2:1:2`(GAM)、`2:1:3`(SGAM)** や
`2:1:%` の形になっているのが目印です(形式は `データベースID:ファイルID:ページID`)。

```sql
-- 今まさに起きている PAGELATCH 競合を見る
SELECT wt.session_id, wt.wait_type, wt.wait_duration_ms,
       wt.resource_description,        -- ★ 2:1:1 のような形なら tempdb 割り当てページ
       wt.blocking_session_id
FROM   sys.dm_os_waiting_tasks AS wt
WHERE  wt.wait_type LIKE 'PAGELATCH%'
  AND  wt.session_id <> @@SPID;
```

- 原因: **多数のセッションが同時に一時テーブル/テーブル変数/ワークテーブルを作成・破棄**している。
- 打ち手:
  - **tempdb のデータファイルを複数用意し、すべて同じサイズ・同じ自動拡張量にする**
    (論理コア数と同数、最大8が出発点)。**2016 以降はセットアップ時に自動で提案されます**。
  - **2016+ では TF 1117/1118 相当が tempdb で既定動作**になったため、
    昔のようにトレースフラグを付ける必要はありません。
  - **2019+** では **メモリ最適化 tempdb メタデータ** で、
    tempdb システムテーブル起因の `PAGELATCH` を大きく減らせます
    (`ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;` → **再起動が必要**。
     戻すときは `OFF` にして再度再起動)。
  - そもそも **一時テーブルの作りすぎ**(15 章)を見直す。

**(b) 最終ページ挿入競合 (last-page insert contention)**

`PAGELATCH_EX` が **ユーザーテーブル**のページに集中するパターン。
**連番(IDENTITY / 昇順の日時)をクラスタ化キーにしたテーブルに、多数のセッションが同時 INSERT** すると、
**全員が B木の同じ最終ページを取り合います**。

- 打ち手:
  - **2019+**: `ALTER INDEX ... SET (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON);` が用意されています。
  - それ以前: クラスタ化キーの設計を見直す(ハッシュ値を先頭に置く等)。
    ただし **キー順の走査性能を犠牲にする**ので、トレードオフを理解した上で。

---

### 4-8. `ASYNC_NETWORK_IO` — 実はクライアント側が遅い

**意味**
**SQL Server は結果を用意し終えているのに、クライアントが受け取ってくれない**ので待っている状態。
名前に `NETWORK` と入っているせいで **「ネットワークが遅い」と誤読されるナンバーワン**の待機タイプです。

実際には、ネットワーク帯域が原因であることは **稀** です。ほとんどはこう:

**これが上位なら疑うこと**

1. **アプリが1行ずつ処理しながら読んでいる**(RBAR)。
   `DataReader` で1行読むごとに重い処理をしていると、その間 SQL Server は待たされます。
2. **返す行数が多すぎる**。100万行をアプリに送って、アプリ側で絞り込んでいる。
   → **絞り込みは SQL 側でやるべき**です。
3. **SSMS で巨大な結果セットをグリッド表示している**(学習中はこれが一番よく出ます)。
4. 本当にネットワークが細い/遠い(クラウド越し等)。

**次に見るもの**

- **そのクエリが何行返しているか**。`sys.dm_exec_query_stats` の `total_rows`。
- クライアント側のコード。「読みながら処理」していないか。
- `sys.dm_exec_connections` の `net_packet_size`、`client_net_address`。

**打ち手**

- **必要な行・列だけを返す**(1 章・2 章の教えがここに効きます)。
- 集計はアプリではなく **SQL Server 側で行う**。
- アプリは **結果を全部読み切ってから処理する**(バッファに溜めてから加工する)。
- **SQL Server 側をいくらチューニングしても直りません**。この待機が上位のときは、
  **調査対象をアプリケーションに移す**という判断そのものが成果です。

> ⚠️ 逆に言えば、`ASYNC_NETWORK_IO` が上位なのに DB のインデックスを弄り続けるのは、
> **完全な時間の無駄**です。待機統計を読む価値は、こういう「やらなくていいこと」が分かる点にもあります。

---

### 4-9. `THREADPOOL` — ワーカースレッド枯渇(緊急事態)

**意味**
**新しいリクエストに割り当てるワーカースレッドが1本も残っていない**状態。
これが出ているときは、**新規接続すらできなくなっている**可能性があります。

**これが上位(というより、そもそも出現していたら)疑うこと**

1. **大規模なブロッキングチェーン**。数百セッションが1つのロックを待って全員 SUSPENDED のまま滞留。
   → **`THREADPOOL` の真の原因は `LCK_M_*` であることがほとんど**です。
2. **同時接続数が想定を超えている**(接続プールの暴走、アプリのリトライ嵐)。
3. **並列クエリの多発**。1本のクエリが DOP ぶんのワーカーを消費します。

**次に見るもの**

```sql
-- 最大ワーカースレッド数と、現在の使用状況
SELECT max_workers_count AS 最大ワーカー数
FROM   sys.dm_os_sys_info;

SELECT SUM(current_workers_count) AS 現在のワーカー数,
       SUM(active_workers_count)  AS アクティブ,
       SUM(runnable_tasks_count)  AS CPU待ち,
       SUM(work_queue_count)      AS ワーカー待ちタスク   -- ★ 0 より大きい = 枯渇
FROM   sys.dm_os_schedulers
WHERE  status = 'VISIBLE ONLINE';
```

**打ち手**

- **原因のブロッキングを解消する**(4-3 節)。`max worker threads` を増やすのは対症療法で、
  むしろメモリを圧迫して悪化させることがあります。
- 接続できないときは **DAC(専用管理者接続)** で入ります。
  `sqlcmd -S サーバー名 -A` で接続し、ブロッカーを特定して `KILL` します。
  DAC は **常に1本ぶんのスケジューラが予約されている**ので、この状況でも入れます。

---

### 4-10. その他、実務で見かける待機タイプ(参考)

| 待機タイプ | 意味 | 一言 |
|---|---|---|
| `RESOURCE_SEMAPHORE_QUERY_COMPILE` | **コンパイル用メモリ**の待ち | 巨大な動的SQL/アドホッククエリの乱発を疑う(20 章)。`optimize for ad hoc workloads` の検討 |
| `IO_COMPLETION` | データページ以外の I/O 完了待ち | **tempdb への spill**(ソート/ハッシュのこぼれ)でよく出る → 4-6 とセットで見る |
| `LATCH_EX` / `LATCH_SH` | ページ **以外** の内部構造のラッチ | `sys.dm_os_latch_stats` で `latch_class` を確認する |
| `HADR_SYNC_COMMIT` | 同期コミット AG のセカンダリ応答待ち | **除外してはいけない**(3-1 節)。AG のレイテンシがそのままユーザー待ち時間になる |
| `BACKUPIO` / `BACKUPBUFFER` | バックアップの I/O | バックアップ時間帯に集中していれば正常。日中に出ていたら実行時刻を疑う |
| `PREEMPTIVE_OS_*` | SQLOS の外(Win32 API 等)を呼んでいる | リンクサーバー、拡張ストアド、CLR、認証(`PREEMPTIVE_OS_AUTHENTICATIONOPS`)など |
| `MSQL_XP` / `OLEDB` | 拡張ストアド / リンクサーバー | **外部システムが遅い**。SQL Server の外を調べる |

---

## 5. 累計をリセットする / スナップショット差分を取る

2-3 節で見たとおり、**累計値のままでは「今」を診断できません**。方法は2つあります。

### 5-1. `DBCC SQLPERF` でクリアする

```sql
-- 待機統計をクリア(サーバー全体・全データベース共通)
DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

-- ラッチ統計も同様にクリアできる
DBCC SQLPERF('sys.dm_os_latch_stats', CLEAR);
```

> ⚠️ **影響を必ず理解してから実行してください。**
> - **サーバー全体・インスタンス単位の累計がゼロに戻ります**。
>   自分のセッションだけ、自分のデータベースだけ、ではありません。
> - **同居している他のシステムや、監視ツール(ベースライン収集)にも影響します**。
>   「昨日と比べて増えた/減った」を見ている監視が、その瞬間から狂います。
> - **元に戻す方法はありません**。消えた累計は復元できません。
> - 実行には **`ALTER SERVER STATE`** 権限が必要です。
>
> **本番の共有サーバーでは原則実行しないこと。**
> 学習環境(自分専用の開発機)なら、実験の前後で気軽に使って構いません。
> 本番で「今」を見たいなら、次のスナップショット差分を使います。

クリアした場合は、**いつクリアしたかを必ず記録**しておきます(そうしないと母数が分からなくなる)。

```sql
-- クリア直後は wait_time_ms がほぼ 0 になる
DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
SELECT SYSDATETIME() AS クリア時刻;
```

### 5-2. スナップショット差分(本番でも安全な本命の手法)

**開始時点と終了時点の2枚の写真を撮り、引き算する**だけです。誰にも迷惑を掛けません。

```sql
/* ============================================================
   ステップ①: 計測開始 — 開始スナップショットを撮る
   ※ #WaitSnapshot は一時テーブルなので、①〜③は
     「同じセッション(同じクエリウィンドウ)」で実行すること
   ============================================================ */
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
```

```sql
/* ============================================================
   ステップ②: この間に負荷を掛ける
     - 別ウィンドウで負荷スクリプトを走らせる
     - あるいは本番なら「遅い」と言われている時間帯をそのまま待つ
   ここでは 60 秒待つ例
   ============================================================ */
WAITFOR DELAY '00:01:00';
GO
```

```sql
/* ============================================================
   ステップ③: 差分を取る(これが「その60秒間に何を待ったか」)
   ============================================================ */
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
       -- ★ 正規化: 「計測期間中、常時何本のスレッドがこの待機で止まっていたか」
       CAST(合計待機ms * 1.0
            / NULLIF(@ElapsedMs, 0) AS DECIMAL(10, 2))            AS 待機秒毎秒
FROM   Positive
ORDER  BY 合計待機ms DESC;
GO
```

- **`待機秒毎秒`** が本番診断での実質的な主役です。
  `2.5` なら「常時 2.5 本のワーカーがこの待機で寝ていた」。
  論理 CPU が 8 個のサーバーで `PAGEIOLATCH_SH` が `6.0` なら、**深刻**です。
- **`#WaitSnapshot` は一時テーブルなので、①〜③は必ず同じセッションで実行**してください。
  ウィンドウを閉じると消えます。恒久的に残したいなら通常テーブルに変えます。

> ⚠️ **`GO` でバッチを区切っても一時テーブルは消えません**(セッションが続いている限り有効)。
> しかし **`DECLARE` した変数はバッチをまたげません**。上の③で `@ElapsedMs` を
> 同じバッチ内で宣言・使用しているのはそのためです。

### 5-3. どちらを使うか

| 状況 | 手法 |
|---|---|
| 自分専用の開発機で実験する | `DBCC SQLPERF(..., CLEAR)` が手軽 |
| **本番で「今」を診断する** | **スナップショット差分**(唯一の正解) |
| このサーバーの長期的な体質を知りたい | 累計をそのまま見る(稼働時間も併記する) |
| 継続的にベースラインを取りたい | 定期ジョブでスナップショットを恒久テーブルに蓄積する |

---

## 6. スコープを絞る — セッション単位 / 「今」

`sys.dm_os_wait_stats` は **インスタンス全体**の話です。もっと狭い範囲を見たいときの道具が3つあります。

### 6-1. `sys.dm_exec_session_wait_stats`(**SQL Server 2016+**)

**セッション単位の待機統計**。「このクエリを実行したら何を待つのか」を **1人で**調べられます。

```sql
-- 自分のセッションだけの待機を見る
SELECT wait_type            AS 待機タイプ,
       waiting_tasks_count  AS 待機回数,
       wait_time_ms         AS 合計待機ms,
       wait_time_ms - signal_wait_time_ms AS リソース待機ms,
       signal_wait_time_ms  AS シグナル待機ms,
       max_wait_time_ms     AS 最大待機ms
FROM   sys.dm_exec_session_wait_stats
WHERE  session_id = @@SPID
ORDER  BY wait_time_ms DESC;
```

**性質**:

- **接続してからの累計**です。**セッションを切断すると消えます**(再接続すると 0 から)。
- `DBCC SQLPERF(..., CLEAR)` の影響を受けません。**クリアする方法もありません**。
  → 「1本のクエリぶん」を測りたいなら、**やはりスナップショット差分**を使います。
- **他人のセッションも見られます**(`WHERE session_id = 55` など)。
  「あの遅いバッチが何を待っているか」をピンポイントで調べるのに最適です。

**典型的な使い方(1本のクエリの待機を測る)**:

```sql
-- ① 実行直前のスナップショット
DROP TABLE IF EXISTS #Before;
SELECT * INTO #Before
FROM   sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- ② 測りたいクエリ
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'完了';

-- ③ 差分
SELECT a.wait_type                                            AS 待機タイプ,
       a.waiting_tasks_count - ISNULL(b.waiting_tasks_count, 0) AS 待機回数,
       a.wait_time_ms        - ISNULL(b.wait_time_ms, 0)        AS 合計待機ms
FROM   sys.dm_exec_session_wait_stats AS a
LEFT   JOIN #Before AS b ON b.wait_type = a.wait_type
WHERE  a.session_id = @@SPID
  AND  a.wait_time_ms - ISNULL(b.wait_time_ms, 0) > 0
ORDER  BY 合計待機ms DESC;
```

### 6-2. `sys.dm_os_waiting_tasks` — **今まさに**待っているタスク

累計ではなく **スナップショット(瞬間の写真)** です。**ブロッキング調査の第一選択**。

```sql
SELECT  wt.session_id                          AS セッション,
        wt.exec_context_id                     AS 実行コンテキスト,  -- 0以外 = 並列の子スレッド
        wt.wait_type                           AS 待機タイプ,
        wt.wait_duration_ms                    AS 待機ms,           -- ★ 今この瞬間で何ms待っているか
        wt.blocking_session_id                 AS ブロック元,
        wt.resource_description                AS リソース詳細,
        s.login_name                           AS ログイン,
        s.host_name                            AS ホスト,
        s.program_name                         AS プログラム,
        r.status                               AS 要求状態,
        DB_NAME(r.database_id)                 AS データベース,
        t.text                                 AS 実行中SQL
FROM    sys.dm_os_waiting_tasks AS wt
LEFT    JOIN sys.dm_exec_sessions AS s ON s.session_id = wt.session_id
LEFT    JOIN sys.dm_exec_requests AS r ON r.session_id = wt.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   wt.session_id > 50                -- システムセッションを除外
  AND   wt.session_id <> @@SPID           -- 自分自身を除外
ORDER   BY wt.wait_duration_ms DESC;
```

- **`resource_description`** が非常に有益です。
  - ロックなら `KEY: 8:72057594043432960 (98ec012aa510)` のようにロック対象が入ります。
  - `PAGELATCH` なら `2:1:1` のように **DB:ファイル:ページ**。
- **`exec_context_id`** が 0 以外の行は **並列クエリの子スレッド**です。
  `CXPACKET` がずらっと並ぶのはこれ。

### 6-3. `sys.dm_exec_requests` — 実行中リクエストの現在の待機

```sql
SELECT r.session_id          AS セッション,
       r.status              AS 状態,           -- running / runnable / suspended
       r.command             AS コマンド,
       r.wait_type           AS 現在の待機,      -- NULL = 待っていない
       r.last_wait_type      AS 直前の待機,      -- ★ wait_type が NULL でもこれは残る
       r.wait_time           AS 待機ms,
       r.wait_resource       AS 待機リソース,
       r.blocking_session_id AS ブロック元,
       r.cpu_time            AS CPU_ms,
       r.total_elapsed_time  AS 経過ms,
       r.reads, r.writes, r.logical_reads,
       r.percent_complete    AS 進捗率            -- BACKUP/RESTORE/DBCC などで有効
FROM   sys.dm_exec_requests AS r
WHERE  r.session_id > 50
  AND  r.session_id <> @@SPID
ORDER  BY r.total_elapsed_time DESC;
```

- **`status`** が 1 節の3状態そのものです。**`suspended` なら `wait_type` を見る、
  `runnable` なら CPU 待ち**、という読み方が直接できます。
- **`last_wait_type`** は「たった今 `running` に戻ったが、直前は何を待っていたか」が分かるので、
  一瞬しか待たない待機を捕まえるのに有効です。

### 6-4. 使い分けまとめ

| DMV | 範囲 | 時間軸 | 使いどころ | バージョン |
|---|---|---|---|---|
| `sys.dm_os_wait_stats` | **インスタンス全体** | 起動からの**累計** | **診断の出発点**。差分を取って使う | すべて |
| `sys.dm_exec_session_wait_stats` | **セッション単位** | 接続からの**累計** | 特定のバッチ/クエリだけを測る。他人のセッションも可 | **2016+** |
| `sys.dm_os_waiting_tasks` | 全タスク | **今この瞬間** | **ブロッキング調査**。誰が誰を止めているか | すべて |
| `sys.dm_exec_requests` | 実行中リクエスト | **今この瞬間** | 実行中クエリの状態・進捗・待機 | すべて |

**実務の流れ**:

```
  ① dm_os_wait_stats の差分     → 「このサーバーは何で待っているか」(全体傾向)
        ↓ 上位が LCK_M_* なら
  ② dm_os_waiting_tasks         → 「今、誰が誰をブロックしているか」(犯人特定)
        ↓ 上位が I/O や CPU 系なら
  ③ Query Store / dm_exec_query_stats → 「どのクエリが原因か」(24章 / 26章)
        ↓
  ④ 実行プラン + STATISTICS IO  → 「そのクエリの何が悪いか」(18章)
```

---

## 7. 待機統計だけで判断しない(この節を読み飛ばさないこと)

待機統計は強力ですが、**万能ではありません**。誤用を避けるために、限界を明確にしておきます。

### 7-1. 待機統計は「全体の傾向」であって「個別クエリの遅さ」ではない

`sys.dm_os_wait_stats` は **インスタンス全体で合算された数字**です。

- **上位の待機タイプが、あなたが困っているクエリの原因とは限りません**。
  夜間バッチが `PAGEIOLATCH_SH` を大量に積んでいるせいで1位になっているだけで、
  日中の遅い画面の原因は別、ということが普通に起こります。
- **だから 5-2 のスナップショット差分で「問題が起きている時間帯だけ」を切り出す**のです。

**個別クエリの遅さを追うには、別の道具を使ってください**:

| 知りたいこと | 使う道具 |
|---|---|
| **どのクエリが遅いのか / リソースを食っているのか** | [26 DMVによる調査](26_dmv_investigation.md) の `sys.dm_exec_query_stats` |
| **いつからプランが変わって遅くなったのか** | [24 Query Store](24_query_store.md)(**2016+**)。待機カテゴリも記録される |
| **特定のイベントを狙って捕まえたい** | [25 拡張イベント](25_extended_events.md) |
| **そのクエリの何が悪いのか** | [18 インデックスと実行プラン](18_indexes_execution_plans.md) |

> **Query Store の待機統計**(`sys.query_store_wait_stats`、**SQL Server 2017+**)は、
> **「クエリごとの待機」** を記録してくれます。待機タイプを細かい種別ではなく
> **カテゴリ**(CPU / Lock / Buffer IO / Memory / Network IO …)にまとめて持つ点が違いますが、
> **「全体の待機」と「個別クエリ」の橋渡し**として非常に有用です。24 章で扱います。

### 7-2. 待機が少なくても遅いことがある

**待機ゼロ = 快適、ではありません**。

- **純粋な CPU バウンド**のクエリは、ずっと RUNNING なので待機をほとんど積みません。
  でも 10 分掛かっているかもしれません。
- **非効率なプラン**で 6,000 ページを走査していても、全部メモリ上なら
  I/O 待機は 0 です(18 章で「論理読み取り数」を最重要指標にした理由がここにあります)。
- したがって **「待機統計」と「リソース消費(CPU / 論理読み取り)」は両方見る**必要があります。

### 7-3. 「1位の待機を潰す」だけでは終わらない

- ボトルネックを1つ解消すると、**次のボトルネックが顔を出します**(モグラたたき)。
  これは失敗ではなく、**正常な進み方**です。1回の計測で終わりにせず、**改善 → 再計測**を回します。
- **改善したことを、必ず同じ方法で再計測して確認する**。18 章の「論理読み取り数で語る」と同じ規律です。

### 7-4. ベースラインが無ければ「異常」は判定できない

- **平常時の待機プロファイルを取っておくこと**。
  障害時にだけ待機統計を見ても、「これは多いのか?普段どおりなのか?」が分かりません。
- 実務では、5-2 のスナップショットを **定期ジョブで恒久テーブルに蓄積**し、
  時間帯別の傾向を持っておくのが定石です。

### 7-5. 方法論としてのまとめ

```
   1. ベースラインを持つ            (平常時のスナップショットを蓄積)
   2. 問題の時間帯を差分で切り出す   (5-2)
   3. ノイズを除外して上位を見る     (3-2)
   4. リソース待機 / シグナル待機で   (2-1)
      「資源側か CPU 側か」を決める
   5. 平均待機 ms で                (2-1)
      「回数の問題か、1回の長さの問題か」を決める
   6. 4節の表で「次に見るもの」へ進む
   7. 個別クエリは Query Store / DMV へ (24章 / 26章)
   8. 直したら、同じ方法で再計測する
```

**推測を1つも挟まないこと。これが上級編の作法です。**

---

## 8. 実践 — 負荷を掛けて、実際に待機を発生させる

待機統計は **複数のセッションが同時に動いているときにしか、意味のある値が溜まりません**。
1人で1本ずつクエリを流しても、本番で見えるような待機は再現できません。

そのために `sample-db/05_workload.sql` を用意してあります。

### 8-1. 準備

```sql
-- sample-db/05_workload.sql の【準備】セクション(冒頭)を1回だけ実行する
--   → dbo.WorkloadTest(1000行)が作成される
-- ※ 業務テーブル(Orders 等)には一切触れません
```

前提として `sample-db/03_bulk_data.sql`(`dbo.OrdersBig` 100万行)が必要です。
また **`dbo.OrdersBig` に非クラスタ化インデックスが無い状態**(18 章の後片付け済み)が正しいスタート地点です。
インデックスが無いからこそ大きなスキャンが発生し、I/O 待機が観測できます。

### 8-2. ウィンドウの割り当て(SSMS のクエリウィンドウを5枚開く)

| ウィンドウ | 役割 | 流すもの |
|---|---|---|
| **W1** | 負荷(読み取り) | セクションA |
| **W2** | 負荷(読み取り) | セクションA(同じものをもう1つ) |
| **W3** | 負荷(書き込み) | セクションB |
| **W4** | 観測(瞬間) | セクションE / `sys.dm_os_waiting_tasks` |
| **W5** | **計測(差分)** | 5-2 のステップ①→②→③ |

**実行の順序が重要です**:

```
   ① W5 でステップ①(開始スナップショット)を実行
   ② すぐに W1 → W2 → W3 の順で負荷スクリプトを起動(各60秒で自動終了)
   ③ 負荷が走っている間に W4 で観測クエリを何度か実行
   ④ 60秒経過して負荷が止まったら、W5 でステップ③(差分)を実行
```

> ⚠️ **W5 のステップ①と③は必ず同じウィンドウで**実行してください(一時テーブルのため)。
> また、**W5 のステップ②(`WAITFOR DELAY`)を使わずに手動で待っても構いません**。
> その場合、経過時間は自分でメモしてください。

### 8-3. 何が観測できるか(期待される結果)

| 流した負荷 | 期待される支配的な待機 | 理由 |
|---|---|---|
| セクションA(読み取り) | `PAGEIOLATCH_SH`, `SOS_SCHEDULER_YIELD`, `CXPACKET`/`CXCONSUMER` | 100万行のスキャン。メモリに乗り切れば I/O は減り CPU 系が増える |
| セクションB(書き込み) | `WRITELOG`, `PAGELATCH_EX`, `LCK_M_U`/`LCK_M_X` | 短いトランザクションを高速で繰り返す |
| セクションC + D(ブロッキング) | `LCK_M_S`(最大待機が数十秒) | 排他ロックを 30 秒保持したまま読ませる |

> ⚠️ **結果は環境によって大きく変わります**。
> メモリが潤沢で `dbo.OrdersBig` が全部バッファプールに乗っていれば、
> `PAGEIOLATCH_SH` はほとんど出ず、代わりに `SOS_SCHEDULER_YIELD` が支配的になります。
> **「教科書どおりに出ないこと」自体が学びです**。なぜそうなったかを 4 節の表で説明してみてください。

### 8-4. 後片付け

```sql
-- 05_workload.sql の【後片付け】セクションを実行する
SELECT @@TRANCOUNT AS 未完了トランザクション数;   -- 0 であることを確認
DROP TABLE IF EXISTS dbo.WorkloadTest;
```

- **セクションC を途中で止めた場合、トランザクションが開いたままロックを持ち続けます**。
  必ず `@@TRANCOUNT` を確認し、0 でなければ `ROLLBACK TRANSACTION;` を実行してください。
- ウィンドウを閉じれば接続が切れてロールバックされますが、**明示的に確認する習慣**をつけましょう。

---

## よくあるつまずき

- **`SLEEP_TASK` や `XE_TIMER_EVENT` が1位で焦る** → **アイドル待機**。3 節のフィルタで除外する。
- **累計値を見て「このサーバーは I/O ボトルネック」と結論する** → それは**稼働期間ぶんの平均**。
  今の話をしたいなら **5-2 のスナップショット差分**を取る。
- **`wait_time_ms` だけ見て打ち手を決める** → `wait_time_ms` には **シグナル待機が含まれる**。
  **`wait_time_ms - signal_wait_time_ms`** で資源側の待ちを分離する。
- **`PAGEIOLATCH` と `PAGELATCH` を混同する** → **`IO` の2文字が全然違う意味**(4-7 節)。
  前者はディスク、後者はメモリ上の競合。打ち手が正反対になる。
- **`ASYNC_NETWORK_IO` を見て「ネットワークを増強しよう」** → 大半は **クライアントの読み方**が原因。
  調査対象をアプリに移すのが正解(4-8 節)。
- **`CXPACKET` が上位=並列が悪、と即断する** → **2016 SP2 / 2017 CU3+ では `CXCONSUMER` が分離**され、
  そちらはほぼ無害。並列度を下げる前に、**推定行数の誤り**を疑う。
- **`THREADPOOL` に対して `max worker threads` を増やす** → 対症療法。
  **真犯人はブロッキング**であることがほとんど(4-9 節)。
- **本番で `DBCC SQLPERF(..., CLEAR)` を実行してしまう** → **サーバー全体の累計が消え、復元できない**。
  監視ツールのベースラインも壊れる(5-1 節)。
- **一時テーブルのスナップショットを別ウィンドウで取ろうとする** → `#WaitSnapshot` は**セッション内でのみ有効**。
- **待機が少ないから健全だと思う** → **CPU バウンドのクエリは待機を積まない**(7-2 節)。
  論理読み取り数・CPU 時間と併せて見る。
- **1回測って終わりにする** → 1つ潰すと次が出る。**改善 → 再計測**を回すのが正しい進め方。

## この章のまとめ

- SQL Server のワーカーは **RUNNING / RUNNABLE / SUSPENDED** を巡る。
  **RUNNABLE = CPU の順番待ち(シグナル待機)**、**SUSPENDED = 資源待ち(リソース待機)**。
  **この区別が診断の出発点**。
- **`wait_time_ms = リソース待機 + signal_wait_time_ms`**。
  したがって **リソース待機 = `wait_time_ms - signal_wait_time_ms`**。必ず自分で計算する。
- **シグナル待機の比率が高い(目安 25% 超)なら CPU 圧迫**を疑い、
  `sys.dm_os_schedulers.runnable_tasks_count` を確認する。
- **アイドル待機(`SLEEP_*` / `XE_TIMER_EVENT` / `BROKER_*` / `CHECKPOINT_QUEUE` …)を
  除外しないと読めない**。除外リスト付きのクエリを自分の道具として持つこと。
  ただし **`HADR_SYNC_COMMIT` は除外しない**。
- 主要な待機タイプは **「疑うこと」と「次に見るもの」をセットで**覚える。
  特に **`PAGEIOLATCH_*`(ディスク)と `PAGELATCH_*`(メモリ上の競合)は別物**、
  **`ASYNC_NETWORK_IO` はクライアント側の問題**、
  **`THREADPOOL` の真犯人はブロッキング**。
- `sys.dm_os_wait_stats` は **サーバー起動からの累計**。
  **`DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR)` はサーバー全体の累計を消す**ため本番では使わない。
  本番では **スナップショット差分**を取る。
- 差分は **`待機時間ms ÷ 経過時間ms`** に正規化すると、
  「常時何本のスレッドが待っていたか」という比較可能な指標になる。
- スコープ別の使い分け:
  **`sys.dm_os_wait_stats`(全体・累計)/ `sys.dm_exec_session_wait_stats`(セッション・2016+)/
  `sys.dm_os_waiting_tasks`(今)/ `sys.dm_exec_requests`(今の実行中)**。
- **待機統計は全体傾向であって、個別クエリの遅さの答えではない**。
  そこから先は [24 Query Store](24_query_store.md)・[26 DMVによる調査](26_dmv_investigation.md)・
  [18 実行プラン](18_indexes_execution_plans.md) に引き継ぐ。
- **推測しない。測る。直す。また測る。**

➡ 演習: [exercises/23_wait_statistics.md](../exercises/23_wait_statistics.md)
