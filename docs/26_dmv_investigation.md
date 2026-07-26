# 26 DMV による調査

> **このトピックのゴール**: 「サーバーが遅い」と言われたときに、**推測せずに DMV で事実を取り出す**。
> 今動いているクエリ・過去に重かったクエリ・インデックスの使われ方・IO とメモリの状態を、
> **その場でコピペして使える調査クエリ**として手元に持つ。
> そして「DMV の数字をどこまで信じてよいか」の**線引き**ができるようになる。
>
> **前提**: [25 拡張イベント (Extended Events)](25_extended_events.md) までを済ませていること。
> **さらに、この章は `sample-db/03_bulk_data.sql`(`dbo.OrdersBig` 100万行)と
> `sample-db/05_workload.sql`(負荷生成)を使います。** 未実行なら先に流してください。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

この章は **「調査クエリの武器庫」** です。理屈の説明よりも、
**現場でそのまま貼り付けて答えが出るクエリ**を揃えることを優先しています。
自分の環境で1本ずつ実行し、**気に入ったものはスニペットとして保存**しておいてください。

---

## 1. DMV / DMF とは

**DMV**(Dynamic Management View / 動的管理ビュー)と
**DMF**(Dynamic Management Function / 動的管理関数)は、
SQL Server が **メモリ上に持っている内部状態を、テーブルのように SELECT できるようにしたもの** です。

- 実体はテーブルではなく、**問い合わせた瞬間の内部構造体のスナップショット**です。
- そのため **トランザクションログにも残らず、バックアップにも入りません**。
  サーバーが再起動すれば、多くは消えます(1-3 節)。
- すべて `sys.` スキーマにあり、名前は `sys.dm_` で始まります。

### 1-1. カテゴリ(名前の2番目の語で用途が分かる)

| プレフィックス | 対象 | 代表的なもの |
|---|---|---|
| `sys.dm_exec_*` | **クエリの実行**(セッション/リクエスト/プラン/統計) | `dm_exec_requests`, `dm_exec_sessions`, `dm_exec_query_stats`, `dm_exec_sql_text`, `dm_exec_query_plan`, `dm_exec_cached_plans` |
| `sys.dm_os_*` | **SQLOS**(スケジューラ/待機/メモリ/カウンター) | `dm_os_wait_stats`, `dm_os_waiting_tasks`, `dm_os_memory_clerks`, `dm_os_performance_counters`, `dm_os_sys_info` |
| `sys.dm_db_*` | **データベース内のオブジェクト**(インデックス/統計/領域) | `dm_db_index_usage_stats`, `dm_db_index_physical_stats`, `dm_db_missing_index_details`, `dm_db_partition_stats`, `dm_db_stats_properties` |
| `sys.dm_tran_*` | **トランザクションとロック** | `dm_tran_locks`, `dm_tran_active_transactions`, `dm_tran_session_transactions` |
| `sys.dm_io_*` | **物理 IO** | `dm_io_virtual_file_stats`, `dm_io_pending_io_requests` |

「どの DMV を見ればいいか分からない」ときは、
**まず対象がどのレイヤの話かを決めて、対応するプレフィックスを探す** のが近道です。

### 1-2. ビュー(DMV)と関数(DMF)の違い

**DMF は引数が要ります**。だから `FROM` に直接書くか、`CROSS APPLY` / `OUTER APPLY` で
他の行の値を渡して使います([14 APPLY](14_apply.md) の知識がここで効きます)。

```sql
-- DMV: そのまま SELECT できる
SELECT TOP (5) session_id, status, command FROM sys.dm_exec_requests;

-- DMF: 引数が必要。定数を渡す形
SELECT * FROM sys.dm_io_virtual_file_stats(DB_ID(N'SalesLearning'), NULL);

-- DMF: 各行の値を渡す形(これが最頻出パターン)
SELECT r.session_id, t.text
FROM   sys.dm_exec_requests AS r
CROSS  APPLY sys.dm_exec_sql_text(r.sql_handle) AS t;
```

> ⚠️ `sql_handle` や `plan_handle` が **NULL になる行**があります(まだハンドルが確定していない等)。
> `CROSS APPLY` だとその行が結果から**消えてしまう**ので、
> **調査用途では `OUTER APPLY` を既定にする** ほうが事故が少ないです。

### 1-3. 【最重要の前提】多くの DMV は「いつからの集計か」が決まっている

DMV の数値の大半は **累積値** です。**「いつリセットされたか」を知らずに読むと必ず誤読します。**

| DMV | リセットされるタイミング |
|---|---|
| `sys.dm_exec_query_stats` | **プランがキャッシュから落ちた/再コンパイルされた**とき、`DBCC FREEPROCCACHE`、サーバー再起動 |
| `sys.dm_exec_procedure_stats` | 同上(プロシージャのプランが落ちたとき) |
| `sys.dm_exec_cached_plans` | 同上(メモリ不足による追い出しも含む) |
| `sys.dm_os_wait_stats` | サーバー再起動、`DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR)` |
| `sys.dm_db_index_usage_stats` | **サーバー再起動**(DB のデタッチ/オフラインでもその DB 分が消える) |
| `sys.dm_db_missing_index_*` | サーバー再起動、**対象テーブルにインデックス DDL を実行**したとき |
| `sys.dm_io_virtual_file_stats` | サーバー再起動(ファイル単位。DB オフラインでも消える) |

だから調査の **1本目のクエリは必ずこれ** です。

```sql
-- 【定番①】この数字は「いつから」の集計なのか
SELECT sqlserver_start_time                                        AS 起動時刻,
       DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME())         AS 稼働時間_時,
       DATEDIFF(MINUTE, sqlserver_start_time, SYSDATETIME())       AS 稼働時間_分
FROM   sys.dm_os_sys_info;
```

> ⚠️ **起動から30分のサーバーで「CPU 合計上位」を見ても意味がありません**。
> 逆に **半年動きっぱなしのサーバーの合計値**は、去年のバッチの残骸を含んでいるかもしれません。
> 「稼働時間 → その割に大きいか?」で読むこと。
> **リセットされない履歴が欲しいなら [24 Query Store](24_query_store.md)** を使います。
> これが Query Store と DMV の一番大きな違いです。

### 1-4. 権限

| 範囲 | 必要な権限 |
|---|---|
| サーバースコープの DMV(`dm_os_*`, `dm_exec_*` の多く) | **`VIEW SERVER STATE`** |
| データベーススコープの DMV(`dm_db_*` の多く) | **`VIEW DATABASE STATE`** |

```sql
-- 調査担当者に読み取りだけ許可する例(sysadmin を配らないこと)
-- GRANT VIEW SERVER STATE TO [調査用ログイン];
```

- SQL Server 2022 では、より限定的な `VIEW SERVER PERFORMANCE STATE` /
  `VIEW SERVER SECURITY STATE` に分割されました(**2022+**)。
- Azure SQL Database では `VIEW DATABASE STATE` が中心で、サーバー全体の DMV は使えないものがあります。

### 1-5. 調査クエリ自身が負荷にならないように

- `sys.dm_exec_query_stats` は **プランキャッシュ全体を走査**します。
  キャッシュが数万プランある本番では **必ず `TOP (n)` + `ORDER BY`** で絞る。
- `sys.dm_exec_query_plan`(XML)は重い。**上位数十件に絞ってから `OUTER APPLY`** する。
- `sys.dm_db_index_physical_stats` の `DETAILED` は **インデックスを全部読む**(4-4 節)。本番では既定の `LIMITED` から。

---

## 2. 【今何が起きているか】

`sample-db/05_workload.sql` の **セクションA(読み取り負荷)を2つのウィンドウで起動**してから、
この節のクエリを **別のウィンドウ**で実行してください。何も動いていないと何も見えません。

### 2-1. 実行中クエリ一覧(この章の主役)

`sys.dm_exec_requests`(**今まさに実行中のリクエスト**)に、
`sys.dm_exec_sessions`(**接続の属性**)を足し、`sys.dm_exec_sql_text` で **SQL 本文**を取ります。

```sql
-- 【定番②】今、誰が何を実行していて、何を待っているか
SELECT  r.session_id                                  AS セッション,
        s.login_name                                  AS ログイン,
        s.host_name                                   AS ホスト,
        s.program_name                                AS アプリ,
        DB_NAME(r.database_id)                        AS DB,
        r.status                                      AS 状態,
        r.command                                     AS コマンド,
        r.wait_type                                   AS 待機タイプ,
        r.wait_time                                   AS 待機ms,
        r.last_wait_type                              AS 直前の待機,
        r.blocking_session_id                         AS ブロック元,
        r.cpu_time                                    AS CPUms,
        r.total_elapsed_time                          AS 経過ms,
        r.logical_reads                               AS 論理読み取り,
        r.reads                                       AS 物理読み取り,
        r.writes                                      AS 書き込み,
        r.open_transaction_count                      AS 未完了トラン,
        r.percent_complete                            AS 進捗率,
        -- ★実行中の「そのステートメントだけ」を切り出す(3-2 節と同じイディオム)
        SUBSTRING(t.text,
                  (r.statement_start_offset / 2) + 1,
                  ((CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(t.text)
                        ELSE r.statement_end_offset
                    END - r.statement_start_offset) / 2) + 1)   AS 実行中ステートメント,
        t.text                                        AS バッチ全体
FROM    sys.dm_exec_requests  AS r
JOIN    sys.dm_exec_sessions  AS s
        ON  s.session_id = r.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   s.is_user_process = 1            -- システムセッションを除く
  AND   r.session_id <> @@SPID           -- 自分自身を除く
ORDER   BY r.total_elapsed_time DESC;
```

読みどころ:

- **`status`** … `running`(CPU 実行中) / `runnable`(CPU 待ち行列) / `suspended`(**何かを待っている**)。
  `suspended` が多ければ `wait_type` を見る。`runnable` だらけなら **CPU 不足**を疑う。
- **`wait_type` と `wait_time`** … 今この瞬間の待機。**種類の意味は [23 待機統計](23_wait_statistics.md)** 参照。
- **`blocking_session_id`** … 0 以外なら **他人に止められている**(2-3 節)。
- **`percent_complete`** … `BACKUP` / `RESTORE` / `DBCC` / インデックス再構築など、
  **一部のコマンドでしか埋まりません**。普通の `SELECT` では常に 0 です。
- **`open_transaction_count`** … 1 以上のまま `sleeping` なら「**開きっぱなしトランザクション**」の疑い。

> ⚠️ `sys.dm_exec_sessions` の `cpu_time` / `reads` は **接続してからの累計**、
> `sys.dm_exec_requests` の同名列は **今のリクエストの分**です。**別物なので混同しないこと**。

> ⚠️ `sys.dm_exec_requests` には **実行中のものしか出ません**。
> 「さっき遅かったクエリ」を探しているなら、この DMV では手遅れです。3 節へ進んでください。

### 2-2. 実行中クエリのプランを取る

「今まさに遅いクエリ」を止めずに、**そのプランだけ**を覗けます。

```sql
-- 【定番③】実行中クエリの実行プラン(XML)を取得する
--          結果の query_plan 列をクリックすると SSMS がグラフィカルプランで開く
SELECT  r.session_id                AS セッション,
        r.status                    AS 状態,
        r.wait_type                 AS 待機タイプ,
        r.total_elapsed_time        AS 経過ms,
        t.text                      AS SQL本文,
        p.query_plan                AS 実行プラン
FROM    sys.dm_exec_requests AS r
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle)   AS t
OUTER   APPLY sys.dm_exec_query_plan(r.plan_handle) AS p
WHERE   r.session_id <> @@SPID
  AND   r.session_id > 50;
```

`sys.dm_exec_query_plan` には落とし穴があります。

- 戻り値は `XML` 型で、**ネストが 128 レベルを超えると NULL** になります
  (深い入れ子ビューや長い `UNION ALL` で起きる)。
- **バッチ全体のプラン**が返ります。特定ステートメントだけ欲しいときは次を使います。

```sql
-- 【定番④】NVARCHAR で返るので 128 レベル制限を回避できる。
--          statement offset を渡せば「そのステートメントのプランだけ」取れる。
SELECT  r.session_id,
        p.query_plan            -- NVARCHAR(MAX)。長い場合は自分でファイルに保存する
FROM    sys.dm_exec_requests AS r
OUTER   APPLY sys.dm_exec_text_query_plan(r.plan_handle,
                                          r.statement_start_offset,
                                          r.statement_end_offset) AS p
WHERE   r.session_id <> @@SPID
  AND   r.session_id > 50;
```

| | `sys.dm_exec_query_plan` | `sys.dm_exec_text_query_plan` |
|---|---|---|
| 戻り型 | `XML` | `NVARCHAR(MAX)` |
| SSMS でクリックして開ける | ○ | ✗(保存して `.sqlplan` にする) |
| 128 ネスト制限 | **あり(NULL になる)** | なし |
| ステートメント指定 | 不可 | **可(offset を渡す)** |

> ⚠️ ここで取れるのは **推定プラン相当**(コンパイル時の情報)です。
> **実際の行数は入っていません**。実行中クエリの実測が欲しいなら
> `sys.dm_exec_query_profiles`(**2014+**、`SET STATISTICS PROFILE ON` または
> **2016+** の軽量プロファイリング有効時)を使います。

### 2-3. ブロッキングチェーンを特定する

`sample-db/05_workload.sql` の **セクションC(ブロッカー)** を1つのウィンドウで実行し、
すぐに **セクションD** を別のウィンドウで実行してから、以下を試してください。

まず素朴な形。

```sql
-- 【定番⑤】ブロックされている側と、ブロックしている側を並べる
SELECT  r.session_id            AS 被害者,
        r.blocking_session_id   AS ブロック元,
        r.wait_type             AS 待機タイプ,
        r.wait_time             AS 待機ms,
        r.wait_resource         AS 待機リソース,
        tv.text                 AS 被害者のSQL,
        tb.text                 AS ブロック元のSQL
FROM    sys.dm_exec_requests AS r
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS tv
LEFT    JOIN sys.dm_exec_connections AS cb
        ON  cb.session_id = r.blocking_session_id
OUTER   APPLY sys.dm_exec_sql_text(cb.most_recent_sql_handle) AS tb
WHERE   r.blocking_session_id <> 0;
```

> ⚠️ **ブロック元は `sys.dm_exec_requests` に居ないことが多い**。
> 「`BEGIN TRAN` して `UPDATE` した後、`COMMIT` せずに放置」しているセッションは
> **`sleeping` / `awaiting command`** で、実行中リクエストが存在しません。
> だから **ブロック元の SQL は `sys.dm_exec_connections.most_recent_sql_handle` から取る**(上のクエリ)か、
> `sys.dm_exec_input_buffer(session_id, NULL)`(**2016 SP1+**)を使います。
> これを知らないと「ブロック元の犯人だけ SQL が空欄」で調査が止まります。

そして本命。**チェーンが3段・4段になると、犯人は一番奥にいます**。
再帰CTE([07 CTE](07_cte.md))で **先頭ブロッカー**まで辿ります。

```sql
-- 【定番⑥】ブロッキングチェーンを木構造で表示し、先頭ブロッカーを特定する
WITH Waiting AS
(
    -- ブロックされているセッション
    SELECT r.session_id,
           r.blocking_session_id,
           r.wait_type,
           r.wait_time,
           r.wait_resource
    FROM   sys.dm_exec_requests AS r
    WHERE  r.blocking_session_id <> 0
      AND  r.blocking_session_id <> r.session_id   -- 並列内の自己待機は除外
),
Head AS
(
    -- 先頭ブロッカー = 誰かをブロックしているが、自分は誰にもブロックされていない
    SELECT DISTINCT w.blocking_session_id AS session_id
    FROM   Waiting AS w
    WHERE  NOT EXISTS (SELECT 1 FROM Waiting AS w2
                       WHERE w2.session_id = w.blocking_session_id)
),
Chain AS
(
    -- アンカー: 先頭ブロッカー(レベル0)
    SELECT  h.session_id,
            CAST(NULL AS INT)        AS blocking_session_id,
            0                        AS レベル,
            CAST(N'' AS NVARCHAR(20)) AS 待機タイプ,
            0                        AS 待機ms,
            CAST(CAST(h.session_id AS NVARCHAR(10)) AS NVARCHAR(400)) AS 連鎖
    FROM    Head AS h
    UNION ALL
    -- 再帰: そのセッションにブロックされている子を辿る
    SELECT  w.session_id,
            w.blocking_session_id,
            c.レベル + 1,
            CAST(w.wait_type AS NVARCHAR(20)),
            w.wait_time,
            CAST(c.連鎖 + N' > ' + CAST(w.session_id AS NVARCHAR(10)) AS NVARCHAR(400))
    FROM    Waiting AS w
    JOIN    Chain   AS c ON c.session_id = w.blocking_session_id
)
SELECT  REPLICATE(N'    ', c.レベル) + CAST(c.session_id AS NVARCHAR(10)) AS ツリー,
        c.レベル,
        c.連鎖,
        CASE WHEN c.レベル = 0 THEN N'★先頭ブロッカー' ELSE N'' END      AS 判定,
        c.待機タイプ,
        c.待機ms,
        s.login_name                AS ログイン,
        s.host_name                 AS ホスト,
        s.program_name              AS アプリ,
        s.status                    AS セッション状態,
        s.last_request_start_time   AS 直近リクエスト開始,
        ISNULL(t1.text, t2.text)    AS SQL本文
FROM    Chain AS c
JOIN    sys.dm_exec_sessions AS s ON s.session_id = c.session_id
LEFT    JOIN sys.dm_exec_requests    AS r  ON r.session_id  = c.session_id
LEFT    JOIN sys.dm_exec_connections AS cn ON cn.session_id = c.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle)               AS t1
OUTER   APPLY sys.dm_exec_sql_text(cn.most_recent_sql_handle)  AS t2
ORDER   BY c.連鎖
OPTION (MAXRECURSION 100);
```

- **レベル0 の行が犯人候補**です。ここを止めれば下流が全部動き出します。
- `s.status = 'sleeping'` かつレベル0 なら、**アプリがトランザクションを閉じ忘れている**典型。
  `s.program_name` と `s.host_name` が、どのアプリの誰かを教えてくれます。

> ⚠️ 再帰CTE は **循環があると無限に回ります**。通常ブロッキングの循環はデッドロック検出で
> 自動解消されますが、保険として **`OPTION (MAXRECURSION 100)`** を必ず付けてください。

> ⚠️ 犯人が分かっても **`KILL` は最後の手段**です。ロールバックに実行時間以上かかることがあり、
> その間 **さらに長くブロックが続く**ことすらあります。まずアプリ側の停止を検討してください。

### 2-4. `sys.dm_os_waiting_tasks` — タスク単位の待機

`sys.dm_exec_requests` は **リクエスト単位**、`sys.dm_os_waiting_tasks` は **タスク(スレッド)単位**です。
**並列クエリは1リクエストが複数タスクに分かれる**ので、こちらでしか見えないものがあります。

```sql
-- 【定番⑦】今この瞬間、待っているタスクの一覧
SELECT  wt.session_id,
        wt.exec_context_id            AS 実行コンテキスト,   -- 0 以外なら並列の子スレッド
        wt.wait_type                  AS 待機タイプ,
        wt.wait_duration_ms           AS 待機ms,
        wt.blocking_session_id        AS ブロック元セッション,
        wt.blocking_exec_context_id   AS ブロック元コンテキスト,
        wt.resource_description       AS リソース詳細,
        s.login_name,
        s.program_name,
        t.text                        AS SQL本文
FROM    sys.dm_os_waiting_tasks AS wt
JOIN    sys.dm_exec_sessions    AS s ON s.session_id = wt.session_id
LEFT    JOIN sys.dm_exec_requests AS r ON r.session_id = wt.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   s.is_user_process = 1
  AND   wt.session_id <> @@SPID
ORDER   BY wt.wait_duration_ms DESC;
```

| | `sys.dm_os_wait_stats` | `sys.dm_os_waiting_tasks` |
|---|---|---|
| 見えるもの | **起動からの累積**(誰が待ったかは分からない) | **今この瞬間**の待機(セッション付き) |
| 用途 | 傾向をつかむ([23 章](23_wait_statistics.md)) | **今の障害**の犯人特定 |

- `exec_context_id` が 0 以外の行が並んでいて `wait_type` が `CXPACKET` / `CXCONSUMER` なら、
  **並列実行の内部待機**です([29 結合アルゴリズムと並列処理](29_join_algorithms_parallelism.md))。
- `blocking_session_id` が自分自身なら、それは **並列タスク同士の待ち合わせ**であってブロッキングではありません。

### 2-5. トランザクションを開きっぱなしのセッションを探す

```sql
-- 【定番⑧】開きっぱなしトランザクションの犯人探し
SELECT  st.session_id,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status                        AS セッション状態,
        at.transaction_begin_time       AS トラン開始時刻,
        DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()) AS 経過秒,
        at.transaction_state            AS トラン状態,
        s.last_request_end_time         AS 最後のリクエスト終了,
        t.text                          AS 直近のSQL
FROM    sys.dm_tran_session_transactions AS st
JOIN    sys.dm_tran_active_transactions  AS at ON at.transaction_id = st.transaction_id
JOIN    sys.dm_exec_sessions             AS s  ON s.session_id      = st.session_id
LEFT    JOIN sys.dm_exec_connections     AS cn ON cn.session_id     = st.session_id
OUTER   APPLY sys.dm_exec_sql_text(cn.most_recent_sql_handle) AS t
WHERE   s.is_user_process = 1
ORDER   BY at.transaction_begin_time;
```

- **経過秒が数百秒**で `セッション状態 = sleeping` なら、ほぼ確実にアプリのバグです
  ([19 トランザクションと分離レベル](19_transactions_isolation.md))。

---

## 3. 【過去に何が重かったか】

ここからが **DMV 調査の本丸**です。`sys.dm_exec_requests` は「今」しか見えませんが、
`sys.dm_exec_query_stats` は **プランキャッシュに残っている限りの累積実績**を持っています。

### 3-1. `sys.dm_exec_query_stats` の中核列

**ステートメント1本 × プラン1つ** につき1行です。

| 列 | 意味 | 単位 |
|---|---|---|
| `execution_count` | 実行回数 | 回 |
| `total_worker_time` | **CPU 時間の合計** | **マイクロ秒** |
| `total_elapsed_time` | 経過時間の合計(待ち時間込み) | **マイクロ秒** |
| `total_logical_reads` | **論理読み取りの合計** | 8KB ページ数 |
| `total_physical_reads` | 物理読み取りの合計 | 8KB ページ数 |
| `total_logical_writes` | 論理書き込みの合計 | 8KB ページ数 |
| `total_rows` | 返した行数の合計 | 行 |
| `creation_time` / `last_execution_time` | **プランが作られた時刻 / 最後に実行された時刻** | |
| `plan_handle` / `sql_handle` | プラン・SQL を引くためのハンドル | |
| `query_hash` / `query_plan_hash` | **リテラル違いを同一視する**ためのハンドル | |
| `statement_start_offset` / `statement_end_offset` | バッチ内でのこのステートメントの位置 | **バイト** |

- **`total_worker_time` は CPU、`total_elapsed_time` は壁時計**。
  `elapsed >> worker` なら **待たされている**(IO・ロック・並列待ち)。
  `worker ≒ elapsed` なら **純粋に CPU を焼いている**。この2列の比較だけで方向性が半分決まります。
- **単位はマイクロ秒**です。ミリ秒だと思って読むと1000倍間違えます。`/ 1000.0` してミリ秒に直しましょう。
- `total_grant_kb` / `total_used_grant_kb` / `total_ideal_grant_kb`(**2016+**)は
  メモリ許可の過不足を見るのに使えます(5-4 節)。
- `total_spills`(**2016 SP2 / 2017 CU3 以降**)は tempdb への溢れ。0 でないなら推定行数の誤りを疑う([27 章](27_statistics_cardinality.md))。

### 3-2. 【必修】`statement_start_offset` で「そのステートメントだけ」を切り出す

`sys.dm_exec_sql_text` が返す `text` は **バッチ全体**(プロシージャなら本体まるごと)です。
そのままだと「300行のプロシージャのどこが重いのか」が分かりません。

`statement_start_offset` / `statement_end_offset` は **バイト単位のオフセット**なので、
`nchar`(2バイト)に合わせて **2で割る** のがポイントです。**この定番の書き方を丸暗記してください。**

```sql
SUBSTRING(st.text,
          (qs.statement_start_offset / 2) + 1,
          ((CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)     -- -1 は「バッチの最後まで」
                ELSE qs.statement_end_offset
            END - qs.statement_start_offset) / 2) + 1)
```

- `statement_end_offset = -1` は **「バッチの終端まで」** の意味。`DATALENGTH` で置き換えます。
- `DATALENGTH`(**バイト長**)を使うこと。`LEN`(文字数)ではズレます。
- `/ 2 + 1` は 1 始まりの `SUBSTRING` に合わせるため。

### 3-3. 三種の神器: CPU 上位 / 論理読み取り上位 / 実行回数上位

**同じ骨格で `ORDER BY` を変えるだけ**です。3本セットで持ち歩いてください。

#### (a) CPU を食っているクエリ

```sql
-- 【定番⑨】CPU 合計 上位20
SELECT TOP (20)
        qs.execution_count                                  AS 実行回数,
        qs.total_worker_time / 1000.0                       AS CPU合計ms,
        qs.total_worker_time / qs.execution_count / 1000.0  AS CPU平均ms,
        qs.total_elapsed_time / 1000.0                      AS 経過合計ms,
        qs.total_elapsed_time / qs.execution_count / 1000.0 AS 経過平均ms,
        qs.total_logical_reads                              AS 論理読み取り合計,
        qs.total_logical_reads / qs.execution_count         AS 論理読み取り平均,
        qs.creation_time                                    AS プラン作成時刻,
        qs.last_execution_time                              AS 最終実行時刻,
        DB_NAME(st.dbid)                                    AS DB,
        OBJECT_NAME(st.objectid, st.dbid)                   AS オブジェクト,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント,
        qs.query_hash,
        qs.plan_handle
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   st.dbid = DB_ID(N'SalesLearning')      -- 対象DBに絞る(アドホックは dbid が NULL のことがある)
ORDER   BY qs.total_worker_time DESC;
```

#### (b) 論理読み取りを食っているクエリ(IO / バッファプール圧迫の犯人)

上のクエリの `ORDER BY` を差し替えるだけです。

```sql
ORDER BY qs.total_logical_reads DESC;
```

- **論理読み取りは環境に左右されない指標**([18 章](18_indexes_execution_plans.md) の合言葉)。
  ここに出てくるクエリは、**インデックス設計で改善できる可能性がいちばん高い**候補です。
- 平均論理読み取りが数万〜数十万なら、**スキャンしている**と考えてまず間違いありません。

#### (c) 実行回数が異常に多いクエリ

```sql
ORDER BY qs.execution_count DESC;
```

- 1回 1ms でも **1時間に100万回**呼ばれていれば、それが最大の負荷源です。
- ここに「同じ形の SELECT」が並んだら、アプリ側の **N+1 問題**やキャッシュ漏れを疑います。

#### (d) リテラル違いをまとめて見る(`query_hash`)

パラメーター化されていない SQL は、リテラルごとに別プラン=別行になります。
**`query_hash` で GROUP BY すると「実質同じクエリ」の合計**が見えます。

```sql
-- 【定番⑩】query_hash 単位に集約して「本当の重量級」を見つける
SELECT TOP (20)
        qs.query_hash,
        COUNT(*)                                AS プラン数,       -- 多いならパラメーター化されていない
        SUM(qs.execution_count)                 AS 実行回数合計,
        SUM(qs.total_worker_time) / 1000.0      AS CPU合計ms,
        SUM(qs.total_logical_reads)             AS 論理読み取り合計,
        MIN(CAST(SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS NVARCHAR(400))) AS 代表ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
GROUP   BY qs.query_hash
ORDER   BY SUM(qs.total_worker_time) DESC;
```

**`プラン数` が数百**になっているものがあれば、それは 6-2 節の **シングルユース プラン肥大化**の原因です。

#### (e) 上位クエリのプランを取る

```sql
-- 上位10件だけプランXMLを取る(全件に APPLY しないこと)
WITH Top10 AS
(
    SELECT TOP (10) qs.plan_handle, qs.total_worker_time, qs.execution_count
    FROM   sys.dm_exec_query_stats AS qs
    ORDER  BY qs.total_worker_time DESC
)
SELECT  t.total_worker_time / 1000.0 AS CPU合計ms,
        t.execution_count            AS 実行回数,
        p.query_plan                 AS 実行プラン
FROM    Top10 AS t
OUTER   APPLY sys.dm_exec_query_plan(t.plan_handle) AS p;
```

### 3-4. 【判断】平均で見るか、合計で見るか

**これを間違えると、直しても効果が出ないクエリをチューニングすることになります。**

| 見方 | 意味 | こう使う |
|---|---|---|
| **合計**(`total_*`) | サーバー全体のリソースを **どれだけ食ったか** | **サーバーを軽くしたい**とき。ここを削れば全体が楽になる |
| **平均**(`total_* / execution_count`) | **1回あたり**の重さ | **「あの画面が遅い」** の原因を探すとき。ユーザー体験に直結 |
| **最大**(`max_*`) | 最悪ケース | **パラメーター スニッフィング**の疑い([28 章](28_parameter_sniffing.md)) |

判断の型:

- **合計が大きい & 平均が小さい** → 1回は軽いが **呼ばれすぎ**。
  直すのは SQL ではなく **アプリの呼び出し方**(ループ内発行・キャッシュ不足)。
- **合計が大きい & 平均も大きい** → **本命**。まずここをチューニングする。
- **合計は小さい & 平均が巨大** → 夜間バッチや月次処理。**ユーザーは困っていない**かもしれない。
  ただし実行中は他をブロックしうるので、時間帯とセットで判断。
- **`max_worker_time` が `total_worker_time / execution_count` の何十倍もある**
  → 同じプランで **速いときと遅いときがある**。パラメーター スニッフィングか、データ量の偏り。

```sql
-- 【定番⑪】平均と最悪のブレを見る(スニッフィング検知)
SELECT TOP (20)
        qs.execution_count                                     AS 実行回数,
        qs.total_worker_time / qs.execution_count / 1000.0     AS CPU平均ms,
        qs.min_worker_time / 1000.0                            AS CPU最小ms,
        qs.max_worker_time / 1000.0                            AS CPU最大ms,
        CAST(qs.max_worker_time * 1.0
             / NULLIF(qs.total_worker_time / qs.execution_count, 0) AS DECIMAL(10,1)) AS 最大_平均比,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   qs.execution_count >= 10
ORDER   BY 最大_平均比 DESC;
```

> ⚠️ `sys.dm_exec_query_stats` は **キャッシュに残っているプランの分しか見えません**。
> 「1日1回の重いバッチ」は、次に見るころにはプランが追い出されていて **1行も出てこない**ことがあります。
> **`creation_time` を必ず確認**し、履歴が必要なら [24 Query Store](24_query_store.md) を有効にしてください。
> Query Store は **プランが落ちてもディスクに残ります**。これが DMV との決定的な差です。

### 3-5. プロシージャ単位で見る `sys.dm_exec_procedure_stats`

「どのステートメントか」ではなく「**どのプロシージャか**」を知りたいときはこちら。
[16 ストアドプロシージャ](16_stored_procedures.md) を運用している現場ではこちらが起点になります。

```sql
-- 【定番⑫】重いプロシージャ 上位20
SELECT TOP (20)
        DB_NAME(ps.database_id)                             AS DB,
        OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id)    AS スキーマ,
        OBJECT_NAME(ps.object_id, ps.database_id)           AS プロシージャ名,
        ps.execution_count                                  AS 実行回数,
        ps.total_worker_time / 1000.0                       AS CPU合計ms,
        ps.total_worker_time / ps.execution_count / 1000.0  AS CPU平均ms,
        ps.total_elapsed_time / ps.execution_count / 1000.0 AS 経過平均ms,
        ps.total_logical_reads                              AS 論理読み取り合計,
        ps.total_logical_reads / ps.execution_count         AS 論理読み取り平均,
        ps.cached_time                                      AS キャッシュ時刻,
        ps.last_execution_time                              AS 最終実行時刻
FROM    sys.dm_exec_procedure_stats AS ps
WHERE   ps.database_id = DB_ID(N'SalesLearning')
ORDER   BY ps.total_worker_time DESC;
```

同系統の DMV:

| DMV | 対象 | バージョン |
|---|---|---|
| `sys.dm_exec_procedure_stats` | ストアドプロシージャ | 2008+ |
| `sys.dm_exec_trigger_stats` | トリガー | 2008+ |
| `sys.dm_exec_function_stats` | **スカラー UDF** | **2016+** |

- **プロシージャで重い → `sys.dm_exec_query_stats` を `plan_handle` で突き合わせて中のどのステートメントかを特定**、
  という2段階の絞り込みが定石です。

```sql
-- プロシージャ内の「どのステートメントが重いか」まで降りる
SELECT  OBJECT_NAME(st.objectid, st.dbid)                     AS プロシージャ名,
        qs.execution_count                                     AS 実行回数,
        qs.total_worker_time / 1000.0                          AS CPU合計ms,
        qs.total_logical_reads                                 AS 論理読み取り合計,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   st.objectid = OBJECT_ID(N'dbo.重いプロシージャ名')
ORDER   BY qs.total_worker_time DESC;
```

---

## 4. 【インデックスの健康診断】

### 4-1. `sys.dm_db_index_usage_stats` — 使われているか

| 列 | 意味 | 増えるとき |
|---|---|---|
| `user_seeks` | シーク回数 | Index Seek が実行された |
| `user_scans` | スキャン回数 | Index Scan が実行された |
| `user_lookups` | ルックアップ回数 | **Key Lookup / RID Lookup** で引かれた(クラスタ化側で増える) |
| `user_updates` | **更新回数** | **INSERT/UPDATE/DELETE でこのインデックスを書き換えた** |
| `last_user_seek` 等 | 最後に使われた日時 | |

```sql
-- 【定番⑬】dbo.OrdersBig のインデックス使用状況
SELECT  i.name                                          AS インデックス名,
        i.type_desc                                     AS 種別,
        ISNULL(us.user_seeks,   0)                      AS シーク,
        ISNULL(us.user_scans,   0)                      AS スキャン,
        ISNULL(us.user_lookups, 0)                      AS ルックアップ,
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
              + ISNULL(us.user_lookups, 0)              AS 読み取り合計,
        ISNULL(us.user_updates, 0)                      AS 更新,
        us.last_user_seek                               AS 最終シーク,
        us.last_user_scan                               AS 最終スキャン,
        us.last_user_update                             AS 最終更新
FROM    sys.indexes AS i
LEFT    JOIN sys.dm_db_index_usage_stats AS us
        ON  us.object_id   = i.object_id
        AND us.index_id    = i.index_id
        AND us.database_id = DB_ID()
WHERE   i.object_id = OBJECT_ID(N'dbo.OrdersBig')
ORDER   BY 読み取り合計 DESC;
```

> ⚠️ **`LEFT JOIN` が必須**です。**一度も使われていないインデックスは、この DMV に行が存在しません**。
> `INNER JOIN` で書くと「一番探したかったもの」が結果から消えます。**これは頻出のミスです。**

### 4-2. 使われていないインデックスの検出(更新コストだけ払っている)

```sql
-- 【定番⑭】DB全体から「削除候補」のインデックスを洗い出す
SELECT  DB_NAME()                                       AS DB,
        OBJECT_SCHEMA_NAME(i.object_id)                 AS スキーマ,
        OBJECT_NAME(i.object_id)                        AS テーブル,
        i.name                                          AS インデックス名,
        i.type_desc                                     AS 種別,
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
              + ISNULL(us.user_lookups, 0)              AS 読み取り合計,
        ISNULL(us.user_updates, 0)                      AS 更新回数,
        SUM(ps.used_page_count) * 8 / 1024              AS 使用MB,
        us.last_user_seek                               AS 最終シーク,
        us.last_user_scan                               AS 最終スキャン
FROM    sys.indexes AS i
JOIN    sys.dm_db_partition_stats AS ps
        ON  ps.object_id = i.object_id
        AND ps.index_id  = i.index_id
LEFT    JOIN sys.dm_db_index_usage_stats AS us
        ON  us.object_id   = i.object_id
        AND us.index_id    = i.index_id
        AND us.database_id = DB_ID()
WHERE   i.index_id > 1                        -- ヒープ(0)とクラスタ化(1)は対象外
  AND   i.is_primary_key = 0
  AND   i.is_unique_constraint = 0            -- 制約を支えるインデックスは消せない
  AND   OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP   BY i.object_id, i.name, i.type_desc,
          us.user_seeks, us.user_scans, us.user_lookups, us.user_updates,
          us.last_user_seek, us.last_user_scan
HAVING  ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
      + ISNULL(us.user_lookups, 0) = 0        -- 一度も読まれていない
ORDER   BY ISNULL(us.user_updates, 0) DESC;   -- 更新負荷が大きいものから
```

**読み取り 0・更新 100万回**のインデックスは、**書き込みを遅くしログを膨らませるだけの純粋な負債**です。

> ⚠️ **数字だけで DROP してはいけません。** 削除前に必ず確認すること:
> 1. **稼働時間は十分か**(1-3 節)。再起動直後の 0 は「使われていない」ではなく「まだ測っていない」。
> 2. **月次・年次バッチを1周分含んでいるか**。四半期処理だけで使うインデックスは、
>    3か月観測しないと使用実績が出ません。
> 3. **フェイルオーバー/AlwaysOn のセカンダリ**では別途カウントされます。プライマリの数字だけ見ていないか。
> 4. **制約(PK/UNIQUE)を支えていないか**。上のクエリで除外していますが、外部キー用も要注意。
> 5. まず **`DISABLE` してしばらく様子を見る**([`ALTER INDEX ... DISABLE`]、戻すのは `REBUILD`)。
>    `DROP` は定義を失うので、**必ず CREATE 文を控えてから**。

> ⚠️ SQL Server 2012 / 2014 には **`ALTER INDEX ... REBUILD` で `sys.dm_db_index_usage_stats` の行が
> 消えてしまう既知の動作**がありました(2016 以降は保持されます)。
> 再構築のメンテナンスジョブを回している環境では、**ジョブ直後の数字は当てになりません**。

補足として、`sys.dm_db_index_operational_stats`(DMF)は
**「使われたか」ではなく「使われた結果どれだけ待ったか」** を返します。

```sql
-- ロック待ち・IO待ちがどのインデックスで起きているか
SELECT  OBJECT_NAME(ios.object_id)      AS テーブル,
        i.name                          AS インデックス名,
        ios.row_lock_count              AS 行ロック取得数,
        ios.row_lock_wait_count         AS 行ロック待ち回数,
        ios.row_lock_wait_in_ms         AS 行ロック待ちms,
        ios.page_io_latch_wait_count    AS ページIO待ち回数,
        ios.page_io_latch_wait_in_ms    AS ページIO待ちms
FROM    sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'dbo.OrdersBig'), NULL, NULL) AS ios
JOIN    sys.indexes AS i
        ON  i.object_id = ios.object_id
        AND i.index_id  = ios.index_id;
```

### 4-3. `sys.dm_db_missing_index_*` — 欠落インデックスの「提案」

オプティマイザは、コンパイル中に「この列にインデックスがあれば安くなったのに」と思ったことを
記録しています。それが3つの DMV に分かれて入っています。

| DMV | 内容 | 結合キー |
|---|---|---|
| `sys.dm_db_missing_index_details` | **どの列**が欲しかったか(`equality_columns` / `inequality_columns` / `included_columns`) | `index_handle` |
| `sys.dm_db_missing_index_groups` | details とグループを結ぶ中間表 | `index_handle` / `index_group_handle` |
| `sys.dm_db_missing_index_group_stats` | **どれだけ効きそうか**(`avg_user_impact`, `avg_total_user_cost`, `user_seeks`) | `group_handle` |

```sql
-- 【定番⑮】欠落インデックスの提案を「効きそうな順」に並べる
SELECT TOP (20)
        -- 改善見込みスコア(広く使われている慣用式。絶対値に意味はなく順位付け用)
        CAST(gs.avg_total_user_cost * (gs.avg_user_impact / 100.0)
             * (gs.user_seeks + gs.user_scans) AS DECIMAL(18,2))  AS 改善見込みスコア,
        gs.user_seeks               AS シーク見込み回数,
        gs.user_scans               AS スキャン見込み回数,
        gs.avg_user_impact          AS 平均改善率パーセント,
        gs.avg_total_user_cost      AS 平均クエリコスト,
        gs.last_user_seek           AS 最終要求時刻,
        OBJECT_SCHEMA_NAME(d.object_id, d.database_id) + N'.'
      + OBJECT_NAME(d.object_id, d.database_id)                   AS 対象テーブル,
        d.equality_columns          AS 等値条件の列,
        d.inequality_columns        AS 範囲条件の列,
        d.included_columns          AS INCLUDE候補の列,
        d.statement                 AS 対象オブジェクト,
        -- ★あくまで「たたき台」。そのまま実行しないこと(下の警告を読むこと)
        N'CREATE NONCLUSTERED INDEX IX_要検討 ON '
          + d.statement + N' ('
          + ISNULL(d.equality_columns, N'')
          + CASE WHEN d.equality_columns IS NOT NULL
                  AND d.inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
          + ISNULL(d.inequality_columns, N'') + N')'
          + ISNULL(N' INCLUDE (' + d.included_columns + N')', N'') + N';'  AS 提案されたDDL草案
FROM    sys.dm_db_missing_index_group_stats AS gs
JOIN    sys.dm_db_missing_index_groups      AS g  ON g.index_group_handle = gs.group_handle
JOIN    sys.dm_db_missing_index_details     AS d  ON d.index_handle       = g.index_handle
WHERE   d.database_id = DB_ID(N'SalesLearning')
ORDER   BY 改善見込みスコア DESC;
```

#### ★★★ 最重要: 提案を鵜呑みにしてはいけない

> ⚠️ **これはこの章でいちばん大事な注意です。**
> SSMS の実行プランに出る緑色の「不足しているインデックス」も、上の DMV も、**中身は同じもの**です。
> **提案をそのままコピーして CREATE INDEX するのは、初心者がやる最悪の運用**です。

理由を1つずつ理解してください。

1. **個別クエリ単位の提案であって、ワークロード全体を見ていない**
   オプティマイザは「今コンパイルしているこの1本」しか考えていません。
   似たクエリが50本あっても、**50個の似て非なる提案**が出るだけです。
   本来なら **1本の複合インデックスで50本ともカバーできる**かもしれないのに、
   言われるままに作ると **50本のインデックスができます**。

2. **列の順序が最適とは限らない**
   `equality_columns` の並びは、**クエリに出てきた順序に近いだけ**で、
   選択度を考慮した最適順ではありません。
   [18 章 6 節](18_indexes_execution_plans.md) のとおり、**複合インデックスは列順序がすべて**です。
   `(CustomerId, OrderDate)` と `(OrderDate, CustomerId)` は別物で、どちらが正しいかは
   **自分のワークロードを見て決める**しかありません。

3. **`INCLUDE` が過剰になりがち**
   提案はそのクエリの `SELECT` に出た列を **全部 `INCLUDE` に並べます**。
   元のクエリが `SELECT *` なら、**テーブルをまるごと複製するインデックス**を提案してきます。
   正しい対処は、まず **`SELECT` の列を絞ること**です。

4. **既存インデックスとの重複を考慮しない**
   すでに `(OrderDate)` があるのに `(OrderDate) INCLUDE (Amount)` を提案してくる、
   といったことが平気で起きます。**本来は既存を作り直して統合すべき**場面です。

5. **更新コストを一切考慮していない**
   提案は「読み取りが何%速くなるか」しか語りません。
   そのインデックスが **INSERT/UPDATE/DELETE をどれだけ遅くするか**は誰も計算してくれません
   ([18 章 9 節](18_indexes_execution_plans.md))。

6. **`avg_user_impact` は「推定コストの改善率」であって実測ではない**
   99% と出ていても、元のコストが小さければ効果は誤差です。
   だから上のクエリでは **コスト × 影響率 × 回数** でスコア化して順位付けしています。

**正しい使い方**:

> **提案は「オプティマイザからの申告」であって「設計書」ではない。**
> 「この列でよく絞られているらしい」という **ヒント**として読み、
> **実際のインデックスは 18 章の知識で自分が設計する。**
> 設計したら **作成前後の論理読み取り数で効果を検証**し、**既存インデックスとの統合**を必ず検討する。

手順としてはこうです。

1. 提案をスコア順に眺め、**どのテーブルのどの列が繰り返し出てくるか**を見る(頻出パターンの発見)。
2. `d.statement` からクエリを特定し、**実際の SQL を読む**。`SELECT *` なら列を削る。
3. **既存インデックス一覧**を出し、統合できないか検討する。
4. 自分で列順序を決めて **1本だけ**作る。
5. `SET STATISTICS IO ON` で **前後を比較**する。改善しなければ **戻す**。

> ⚠️ `sys.dm_db_missing_index_*` は **そのテーブルにインデックス DDL を実行するとリセット**されます。
> つまり「1本作ったら、残りの提案は消える」ことがあります。**作る前に結果を保存**しておきましょう。

> ⚠️ 提案には **クラスタ化インデックス・列ストア・フィルター選択されたインデックスの提案は含まれません**。
> また、**最大 500 グループ**しか保持されません。

### 4-4. `sys.dm_db_index_physical_stats` — 断片化

```sql
-- 【定番⑯】断片化の確認(まずは軽い LIMITED で)
SELECT  OBJECT_NAME(ips.object_id)              AS テーブル,
        i.name                                  AS インデックス名,
        ips.index_type_desc                     AS 種別,
        ips.partition_number                    AS パーティション,
        ips.index_level                         AS レベル,       -- 0 = リーフ
        ips.page_count                          AS ページ数,
        CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS 断片化率,
        ips.avg_page_space_used_in_percent      AS ページ使用率, -- SAMPLED/DETAILED のみ
        ips.record_count                        AS 行数          -- SAMPLED/DETAILED のみ
FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.OrdersBig'), NULL, NULL, 'LIMITED') AS ips
JOIN    sys.indexes AS i
        ON  i.object_id = ips.object_id
        AND i.index_id  = ips.index_id
WHERE   ips.index_level = 0
ORDER   BY ips.avg_fragmentation_in_percent DESC;
```

**モードによってコストが桁違い**です。第5引数を必ず意識してください。

| モード | 読むもの | コスト | 取れる情報 |
|---|---|---|---|
| **`LIMITED`**(既定) | **リーフの1つ上のレベルだけ** | **最も軽い** | `avg_fragmentation_in_percent`, `page_count` |
| `SAMPLED` | リーフページの **約1%**(1万ページ未満なら DETAILED と同じ) | 中 | + `avg_page_space_used_in_percent`, `record_count` |
| `DETAILED` | **全ページ** | **重い(本番で長時間ブロックしうる)** | 全項目が最も正確 |

> ⚠️ `NULL` を渡すと **既定の `LIMITED`** ですが、**第2引数を `NULL` にすると DB 内の全オブジェクト**が対象になります。
> `DETAILED` × 全オブジェクトは **本番でやってはいけない組み合わせ**の代表です。
> 必ず `OBJECT_ID(...)` でテーブルを絞ってから使ってください。

判断の目安(**環境により調整すべき慣用値**):

| 断片化率 | 対処 |
|---|---|
| 〜5% | 何もしない |
| 5〜30% | `ALTER INDEX ... REORGANIZE`(オンライン・軽い・ログ少なめ) |
| 30%〜 | `ALTER INDEX ... REBUILD`(重い。Enterprise なら `WITH (ONLINE = ON)`) |

> ⚠️ **`page_count` が 1000 未満(約8MB未満)の小さいインデックスの断片化率は無視**してよいのが定石です。
> 数ページしかないものは、断片化率が 90% でも実害がありません。
> また、**SSD 環境では断片化の実害は HDD 時代よりずっと小さい**。
> 断片化対策より、**統計情報の更新**([27 章](27_statistics_cardinality.md))のほうが効くことがよくあります。

---

## 5. 【メモリと IO】

### 5-1. `sys.dm_os_performance_counters` — PLE と Buffer cache hit ratio

Windows のパフォーマンスモニターのカウンターを、**T-SQL から直接読めます**。

```sql
-- 【定番⑰】Page life expectancy(PLE)を取る
SELECT  RTRIM(object_name)      AS オブジェクト,
        RTRIM(counter_name)     AS カウンター,
        RTRIM(instance_name)    AS インスタンス,
        cntr_value              AS 値
FROM    sys.dm_os_performance_counters
WHERE   counter_name LIKE N'Page life expectancy%'
ORDER   BY object_name, instance_name;
```

> ⚠️ `object_name` は **固定長で右側に空白が入っています**。`= 'SQLServer:Buffer Manager'` で
> 一致しないのはこれが原因です。**`RTRIM` するか `LIKE '%Buffer Manager%'` を使う**こと。
> さらに **名前付きインスタンスでは `MSSQL$インスタンス名:Buffer Manager`** になります。
> `LIKE` で書いておくと環境に依存しません。

Buffer cache hit ratio は **比率カウンター**なので、**`base` とペアで計算**しないと意味のない生値が出ます。

```sql
-- 【定番⑱】Buffer cache hit ratio(base とペアで計算する)
SELECT  CAST(a.cntr_value * 100.0 / NULLIF(b.cntr_value, 0) AS DECIMAL(5,2)) AS バッファキャッシュヒット率
FROM    sys.dm_os_performance_counters AS a
JOIN    sys.dm_os_performance_counters AS b
        ON  RTRIM(a.object_name) = RTRIM(b.object_name)
WHERE   a.counter_name LIKE N'Buffer cache hit ratio%'
  AND   a.counter_name NOT LIKE N'%base%'
  AND   b.counter_name LIKE N'Buffer cache hit ratio base%'
  AND   a.object_name LIKE N'%Buffer Manager%';
```

#### ★ これらの指標を単独で信じてはいけない

> ⚠️ **`Buffer cache hit ratio` はほぼ役に立ちません。**
> SQL Server は **先読み(read-ahead)** でページを事前にバッファへ載せます。
> 先読みされたページは「ヒット」として数えられるため、
> **ディスクをガンガン読んでいる最中でも 99% 以上を示します**。
> 「99%だから健全」は **完全な誤読**です。この指標で判断するのはやめてください。

> ⚠️ **`Page life expectancy` の「300秒を切ったら危険」は 20年前の目安**です。
> 当時のメモリ容量(4GB)を前提にした値で、**数百GB のメモリを積んだ現代のサーバーには適用できません**。
> 正しい読み方は次のとおりです。
> - **絶対値ではなく推移で見る**。普段 20,000 なのに 500 に落ちた、という **変化**が情報。
> - **NUMA ノードごとに見る**。`SQLServer:Buffer Node` の PLE を `instance_name`(ノード)別に確認する。
>   `Buffer Manager` の値は全ノードの平均なので、**片方のノードだけ枯れていても平らに見えます**。
> - **PLE が落ちた = メモリ不足、ではない**。**巨大なスキャンが1本走ってバッファを洗い流した**だけかもしれません。
>   その場合の正しい対処は「メモリ増設」ではなく「**そのクエリにインデックスを貼る**」です。
> - つまり **PLE は「症状」であって「原因」ではない**。原因は 3 節の論理読み取り上位クエリにあります。

```sql
-- NUMA ノードごとの PLE(ノードが複数ある環境ではこちらを見る)
SELECT  RTRIM(instance_name) AS ノード,
        cntr_value           AS PLE秒
FROM    sys.dm_os_performance_counters
WHERE   object_name LIKE N'%Buffer Node%'
  AND   counter_name LIKE N'Page life expectancy%';
```

その他、よく使うカウンターの取り方:

```sql
-- 秒間カウンター(Batch Requests/sec など)は「累積値」なので差分を取る必要がある
SELECT  RTRIM(object_name) AS オブジェクト,
        RTRIM(counter_name) AS カウンター,
        cntr_value,
        cntr_type          -- 65792=瞬間値 / 272696576=累積(差分が必要) / 537003264=比率(base必要)
FROM    sys.dm_os_performance_counters
WHERE   counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec',
                         N'SQL Re-Compilations/sec', N'Lock Waits/sec')
  AND   (instance_name = N'' OR instance_name IS NULL OR instance_name = N'_Total');
```

> ⚠️ `cntr_type = 272696576` のカウンターは **`/sec` という名前でも中身は累積値**です。
> **2回取って差分 ÷ 経過秒**で初めて「毎秒の値」になります。1回だけ見て「毎秒◯回だ」と読むのは誤りです。

### 5-2. `sys.dm_io_virtual_file_stats` — どのファイルが遅いか

**「ディスクが遅い」を数字にする DMF** です。ファイル単位の **待ち時間(stall)** が取れます。

```sql
-- 【定番⑲】ファイル別の平均 IO 待ち時間(起動からの累積)
SELECT  DB_NAME(vfs.database_id)                        AS DB名,
        mf.name                                         AS 論理ファイル名,
        mf.type_desc                                    AS 種別,       -- ROWS(データ) / LOG
        vfs.num_of_reads                                AS 読み取り回数,
        vfs.num_of_writes                               AS 書き込み回数,
        vfs.io_stall_read_ms  / NULLIF(vfs.num_of_reads,  0) AS 平均読み取り待ちms,
        vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS 平均書き込み待ちms,
        vfs.num_of_bytes_read  / 1024 / 1024            AS 読み取りMB,
        vfs.num_of_bytes_written / 1024 / 1024          AS 書き込みMB,
        vfs.size_on_disk_bytes / 1024 / 1024            AS サイズMB,
        mf.physical_name                                AS 物理パス
FROM    sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN    sys.master_files AS mf
        ON  mf.database_id = vfs.database_id
        AND mf.file_id     = vfs.file_id
ORDER   BY 平均読み取り待ちms DESC;
```

判断の目安(**ストレージによって大きく変わる参考値**):

| 対象 | 望ましい平均待ち時間 |
|---|---|
| データファイル(`ROWS`)の読み取り | **10〜20ms 以下** |
| データファイルの書き込み | 10〜20ms 以下 |
| **ログファイル(`LOG`)の書き込み** | **5ms 以下**(ここが遅いと `WRITELOG` 待ちが爆発する) |
| tempdb | データファイルに準じる |

> ⚠️ **これは起動からの「平均」**です。**夜間バッチの3時間だけ 500ms だった**という事故は、
> 24時間の平均に薄まって見えなくなります。**今の状態が知りたいなら差分を取ってください。**

```sql
-- 【定番⑳】スナップショット差分で「今この30秒」の IO 待ちを測る
DROP TABLE IF EXISTS #vfs1;

SELECT database_id, file_id, num_of_reads, num_of_writes,
       io_stall_read_ms, io_stall_write_ms
INTO   #vfs1
FROM   sys.dm_io_virtual_file_stats(NULL, NULL);

WAITFOR DELAY '00:00:30';        -- この間に負荷(セクションA/B)を流しておく

SELECT  DB_NAME(v2.database_id)                     AS DB名,
        mf.name                                     AS 論理ファイル名,
        mf.type_desc                                AS 種別,
        v2.num_of_reads  - v1.num_of_reads          AS 期間内読み取り回数,
        v2.num_of_writes - v1.num_of_writes         AS 期間内書き込み回数,
        (v2.io_stall_read_ms  - v1.io_stall_read_ms)
            / NULLIF(v2.num_of_reads  - v1.num_of_reads,  0)  AS 平均読み取り待ちms,
        (v2.io_stall_write_ms - v1.io_stall_write_ms)
            / NULLIF(v2.num_of_writes - v1.num_of_writes, 0)  AS 平均書き込み待ちms
FROM    sys.dm_io_virtual_file_stats(NULL, NULL) AS v2
JOIN    #vfs1 AS v1
        ON  v1.database_id = v2.database_id
        AND v1.file_id     = v2.file_id
JOIN    sys.master_files AS mf
        ON  mf.database_id = v2.database_id
        AND mf.file_id     = v2.file_id
WHERE   v2.num_of_reads + v2.num_of_writes > v1.num_of_reads + v1.num_of_writes
ORDER   BY 平均読み取り待ちms DESC;

DROP TABLE IF EXISTS #vfs1;
```

**この「2回スナップショットを撮って差分を取る」手法は、累積型 DMV すべてに応用できます**
(`sys.dm_os_wait_stats`, `sys.dm_exec_query_stats`, `sys.dm_os_performance_counters` など)。
上級者の調査は、ほぼこの形です。

> ⚠️ **IO が遅い=ストレージが悪い、とは限りません。**
> インデックスが無くて100万行スキャンしていれば、どんなに速い SSD でも待ちは出ます。
> **まず 3 節で論理読み取り上位のクエリを直す**。ハードウェアの話はその後です。

### 5-3. `sys.dm_os_memory_clerks` — メモリを誰が使っているか

SQL Server のメモリは **「メモリクラーク」** という単位で管理されています。
「メモリが足りない」と言われたら、**どのクラークが食っているか**を見ます。

```sql
-- 【定番㉑】メモリ使用量の上位クラーク
SELECT TOP (15)
        mc.type                                       AS クラーク種別,
        SUM(mc.pages_kb) / 1024                       AS 使用MB,
        SUM(mc.virtual_memory_committed_kb) / 1024    AS 仮想メモリMB
FROM    sys.dm_os_memory_clerks AS mc
GROUP   BY mc.type
ORDER   BY SUM(mc.pages_kb) DESC;
```

代表的なクラークの読み方:

| `type` | 意味 | 大きいときに疑うこと |
|---|---|---|
| `MEMORYCLERK_SQLBUFFERPOOL` | **バッファプール**(データページ) | 正常。ここが最大なのが健全な状態 |
| `CACHESTORE_SQLCP` | **アドホック SQL のプラン** | **シングルユース プラン肥大化**(6-2 節) |
| `CACHESTORE_OBJCP` | プロシージャのプラン | 正常な範囲か確認 |
| `MEMORYCLERK_SQLQERESERVATIONS` | **クエリ実行用のメモリ許可** | ソート/ハッシュが大きすぎる(5-4 節) |
| `USERSTORE_TOKENPERM` | セキュリティトークン | 肥大化するとコンパイルが遅くなる既知の問題 |
| `MEMORYCLERK_XTP` | インメモリ OLTP | [32 章](32_in_memory_oltp.md) |

```sql
-- サーバー全体のメモリ状況
SELECT  physical_memory_kb / 1024              AS 物理メモリMB,
        committed_kb / 1024                    AS SQLServerコミット済みMB,
        committed_target_kb / 1024             AS 目標MB
FROM    sys.dm_os_sys_info;
```

- `committed_kb` が `committed_target_kb` を大きく下回り続けているなら、**メモリ圧迫**の可能性。
- `pages_kb` 列は **2012+**(それ以前は `single_pages_kb` / `multi_pages_kb`)。

### 5-4. `sys.dm_exec_query_memory_grants` — メモリ許可待ち

ソートやハッシュ結合は、実行前に **メモリの割り当て(memory grant)** を要求します。
**割り当てられるまでクエリは1行も処理を始められません**。

```sql
-- 【定番㉒】今、メモリ許可を待っている/使っているクエリ
SELECT  mg.session_id                                   AS セッション,
        mg.request_time                                 AS 要求時刻,
        mg.grant_time                                   AS 許可時刻,     -- NULL なら「まだ待っている」
        mg.requested_memory_kb / 1024                   AS 要求MB,
        mg.granted_memory_kb   / 1024                   AS 許可MB,
        mg.required_memory_kb  / 1024                   AS 最低必要MB,
        mg.used_memory_kb      / 1024                   AS 使用中MB,
        mg.max_used_memory_kb  / 1024                   AS 最大使用MB,
        mg.ideal_memory_kb     / 1024                   AS 理想MB,
        mg.wait_time_ms                                 AS 待機ms,
        mg.queue_id                                     AS 待ち行列,
        mg.dop                                          AS 並列度,
        mg.query_cost                                   AS 推定コスト,
        t.text                                          AS SQL本文
FROM    sys.dm_exec_query_memory_grants AS mg
OUTER   APPLY sys.dm_exec_sql_text(mg.sql_handle) AS t
ORDER   BY mg.requested_memory_kb DESC;
```

判断:

- **`grant_time IS NULL` の行がある** → メモリ許可待ち。待機タイプは **`RESOURCE_SEMAPHORE`** です
  ([23 待機統計](23_wait_statistics.md))。これが上位に来ていたらここを見ます。
- **`granted_memory_kb` >> `max_used_memory_kb`** → **取りすぎ**。
  推定行数が過大で、他のクエリのメモリを奪っています。原因は統計([27 章](27_statistics_cardinality.md))か、
  スニッフィング([28 章](28_parameter_sniffing.md))。
- **`granted` < `ideal`** → 許可が足りず **tempdb に溢れる(spill)** 可能性。
  実際のプランに「ハッシュ警告」「ソート警告」が出ます。
- **`dop` が大きい** → 並列度が高いほどメモリ許可も膨らみます([29 章](29_join_algorithms_parallelism.md))。

```sql
-- メモリ許可のリソースセマフォ(空きがどれだけあるか)
SELECT  resource_semaphore_id,
        target_memory_kb / 1024      AS 上限MB,
        total_memory_kb  / 1024      AS 総MB,
        available_memory_kb / 1024   AS 空きMB,
        granted_memory_kb / 1024     AS 許可済みMB,
        grantee_count                AS 許可中クエリ数,
        waiter_count                 AS 待機中クエリ数
FROM    sys.dm_exec_query_resource_semaphores;
```

`waiter_count` が慢性的に 0 でないなら、**メモリ不足かクエリのメモリ要求が過大**です。

---

## 6. 【プランキャッシュ】

### 6-1. `sys.dm_exec_cached_plans` と `usecounts`

```sql
-- 【定番㉓】キャッシュの内訳(種類別のプラン数とサイズ)
SELECT  cp.objtype                                       AS 種別,
        cp.cacheobjtype                                  AS キャッシュ種別,
        COUNT(*)                                         AS プラン数,
        SUM(CAST(cp.size_in_bytes AS BIGINT)) / 1024 / 1024 AS 合計MB,
        AVG(cp.usecounts)                                AS 平均使用回数
FROM    sys.dm_exec_cached_plans AS cp
GROUP   BY cp.objtype, cp.cacheobjtype
ORDER   BY 合計MB DESC;
```

`objtype` の主な値:

| 値 | 意味 |
|---|---|
| `Adhoc` | **パラメーター化されていない生の SQL**(要注意) |
| `Prepared` | `sp_executesql` 等でパラメーター化された SQL(健全) |
| `Proc` | ストアドプロシージャ |
| `Trigger` / `View` / `UsrTab` 等 | その他 |

- **`usecounts`** = そのプランが再利用された回数。**1 のままなら1回しか使われていない**。

### 6-2. シングルユース プランの肥大化を検出する

```sql
-- 【定番㉔】シングルユース(1回しか使われていない)アドホックプランの割合
SELECT  SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                 THEN 1 ELSE 0 END)                                AS シングルユース数,
        COUNT(*)                                                   AS 全プラン数,
        CAST(SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                      THEN CAST(cp.size_in_bytes AS BIGINT) ELSE 0 END)
             / 1024.0 / 1024.0 AS DECIMAL(10,1))                   AS シングルユースMB,
        CAST(SUM(CAST(cp.size_in_bytes AS BIGINT))
             / 1024.0 / 1024.0 AS DECIMAL(10,1))                   AS 全体MB,
        CAST(100.0 * SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                              THEN CAST(cp.size_in_bytes AS BIGINT) ELSE 0 END)
             / NULLIF(SUM(CAST(cp.size_in_bytes AS BIGINT)), 0) AS DECIMAL(5,1)) AS シングルユース比率
FROM    sys.dm_exec_cached_plans AS cp;
```

```sql
-- 実際にどんな SQL がゴミになっているか(先頭200文字で確認)
SELECT TOP (30)
        cp.usecounts        AS 使用回数,
        cp.size_in_bytes / 1024 AS サイズKB,
        cp.objtype          AS 種別,
        LEFT(t.text, 200)   AS SQL先頭
FROM    sys.dm_exec_cached_plans AS cp
CROSS   APPLY sys.dm_exec_sql_text(cp.plan_handle) AS t
WHERE   cp.objtype = N'Adhoc'
  AND   cp.usecounts = 1
ORDER   BY cp.size_in_bytes DESC;
```

**シングルユース比率が高い(目安として全体の 30% 以上、または数GB)** ときに起きること:

- プランキャッシュがメモリを食い、**バッファプール(データキャッシュ)を圧迫**する。
- 毎回コンパイルするので **CPU を消費**し、`SQL Compilations/sec` が高くなる。
- `sys.dm_exec_query_stats` が **同じクエリの断片で埋め尽くされ、調査しにくくなる**。

対処:

1. **アプリ側でパラメーター化する**(`sp_executesql` を使う。[20 動的SQL](20_dynamic_sql.md) 参照)。**これが本筋**。
2. サーバー構成 **`optimize for ad hoc workloads`** を有効にする。
   初回はプラン本体ではなく **小さなスタブだけ**をキャッシュし、2回目に本体を入れます。
   一般に **副作用が少なく効果が大きい**設定です。

```sql
-- 現在値を確認してから変更する(★元に戻す手順とセットで)
SELECT name, value_in_use FROM sys.configurations
WHERE name = N'optimize for ad hoc workloads';

-- 有効化
EXEC sp_configure 'show advanced options', 1;  RECONFIGURE;
EXEC sp_configure 'optimize for ad hoc workloads', 1;  RECONFIGURE;

-- ▼元に戻す(既定は 0)
-- EXEC sp_configure 'optimize for ad hoc workloads', 0;  RECONFIGURE;
```

3. データベースの `PARAMETERIZATION` を `FORCED` にする方法もありますが、
   **スニッフィングの影響を広げる副作用**があるため安易に使わないこと([28 章](28_parameter_sniffing.md))。

### 6-3. ★ プランキャッシュのクリアについて(安全上の最重要事項)

> ⚠️⚠️ **`DBCC FREEPROCCACHE` を本番環境で実行してはいけません。**
> このコマンドは **サーバー上のすべてのデータベースの、すべてのプランを捨てます**。
> 直後にサーバー上の **全クエリが同時に再コンパイル**され、CPU が跳ね上がり、
> **全ユーザーが一斉に遅くなります**。
> 「キャッシュをクリアすれば直る」という話をネットで見かけますが、
> それは **原因を消さずに症状を一時的に隠しているだけ**です。しかも代償が大きすぎます。
> 同じ理由で **`DBCC DROPCLEANBUFFERS`(バッファプールを空にする)も本番禁止**です
> ([18 章 1-3 節](18_indexes_execution_plans.md) と同じ方針)。

**学習環境で試すとき、そして本番でどうしても必要なときは、影響範囲を限定します。**

```sql
-- ① 特定のプラン1つだけを捨てる(最も影響が小さい。★これを既定にする)
--    plan_handle は sys.dm_exec_query_stats / sys.dm_exec_cached_plans から取る
-- DBCC FREEPROCCACHE (0x06000E00...);       -- ← 実際の plan_handle を指定

-- ② 特定のデータベースのプランだけ捨てる(SQL Server 2016+)
--    そのDBに限定されるので、サーバー全体よりずっと安全
-- ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;

-- ③ 特定オブジェクトを参照するプランだけ再コンパイル対象にする
--    次回実行時に作り直される。既存のプランは即座には捨てられない
-- EXEC sp_recompile N'dbo.OrdersBig';

-- ④ アドホックプランのキャッシュストアだけ捨てる
-- DBCC FREESYSTEMCACHE ('SQL Plans');

-- ⑤ そもそもキャッシュを汚さない・使わない(最も安全)
--    SELECT ... OPTION (RECOMPILE);
```

- 学習中に「同じクエリを何度も測りたいので毎回コンパイルさせたい」だけなら、
  **`OPTION (RECOMPILE)` で十分**です。キャッシュを消す必要はありません。
- ①の `plan_handle` 指定は、**スニッフィングで固まった1本のプランだけを剥がす**ときの実務的な手段です
  ([28 章](28_parameter_sniffing.md))。

```sql
-- ①で使う plan_handle を取り出す例
SELECT TOP (5)
        qs.plan_handle,
        qs.execution_count,
        qs.total_worker_time / 1000.0 AS CPU合計ms,
        LEFT(st.text, 200)            AS SQL先頭
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   st.text LIKE N'%OrdersBig%'
ORDER   BY qs.total_worker_time DESC;
```

---

## 7. 調査の進め方(この章の結論)

個々の DMV より、**順番のほうが大事**です。行き当たりばったりで DMV を叩いても答えは出ません。

```
  ① 待機統計で「何を待っているか」の当たりを付ける      → 23章
       sys.dm_os_wait_stats(全体傾向)
       sys.dm_os_waiting_tasks(今の瞬間)
              ↓  「CPU なのか、IO なのか、ロックなのか」を決める
  ② DMV で「具体的にどのクエリか」を特定する            → 26章(この章)
       今の障害      : sys.dm_exec_requests + sql_text + query_plan
       過去の重量級  : sys.dm_exec_query_stats(CPU / 論理読み取り / 実行回数)
       ブロッキング  : blocking_session_id の再帰CTE
              ↓  「犯人のクエリ1本」まで絞り込む
  ③ Query Store で履歴を確認する                        → 24章
       いつから遅い? プランが変わった? 前のプランは?
       DMV と違い、再起動やキャッシュ追い出しで消えない
              ↓  「いつ・何をきっかけに変わったか」を確定
  ④ 実行プランで原因を特定する                          → 18章
       Scan か Seek か / Key Lookup / 推定 vs 実際の乖離
       結合方式・並列度                                  → 29章
       統計情報                                          → 27章
              ↓
  ⑤ 直す → ①に戻って「本当に効いたか」を測り直す
```

**各段階での問い**:

| 段階 | 問い | 使うもの |
|---|---|---|
| ① | サーバーは何を待っている? | `dm_os_wait_stats` / `dm_os_waiting_tasks` |
| ② | それを引き起こしているクエリは? | `dm_exec_query_stats` / `dm_exec_requests` |
| ③ | それはいつからそうなのか? | Query Store |
| ④ | なぜそのクエリは遅いのか? | 実行プラン / 統計 / インデックス |
| ⑤ | 直したら本当に軽くなったか? | 論理読み取り数の前後比較 |

> ⚠️ **④から始めてはいけません。** 「とりあえずこのクエリのプランを見る」は、
> **そのクエリが本当にボトルネックである保証がない**まま時間を溶かす典型的な失敗です。
> **必ず①②で「サーバー全体から見て重いのはこれ」を確定してから**プランを開いてください。

> ⚠️ そして **⑤を飛ばさないこと**。DMV の数字は改善前後で比較して初めて意味を持ちます。
> 改善前に **上位クエリの一覧を一時テーブルに保存**しておくと、後から差分が取れます。

```sql
-- 改善前のスナップショットを取っておく(#ではなく実テーブルにすれば再起動をまたげる)
DROP TABLE IF EXISTS #before;

SELECT  qs.query_hash,
        qs.execution_count,
        qs.total_worker_time,
        qs.total_logical_reads,
        CAST(SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS NVARCHAR(400)) AS ステートメント,
        SYSDATETIME() AS 取得時刻
INTO    #before
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st;
```

---

## よくあるつまずき

- **DMV の数字を「いつからの集計か」を確認せずに読む** → まず `sys.dm_os_sys_info.sqlserver_start_time`(1-3 節)。
- **`sys.dm_exec_requests` に探しているクエリが出てこない** → そこには **実行中のものしか出ません**。
  過去のものは `sys.dm_exec_query_stats`、さらに古いものは Query Store。
- **ブロック元の SQL が空欄になる** → ブロック元は `sleeping` で **リクエストが存在しない**。
  `sys.dm_exec_connections.most_recent_sql_handle` か `sys.dm_exec_input_buffer`(2016 SP1+)を使う(2-3 節)。
- **`CROSS APPLY` で行が消える** → `sql_handle` / `plan_handle` が NULL の行。**`OUTER APPLY` にする**。
- **`sys.dm_exec_sql_text` がプロシージャ本体を丸ごと返して読めない** → `statement_start_offset` /
  `statement_end_offset` で切り出す(3-2 節)。**`/2 + 1` と `-1 → DATALENGTH` を忘れない**。
- **時間の単位を1000倍間違える** → `total_worker_time` などは **マイクロ秒**。
- **`sys.dm_db_index_usage_stats` を `INNER JOIN` して未使用インデックスを見逃す**
  → **使われていないインデックスは行そのものが無い**。`LEFT JOIN` 必須(4-1 節)。
- **欠落インデックスの提案をコピペで CREATE する** → **この章最大の禁じ手**(4-3 節)。
  ヒントとして読み、自分で設計する。
- **`sys.dm_db_index_physical_stats` を `DETAILED` × 全オブジェクトで本番実行** → 長時間の高負荷(4-4 節)。
- **Buffer cache hit ratio 99% を見て「メモリは足りている」と判断** → 先読みで常に高く出る。ほぼ無意味(5-1 節)。
- **PLE 300秒の目安をそのまま使う** → 20年前のメモリ容量前提。**推移と NUMA ノード別**で見る(5-1 節)。
- **`object_name = 'SQLServer:Buffer Manager'` が一致しない** → 右側に空白。`RTRIM` か `LIKE`(5-1 節)。
- **`/sec` カウンターの生値を毎秒の値だと思う** → 累積値。**2回取って差分**(5-1 節)。
- **`DBCC FREEPROCCACHE` を本番で実行** → サーバー全体が一斉に再コンパイル。**絶対禁止**(6-3 節)。
- **プランを見ることから調査を始める** → ①待機統計 → ②DMV の順で **対象を確定してから**(7 節)。

## この章のまとめ

- DMV/DMF は **内部状態のスナップショット**。`dm_exec_*` / `dm_os_*` / `dm_db_*` / `dm_tran_*` / `dm_io_*`
  でレイヤが分かれる。DMF は引数が要るので **`OUTER APPLY`** で使う。
- **数値の大半は累積で、再起動やプラン追い出しでリセットされる**。
  **調査の1本目は `sqlserver_start_time` の確認**。履歴が要るなら **Query Store**。
- **今**を見るなら `sys.dm_exec_requests` + `sys.dm_exec_sessions` + `sys.dm_exec_sql_text`。
  プランは `sys.dm_exec_query_plan`(XML)/ `sys.dm_exec_text_query_plan`(offset 指定可)。
- **ブロッキングは `blocking_session_id` を再帰CTEで辿り、先頭ブロッカーを特定**する。
  ブロック元は `sleeping` で SQL が取れないことが多いので `most_recent_sql_handle` を使う。
- **過去**を見るなら `sys.dm_exec_query_stats` が中核。
  **CPU 上位 / 論理読み取り上位 / 実行回数上位**の3本を持ち歩く。
  **`statement_start_offset` / `statement_end_offset` での切り出しは必修イディオム**。
  **合計はサーバーを軽くするため、平均は画面を速くするため**に見る。
- インデックスは `sys.dm_db_index_usage_stats` で **読み取り 0・更新だけ**のものを探す(`LEFT JOIN` 必須)。
- **`sys.dm_db_missing_index_*` の提案は鵜呑みにしない**。個別クエリ視点・列順序が最適でない・
  `INCLUDE` 過剰・既存との重複を見ない・更新コストを見ない。**ヒントとして読み、18 章の知識で自分で設計する**。
- `sys.dm_db_index_physical_stats` は **`LIMITED` / `SAMPLED` / `DETAILED` でコストが桁違い**。
- **PLE と Buffer cache hit ratio は単独で信じない**。症状であって原因ではない。
  `sys.dm_io_virtual_file_stats` は **2回スナップショットして差分**を取る。
- プランキャッシュは `usecounts` で **シングルユース肥大化**を検出。対処は
  **パラメーター化**と `optimize for ad hoc workloads`。
- **`DBCC FREEPROCCACHE` は本番厳禁**。必要なら **plan_handle 指定 /
  `ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE`(2016+)/ `sp_recompile`** で範囲を限定する。
- **調査の順番: ①待機統計(23章) → ②DMV(26章) → ③Query Store(24章) → ④実行プラン(18章) → ⑤測り直す**。
  プランから始めない。効果は必ず数字で確認する。

➡ 演習: [exercises/26_dmv_investigation.md](../exercises/26_dmv_investigation.md)
