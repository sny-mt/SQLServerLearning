/* ============================================================
   解答例 26 — DMV による調査
   対象演習: exercises/26_dmv_investigation.md

   ★実行前の確認
     - sample-db/03_bulk_data.sql  (dbo.OrdersBig 100万行) 実行済み
     - sample-db/05_workload.sql   の【準備】セクション実行済み
     - SSMS のウィンドウを4つ開き、W1/W2=セクションA、W3=セクションB or C、
       W4=このファイル(観測用)という役割分担にしておくこと

   ★このファイルは W4(観測用ウィンドウ)で実行する想定です。
     負荷が流れていない状態で Q2/Q9/Q10/Q11 を実行しても「0行」になります。
     それは失敗ではなく「今は何も起きていない」という正しい観測結果です。

   ★安全方針
     - DBCC FREEPROCCACHE(引数なし)は使いません。
     - サーバー構成は変更しません(Q15 の解説で触れる箇所も既定ではコメントアウト)。
     - 作成したインデックスは Q18 ですべて削除します。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. サーバー起動時刻と稼働時間。DMV を読む前の「作法」。
SELECT  si.sqlserver_start_time                                    AS 起動時刻,
        DATEDIFF(HOUR,   si.sqlserver_start_time, SYSDATETIME())   AS 稼働時間_時,
        DATEDIFF(MINUTE, si.sqlserver_start_time, SYSDATETIME())   AS 稼働時間_分,
        si.cpu_count                                               AS 論理CPU数,
        si.physical_memory_kb / 1024                               AS 物理メモリMB
FROM    sys.dm_os_sys_info AS si;

/* Q1 の説明:
   DMV の数値の大半は「累積値」であり、基準時刻を知らないと大小の判断ができない。

   ・sys.dm_exec_query_stats
       プランがキャッシュに載っている間だけの集計。サーバー再起動、メモリ圧迫による
       プランの追い出し、再コンパイル、DBCC FREEPROCCACHE でリセットされる。
       → 起動30分後に「CPU 合計上位」を見ても、その30分の話でしかない。
       → 逆に半年動きっぱなしなら、去年終わったバッチの残骸が上位に居座ることがある。
       → 各行の creation_time も併せて確認するのが正しい読み方。

   ・sys.dm_db_index_usage_stats
       サーバー再起動でリセットされる(DB のデタッチ/オフラインでもその DB 分が消える)。
       → 再起動直後の「読み取り 0」は「使われていない」ではなく「まだ測っていない」。
       → 月次・四半期バッチでしか使われないインデックスは、その周期を1周
         観測しないと使用実績が現れない。

   リセットされない履歴が欲しい場合は Query Store(24章)を使うこと。 */


-- Q2. 今実行中のユーザーリクエスト一覧
--     ※ W1/W2 でセクションA を流している状態で実行すること
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
        -- 実行中のステートメントだけを切り出す(Q6 と同じイディオム)
        SUBSTRING(t.text,
                  (r.statement_start_offset / 2) + 1,
                  ((CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(t.text)
                        ELSE r.statement_end_offset
                    END - r.statement_start_offset) / 2) + 1)   AS 実行中ステートメント,
        t.text                                        AS バッチ全体
FROM    sys.dm_exec_requests AS r
JOIN    sys.dm_exec_sessions AS s
        ON  s.session_id = r.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t   -- ★CROSS ではなく OUTER
WHERE   s.is_user_process = 1        -- システムセッションを除外
  AND   r.session_id <> @@SPID       -- 自分自身を除外
ORDER   BY r.total_elapsed_time DESC;

/* Q2 のポイント:
   ・sql_handle が NULL の行があるため OUTER APPLY を既定にする。
     CROSS APPLY だと「探していた行」が黙って消えることがある。
   ・status の読み分け
       running   : いま CPU で実行中
       runnable  : CPU の順番待ち  → 大量にあれば CPU 不足を疑う(SOS_SCHEDULER_YIELD)
       suspended : 何かを待っている → wait_type を見る
   ・percent_complete は BACKUP / RESTORE / DBCC / インデックス再構築などでしか埋まらない。
   ・dm_exec_sessions.cpu_time は「接続してからの累計」、
     dm_exec_requests.cpu_time は「今のリクエスト分」。別物なので混同しないこと。 */


-- Q3. 実行中クエリのプランを取得(2通り)
-- (a) sys.dm_exec_query_plan … XML 型。SSMS でクリックするとグラフィカルプランで開く
SELECT  r.session_id        AS セッション,
        r.status            AS 状態,
        r.wait_type         AS 待機タイプ,
        r.total_elapsed_time AS 経過ms,
        t.text              AS SQL本文,
        p.query_plan        AS 実行プランXML
FROM    sys.dm_exec_requests AS r
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle)    AS t
OUTER   APPLY sys.dm_exec_query_plan(r.plan_handle) AS p
WHERE   r.session_id <> @@SPID
  AND   r.session_id > 50;

-- (b) sys.dm_exec_text_query_plan … NVARCHAR(MAX)。offset を渡せばステートメント単位
SELECT  r.session_id        AS セッション,
        p.query_plan        AS 実行プランテキスト
FROM    sys.dm_exec_requests AS r
OUTER   APPLY sys.dm_exec_text_query_plan(r.plan_handle,
                                          r.statement_start_offset,
                                          r.statement_end_offset) AS p
WHERE   r.session_id <> @@SPID
  AND   r.session_id > 50;

/* Q3 の説明:
                          dm_exec_query_plan       dm_exec_text_query_plan
     戻り型                XML                      NVARCHAR(MAX)
     SSMS でクリック       ○(プランが開く)         ✗(保存して .sqlplan にする)
     128 ネスト制限        あり(超えると NULL)     なし
     ステートメント指定    不可(バッチ全体)        可(offset を渡す)

   使い分け:
     ・普段は (a)。クリックしてすぐ見られるので速い。
     ・(a) が NULL を返す(深い入れ子ビュー・巨大な UNION ALL)ときは (b)。
     ・長大なプロシージャの「この1文だけ」が欲しいときも (b)。
   共通の注意: ここで取れるのはコンパイル時の情報(推定プラン相当)であり、
   実際の行数は含まれない。実行中の実測が欲しければ
   sys.dm_exec_query_profiles(2014+、2016+ の軽量プロファイリング)を使う。 */


-- Q4. dbo.OrdersBig のインデックス使用状況
SELECT  i.name                                          AS インデックス名,
        i.index_id                                      AS インデックスID,
        i.type_desc                                     AS 種別,
        ISNULL(us.user_seeks,   0)                      AS シーク,
        ISNULL(us.user_scans,   0)                      AS スキャン,
        ISNULL(us.user_lookups, 0)                      AS ルックアップ,
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
              + ISNULL(us.user_lookups, 0)              AS 読み取り合計,
        ISNULL(us.user_updates, 0)                      AS 更新,
        us.last_user_seek                               AS 最終シーク,
        us.last_user_scan                               AS 最終スキャン,
        us.last_user_lookup                             AS 最終ルックアップ,
        us.last_user_update                             AS 最終更新
FROM    sys.indexes AS i
LEFT    JOIN sys.dm_db_index_usage_stats AS us          -- ★LEFT JOIN でなければならない
        ON  us.object_id   = i.object_id
        AND us.index_id    = i.index_id
        AND us.database_id = DB_ID()
WHERE   i.object_id = OBJECT_ID(N'dbo.OrdersBig')
  AND   i.index_id > 0                                  -- ヒープ(0)は除外
ORDER   BY 読み取り合計 DESC;

/* Q4 の答え:
   INNER JOIN にしてはいけない理由 —
   sys.dm_db_index_usage_stats は「一度でも使われたインデックス」の行しか持たない。
   一度も使われていないインデックスは、そもそも行が存在しない。
   INNER JOIN で書くと、いちばん探したかった「未使用インデックス」が
   結果から消えてしまう。これは頻出のミス。
   ISNULL(...,0) を併用して、NULL を 0 として読めるようにしておくと扱いやすい。 */


-- Q5. CPU 合計時間の上位10クエリ(まずは素朴な形。Q6 で改良する)
SELECT TOP (10)
        qs.execution_count                                  AS 実行回数,
        qs.total_worker_time / 1000.0                       AS CPU合計ms,
        qs.total_worker_time / qs.execution_count / 1000.0  AS CPU平均ms,
        qs.total_elapsed_time / qs.execution_count / 1000.0 AS 経過平均ms,
        qs.total_logical_reads                              AS 論理読み取り合計,
        qs.creation_time                                    AS プラン作成時刻,
        qs.last_execution_time                              AS 最終実行時刻,
        st.text                                             AS バッチ全体  -- ← ここが問題(Q6)
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER   BY qs.total_worker_time DESC;

/* Q5 の注意:
   total_worker_time / total_elapsed_time の単位は「マイクロ秒」。
   /1000.0 でミリ秒に直さないと1000倍読み違える。
   また、CPU 合計と経過合計を比べると方向性が分かる:
     経過 >> CPU  … 待たされている(IO / ロック / 並列待ち)→ 23章へ
     経過 ≒ CPU   … 純粋に CPU を焼いている → プラン・インデックスを見る */


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q6. statement offset で「該当ステートメントだけ」を切り出す(必修イディオム)
SELECT TOP (10)
        qs.execution_count                                  AS 実行回数,
        qs.total_worker_time / 1000.0                       AS CPU合計ms,
        qs.total_worker_time / qs.execution_count / 1000.0  AS CPU平均ms,
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
ORDER   BY qs.total_worker_time DESC;

/* Q6 の答え:
   1) なぜ 2 で割るのか
      statement_start_offset / statement_end_offset は「バイト単位」のオフセット。
      text は nvarchar(1文字 = 2バイト)なので、SUBSTRING に渡す「文字位置」に
      直すには 2 で割る必要がある。さらに SUBSTRING は 1 始まりなので +1 する。

   2) statement_end_offset = -1 の意味
      「そのバッチの最後まで」を表す番兵値。そのまま引き算すると負の長さになるので、
      CASE で DATALENGTH(st.text) に置き換える。

   3) なぜ LEN ではなく DATALENGTH か
      LEN は「文字数」、DATALENGTH は「バイト数」を返す。
      オフセットがバイト単位なので、バイト長である DATALENGTH と揃えないとズレる。
      (加えて LEN は末尾の半角スペースを数えないという差もある) */


-- Q7-1. 論理読み取り合計 上位10(インデックス設計で改善できる可能性が最も高い候補)
SELECT TOP (10)
        qs.total_logical_reads                              AS 論理読み取り合計,
        qs.total_logical_reads / qs.execution_count         AS 論理読み取り平均,
        qs.execution_count                                  AS 実行回数,
        qs.total_worker_time / 1000.0                       AS CPU合計ms,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER   BY qs.total_logical_reads DESC;

-- Q7-2. 実行回数 上位10(1回は軽くても回数で効いてくるもの)
SELECT TOP (10)
        qs.execution_count                                  AS 実行回数,
        qs.total_worker_time / qs.execution_count / 1000.0  AS CPU平均ms,
        qs.total_worker_time / 1000.0                       AS CPU合計ms,
        qs.total_logical_reads / qs.execution_count         AS 論理読み取り平均,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER   BY qs.execution_count DESC;

-- Q7-3. 1回あたりの平均論理読み取り 上位10(実行回数5回以上に限定)
SELECT TOP (10)
        qs.total_logical_reads / qs.execution_count         AS 論理読み取り平均,
        qs.total_logical_reads                              AS 論理読み取り合計,
        qs.execution_count                                  AS 実行回数,
        qs.total_elapsed_time / qs.execution_count / 1000.0 AS 経過平均ms,
        SUBSTRING(st.text,
                  (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                    END - qs.statement_start_offset) / 2) + 1) AS ステートメント
FROM    sys.dm_exec_query_stats AS qs
CROSS   APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   qs.execution_count >= 5
ORDER   BY qs.total_logical_reads / qs.execution_count DESC;

/* Q7 の答え(合計か平均か):

   合計(total_*)で見るべきとき = 「サーバー全体を軽くしたい」
     サーバーのリソースを実際に食っている量そのもの。
     ここを削れば、CPU・IO・バッファプールの取り合いが全体的に緩む。
     容量計画・全体最適の話はこちら。

   平均(total_* / execution_count)で見るべきとき = 「あの画面が遅い」
     ユーザーの体感に直結するのは1回あたりの重さ。
     合計順で20位にも入らないクエリが、1回30秒かかっていて苦情の原因、はよくある。

   顔ぶれが変わる理由:
     合計上位には「1回0.5ms × 500万回」のような軽量高頻度クエリが並びやすい。
     平均上位には「1回8秒 × 6回」のような重量低頻度クエリが並ぶ。
     この2つは直し方がまったく違う。
       前者 → アプリの呼び出し方(ループ内発行・N+1・キャッシュ漏れ)を直す
       後者 → SQL とインデックスを直す

   さらに max_worker_time / 平均 の比を見ると、
   「同じプランなのに速いときと遅いときがある」= パラメーター スニッフィング(28章)を検知できる。 */

-- (補足) スニッフィング検知用: 最大と平均のブレ
SELECT TOP (10)
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


-- Q8. query_hash で集約して「実質同じクエリ」の合計負荷を見る
SELECT TOP (20)
        qs.query_hash,
        COUNT(*)                                AS プラン数,
        SUM(qs.execution_count)                 AS 実行回数合計,
        SUM(qs.total_worker_time) / 1000.0      AS CPU合計ms,
        SUM(qs.total_logical_reads)             AS 論理読み取り合計,
        SUM(CAST(qs.size_in_bytes AS BIGINT))   AS ダミー_使わない          -- ※存在しない列なので下で除去
FROM    sys.dm_exec_query_stats AS qs
GROUP   BY qs.query_hash
ORDER   BY SUM(qs.total_worker_time) DESC;
GO

-- ↑ の SUM(size_in_bytes) は sys.dm_exec_query_stats に存在しない列。正しくはこちら:
SELECT TOP (20)
        qs.query_hash,
        COUNT(*)                                AS プラン数,     -- ★多いとパラメーター化されていない
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

/* Q8 の答え:
   query_hash は「リテラルを取り除いたクエリの形」に対するハッシュ。
   WHERE CustomerId = 1 と = 2 は、テキストは違うが query_hash は同じになる。

   プラン数が多い(数十〜数百)ことが意味するもの:
     ・そのクエリが パラメーター化されていない(アドホックSQL)。
     ・リテラルごとに別プランがキャッシュされ、プランキャッシュを圧迫している(6-2 節)。
     ・毎回コンパイルされるので CPU も無駄に使っている。
     ・1本ずつ見ると負荷が小さく見えるため、個別ランキングでは見落とす。
       だから query_hash で集約して初めて「本当の重量級」が見える。
   対処: アプリ側で sp_executesql によるパラメーター化(20章)、
         サーバー構成 optimize for ad hoc workloads。 */


-- Q9. ブロッキングの観測
--     手順: W3 でセクションC(30秒ロック保持)→ すぐ W1 でセクションD → ここを実行
SELECT  r.session_id            AS 被害者セッション,
        r.blocking_session_id   AS ブロック元セッション,
        r.status                AS 状態,
        r.wait_type             AS 待機タイプ,      -- LCK_M_S などになるはず
        r.wait_time             AS 待機ms,
        r.wait_resource         AS 待機リソース,
        sv.login_name           AS 被害者ログイン,
        sv.program_name         AS 被害者アプリ,
        tv.text                 AS 被害者のSQL,
        sb.status               AS ブロック元の状態,  -- sleeping になっていることが多い
        sb.login_name           AS ブロック元ログイン,
        sb.host_name            AS ブロック元ホスト,
        sb.program_name         AS ブロック元アプリ,
        sb.last_request_start_time AS ブロック元の直近開始,
        tb.text                 AS ブロック元のSQL     -- ★most_recent_sql_handle から取る
FROM    sys.dm_exec_requests AS r
JOIN    sys.dm_exec_sessions AS sv ON sv.session_id = r.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS tv
LEFT    JOIN sys.dm_exec_sessions    AS sb ON sb.session_id = r.blocking_session_id
LEFT    JOIN sys.dm_exec_connections AS cb ON cb.session_id = r.blocking_session_id
OUTER   APPLY sys.dm_exec_sql_text(cb.most_recent_sql_handle) AS tb
WHERE   r.blocking_session_id <> 0
  AND   r.blocking_session_id <> r.session_id;   -- 並列内の自己待機は除外

-- (参考) 2016 SP1+ なら入力バッファからも取れる(DBCC INPUTBUFFER の DMF 版)
-- SELECT * FROM sys.dm_exec_input_buffer(<ブロック元のsession_id>, NULL);

-- (参考) 今どんなロックが保持されているか
SELECT  l.request_session_id      AS セッション,
        l.resource_type           AS リソース種別,
        l.request_mode            AS ロックモード,
        l.request_status          AS 状態,          -- GRANT / WAIT / CONVERT
        DB_NAME(l.resource_database_id) AS DB,
        OBJECT_NAME(p.object_id)  AS オブジェクト
FROM    sys.dm_tran_locks AS l
LEFT    JOIN sys.partitions AS p
        ON  p.hobt_id = l.resource_associated_entity_id
WHERE   l.request_session_id <> @@SPID
  AND   l.resource_type <> 'DATABASE'
ORDER   BY l.request_session_id, l.request_status DESC;

/* Q9 の答え:
   なぜブロック元の SQL が sys.dm_exec_requests から取れないのか —
     ブロック元(セクションC)は UPDATE を実行し終えて WAITFOR DELAY で待っており、
     トランザクションを開いたままアプリからの次の命令を待っている状態。
     つまり「実行中のリクエストが存在しない」= sys.dm_exec_requests に行が無い。
     status は sleeping、command は AWAITING COMMAND になる。
     現場でいちばん多いブロッキングの正体である
     「BEGIN TRAN したまま COMMIT を忘れているアプリ」も、まったく同じ形で現れる。

   回避方法(2つ):
     ① sys.dm_exec_connections.most_recent_sql_handle を
        sys.dm_exec_sql_text に渡す(上のクエリの方法)。
        そのセッションが最後に実行した SQL が取れる。
     ② sys.dm_exec_input_buffer(session_id, NULL)(SQL Server 2016 SP1+)。
        DBCC INPUTBUFFER の後継で、結合して使える。

   これを知らないと「犯人の SQL 欄だけ空白」で調査が止まる。 */


-- Q10. sys.dm_os_waiting_tasks(タスク単位の待機)
SELECT  wt.session_id                 AS セッション,
        wt.exec_context_id            AS 実行コンテキスト,   -- 0 以外 = 並列の子スレッド
        wt.wait_type                  AS 待機タイプ,
        wt.wait_duration_ms           AS 待機ms,
        wt.blocking_session_id        AS ブロック元セッション,
        wt.blocking_exec_context_id   AS ブロック元コンテキスト,
        wt.resource_description       AS リソース詳細,
        s.login_name                  AS ログイン,
        s.program_name                AS アプリ,
        s.status                      AS セッション状態,
        t.text                        AS SQL本文
FROM    sys.dm_os_waiting_tasks AS wt
JOIN    sys.dm_exec_sessions    AS s ON s.session_id = wt.session_id
LEFT    JOIN sys.dm_exec_requests AS r ON r.session_id = wt.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   s.is_user_process = 1
  AND   wt.session_id <> @@SPID
ORDER   BY wt.wait_duration_ms DESC;

/* Q10 の答え:
   sys.dm_exec_requests との違い:
     ・dm_exec_requests は「リクエスト単位」で1行。
       並列クエリでも1行にまとまり、代表的な wait_type しか見えない。
     ・dm_os_waiting_tasks は「タスク(ワーカースレッド)単位」で1行。
       並列クエリは DOP の数だけ行が出る(exec_context_id が 1,2,3...)。
       → CXPACKET / CXCONSUMER のような並列内部の待機はこちらでしか正しく見えない(29章)。
     ・blocking_exec_context_id まで見えるので、
       「どの子スレッドが誰を待っているか」まで分かる。

   sys.dm_os_wait_stats との使い分け:
     ・dm_os_wait_stats = サーバー起動からの「累積」。誰が待ったかは分からない。
       → 傾向をつかむ・当たりを付ける段階で使う(23章)。DBCC SQLPERF でリセット可能。
     ・dm_os_waiting_tasks = 「今この瞬間」のスナップショット。セッションが特定できる。
       → 進行中の障害で犯人を捕まえる段階で使う。
     つまり「まず wait_stats で方向を決め、waiting_tasks で現行犯を押さえる」。

   注意: blocking_session_id が自分自身と同じ行は、並列タスク同士の待ち合わせであって
   ブロッキングではない。除外して読むこと。 */


-- Q11. 再帰CTE でブロッキングチェーンの先頭ブロッカーを特定する
WITH Waiting AS
(
    -- ブロックされているセッション
    SELECT  r.session_id,
            r.blocking_session_id,
            r.wait_type,
            r.wait_time,
            r.wait_resource
    FROM    sys.dm_exec_requests AS r
    WHERE   r.blocking_session_id <> 0
      AND   r.blocking_session_id <> r.session_id   -- 並列内の自己待機を除外
),
Head AS
(
    -- 先頭ブロッカー = 誰かをブロックしているが、自分は誰にもブロックされていない
    SELECT DISTINCT w.blocking_session_id AS session_id
    FROM   Waiting AS w
    WHERE  NOT EXISTS (SELECT 1
                       FROM   Waiting AS w2
                       WHERE  w2.session_id = w.blocking_session_id)
),
Chain AS
(
    -- アンカー: レベル0 = 先頭ブロッカー
    SELECT  h.session_id,
            CAST(NULL AS INT)                                          AS blocking_session_id,
            0                                                          AS レベル,
            CAST(N'' AS NVARCHAR(60))                                  AS 待機タイプ,
            0                                                          AS 待機ms,
            CAST(CAST(h.session_id AS NVARCHAR(10)) AS NVARCHAR(400))  AS 連鎖
    FROM    Head AS h

    UNION ALL

    -- 再帰: そのセッションにブロックされている子を辿る
    SELECT  w.session_id,
            w.blocking_session_id,
            c.レベル + 1,
            CAST(w.wait_type AS NVARCHAR(60)),
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
        s.last_request_end_time     AS 直近リクエスト終了,
        ISNULL(t1.text, t2.text)    AS SQL本文
FROM    Chain AS c
JOIN    sys.dm_exec_sessions AS s ON s.session_id = c.session_id
LEFT    JOIN sys.dm_exec_requests    AS r  ON r.session_id  = c.session_id
LEFT    JOIN sys.dm_exec_connections AS cn ON cn.session_id = c.session_id
OUTER   APPLY sys.dm_exec_sql_text(r.sql_handle)              AS t1
OUTER   APPLY sys.dm_exec_sql_text(cn.most_recent_sql_handle) AS t2
ORDER   BY c.連鎖
OPTION (MAXRECURSION 100);      -- ★無限再帰への保険

/* Q11 のポイント:
   ・アンカーの決め方が肝。「ブロックしている集合」から「ブロックされている集合」を
     引いた差が先頭ブロッカー。NOT EXISTS で表現している。
   ・レベル0 の行が犯人候補。ここを解消すれば下流が一斉に動き出す。
   ・レベル0 が status='sleeping' なら、アプリのトランザクション閉じ忘れがほぼ確定。
     program_name と host_name で、どのアプリのどのマシンかまで分かる。
   ・SQL 本文は「実行中(t1)」を優先し、無ければ「最後に実行したもの(t2)」で補う。
   ・MAXRECURSION は必須。通常ブロッキングの循環はデッドロック検出で自動解消されるが、
     観測タイミング次第で循環に見えることがあり、その場合の暴走を防ぐ。
   ・犯人が分かっても KILL は最後の手段。ロールバックに実行時間以上かかることがあり、
     その間さらにブロックが延びる。まずアプリ側の停止を検討する。 */


-- Q12-1. 累積値からのファイル別 IO 待ち時間
SELECT  DB_NAME(vfs.database_id)                             AS DB名,
        mf.name                                              AS 論理ファイル名,
        mf.type_desc                                         AS 種別,
        vfs.num_of_reads                                     AS 読み取り回数,
        vfs.num_of_writes                                    AS 書き込み回数,
        vfs.io_stall_read_ms  / NULLIF(vfs.num_of_reads,  0) AS 平均読み取り待ちms,
        vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS 平均書き込み待ちms,
        vfs.num_of_bytes_read    / 1024 / 1024               AS 読み取りMB,
        vfs.num_of_bytes_written / 1024 / 1024               AS 書き込みMB,
        vfs.size_on_disk_bytes   / 1024 / 1024               AS サイズMB,
        mf.physical_name                                     AS 物理パス
FROM    sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN    sys.master_files AS mf
        ON  mf.database_id = vfs.database_id
        AND mf.file_id     = vfs.file_id
ORDER   BY 平均読み取り待ちms DESC;

-- Q12-2. 30秒スナップショット差分(この30秒の間に W1/W3 で負荷を流しておくこと)
DROP TABLE IF EXISTS #vfs1;

SELECT  database_id, file_id, num_of_reads, num_of_writes,
        io_stall_read_ms, io_stall_write_ms
INTO    #vfs1
FROM    sys.dm_io_virtual_file_stats(NULL, NULL);

WAITFOR DELAY '00:00:30';

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
WHERE   (v2.num_of_reads + v2.num_of_writes) > (v1.num_of_reads + v1.num_of_writes)
ORDER   BY 平均読み取り待ちms DESC;

DROP TABLE IF EXISTS #vfs1;

/* Q12 の答え:
   値が違う理由:
     1 はサーバー起動からの全期間の平均。長時間動いているサーバーでは、
       夜間バッチの数時間だけ 500ms だったという事故も、24時間の平均に薄まって消える。
       逆に、遠い過去の一時的な障害がいつまでも平均を押し上げ続けることもある。
     2 は指定した30秒間だけの実測。今この瞬間の状態を反映する。

   障害調査で使うべきなのは 2(差分)。
     「今遅い」の調査に、起動からの平均は役に立たない。
     1 は「このサーバーは全体としてストレージが遅い傾向があるか」という
     ベースライン把握には使える。

   目安(ストレージにより大きく変わる参考値):
     データファイル(ROWS)の読み書き … 10〜20ms 以下が望ましい
     ログファイル(LOG)の書き込み   … 5ms 以下。ここが遅いと WRITELOG 待ちが爆発する

   ★この「2回スナップショットして差分を取る」手法は、
     dm_os_wait_stats / dm_exec_query_stats / dm_os_performance_counters など
     累積型 DMV すべてに応用できる。上級者の調査はほぼこの形になる。

   ★注意: IO が遅い = ストレージが悪い、ではない。
     インデックスが無くて100万行スキャンしていれば、どんな SSD でも待ちは出る。
     まず論理読み取り上位のクエリを直すこと。ハードウェアの話はその後。 */


-- Q13. 未使用インデックスの検出
-- (1) インデックスを2本作る
CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate);

CREATE NONCLUSTERED INDEX IX_OrdersBig_Status
    ON dbo.OrdersBig (Status);
GO

-- (2) OrderDate 側だけを数回使う(Status 側は一度も使わない)
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-01';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-02';
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01' AND OrderDate < '2023-02-01';
GO

-- (3) 更新も発生させて user_updates を増やす(必ず ROLLBACK する)
BEGIN TRANSACTION;
    UPDATE TOP (5000) dbo.OrdersBig
    SET    Amount = Amount + 1
    WHERE  OrderId <= 5000;
ROLLBACK TRANSACTION;   -- ★データは元に戻すが、インデックスの更新は計上される
GO

-- (4) 使用状況を確認(IX_OrdersBig_Status は読み取り 0 のはず)
SELECT  i.name                                          AS インデックス名,
        ISNULL(us.user_seeks, 0)                        AS シーク,
        ISNULL(us.user_scans, 0)                        AS スキャン,
        ISNULL(us.user_lookups, 0)                      AS ルックアップ,
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
              + ISNULL(us.user_lookups, 0)              AS 読み取り合計,
        ISNULL(us.user_updates, 0)                      AS 更新回数
FROM    sys.indexes AS i
LEFT    JOIN sys.dm_db_index_usage_stats AS us
        ON  us.object_id   = i.object_id
        AND us.index_id    = i.index_id
        AND us.database_id = DB_ID()
WHERE   i.object_id = OBJECT_ID(N'dbo.OrdersBig')
  AND   i.index_id > 0
ORDER   BY 読み取り合計 DESC;

-- (5) 「読み取り 0 なのに更新コストだけ払っている」インデックスを DB 全体から検出
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
WHERE   i.index_id > 1                       -- ヒープ(0)・クラスタ化(1)は対象外
  AND   i.is_primary_key = 0
  AND   i.is_unique_constraint = 0
  AND   OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP   BY i.object_id, i.name, i.type_desc,
          us.user_seeks, us.user_scans, us.user_lookups, us.user_updates,
          us.last_user_seek, us.last_user_scan
HAVING  ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
      + ISNULL(us.user_lookups, 0) = 0
ORDER   BY ISNULL(us.user_updates, 0) DESC;

/* Q13 の答え(この結果だけで DROP してはいけない理由 — 4つ以上):

   ① 観測期間が足りない可能性
      統計はサーバー再起動でリセットされる。稼働時間が短ければ「読み取り 0」は
      「使われていない」ではなく「まだ測っていない」に過ぎない。
      必ず sys.dm_os_sys_info.sqlserver_start_time と併せて判断する(Q1)。

   ② 低頻度バッチを1周分含んでいない可能性
      月次・四半期・年次処理でしか使われないインデックスは、
      その周期を1周観測しないと使用実績が現れない。
      「1週間見て 0 だったから消す」は事故のもと。

   ③ 別レプリカで使われている可能性
      AlwaysOn 可用性グループの読み取り可能セカンダリでの利用は、
      そのレプリカ側でカウントされる。プライマリの数字だけ見て消すと、
      レポート系のクエリが一斉に遅くなる。

   ④ 制約や外部キーを支えている可能性
      PRIMARY KEY / UNIQUE 制約を支えるインデックスは、そもそも DROP INDEX で消せない。
      外部キー参照の検証や、ON DELETE CASCADE の性能に効いているものもある。
      (上のクエリでは is_primary_key / is_unique_constraint で除外している)

   ⑤ ALTER INDEX REBUILD で統計が消えた可能性
      SQL Server 2012 / 2014 には、インデックス再構築で
      sys.dm_db_index_usage_stats の行が消えてしまう既知の動作があった(2016 以降は保持)。
      メンテナンスジョブの直後は数字が当てにならない。

   ⑥ 一意性の担保・ヒントでの明示指定に使われている可能性
      UNIQUE インデックスは業務ルールそのものかもしれない。
      WITH (INDEX(...)) で名指しされているコードがないかも要確認。

   実務での安全な手順:
     1) CREATE INDEX 文を必ず控える(定義を失わないように)
     2) いきなり DROP せず ALTER INDEX ... DISABLE でしばらく様子を見る
        (戻すのは ALTER INDEX ... REBUILD)
     3) 問題が出なければ DROP する */


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q14. 欠落インデックスの提案を「鵜呑みにしない」練習

-- (1) いったん両方 DROP して、提案が出る状態に戻す
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status    ON dbo.OrdersBig;
GO

-- (2) 提案を溜めるためのクエリを何度か実行する
SET STATISTICS IO ON;

-- (2-a) CustomerId で絞って OrderDate と Amount を返す
SELECT OrderId, OrderDate, Amount
FROM   dbo.OrdersBig
WHERE  CustomerId = 7
  AND  OrderDate >= '2023-01-01' AND OrderDate < '2023-04-01';

-- (2-b) Status と OrderDate の範囲で絞って集計
SELECT CustomerId, SUM(Amount) AS 合計金額
FROM   dbo.OrdersBig
WHERE  Status = N'保留'
  AND  OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01'
GROUP  BY CustomerId;

SET STATISTICS IO OFF;
GO
-- ↑この時点の論理読み取り数を「Before」としてメモしておくこと(Clustered Index Scan で 6000 前後)

-- (3)(4) 提案を改善見込みスコア順に一覧し、DDL 草案も組み立てる
SELECT TOP (20)
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
        -- ★あくまで「たたき台」。そのまま実行しないこと
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
  AND   d.object_id   = OBJECT_ID(N'dbo.OrdersBig')
ORDER   BY 改善見込みスコア DESC;

/* Q14 の検討(★この章で最も重要な問い):

   典型的には、次のような2つの提案が並ぶ(環境により前後する):
     提案1: (CustomerId, OrderDate) INCLUDE (Amount)        ← 2-a 用
     提案2: (Status, OrderDate)     INCLUDE (CustomerId, Amount) ← 2-b 用

   ● 列の順序は妥当か
     提案の equality_columns → inequality_columns という並びは、
     偶然「等値 → 範囲」という 18章 6節の原則と一致していることが多い。
     しかし equality_columns が複数ある場合、その内部の順序は
     「クエリに出てきた順」に近いだけで、選択度は考慮されていない。
     - 提案2 の Status は 完了95% / 保留5% の偏った列。
       「保留」を引くなら先頭に置く価値があるが、
       「完了」で引くクエリでは先頭に置いても絞れない(18章 8節)。
       つまり "どの値で引かれるか" 次第であり、提案はそれを知らない。

   ● INCLUDE は妥当か
     元のクエリが返す列をそのまま全部並べているだけ。
     もし 2-a を SELECT * で書いていたら、
       INCLUDE (CustomerId, EmployeeId, ShipDate, Status, Amount)
     という「テーブルの複製」に近い提案が出る。
     正しい対処は INCLUDE を増やすことではなく、SELECT の列を削ること(18章 5-3節)。

   ● 統合できないか
     提案1 と 提案2 は別々の1本を要求してくるが、
     2本作れば更新コストは2倍、容量も2倍になる。
     このワークロードでは、まず「どちらが本当に頻繁に走るのか」を
     dm_exec_query_stats の実行回数で確認し、
     必要な1本に絞る(あるいは共通する OrderDate 先頭の1本で妥協する)判断があり得る。

   ● その他、提案が見ていないもの
     - 既存インデックスとの重複(すでに (OrderDate) があっても平気で重複提案する)
     - 更新コスト(INSERT/UPDATE/DELETE がどれだけ遅くなるか)
     - クラスタ化インデックス・列ストア・フィルター選択されたインデックスは提案対象外
     - avg_user_impact は「推定コストの改善率」であって実測ではない
     - 保持されるのは最大500グループまで
*/

-- (5) 自分で設計した1本を作る(提案のコピペではなく、18章の知識で決める)
--     判断: 2-a は CustomerId 等値 + OrderDate 範囲。等値を先頭にする原則どおり。
--           Amount は SELECT に出るだけなので INCLUDE。
--           2-b の Status は偏りが強く、この演習では「保留」でしか引かないので
--           まずは 2-a を優先して1本だけ作り、効果を測ってから次を考える。
CREATE NONCLUSTERED INDEX IX_OrdersBig_Cust_Date
    ON dbo.OrdersBig (CustomerId, OrderDate)
    INCLUDE (Amount);
GO

-- (6) 効果を数字で確認する(Before と比較する)
SET STATISTICS IO ON;

SELECT OrderId, OrderDate, Amount
FROM   dbo.OrdersBig
WHERE  CustomerId = 7
  AND  OrderDate >= '2023-01-01' AND OrderDate < '2023-04-01';

SET STATISTICS IO OFF;
GO
/* 期待される変化(環境により前後する目安):
     Before: Clustered Index Scan、論理読み取り 6,000 前後
     After : Index Seek (IX_OrdersBig_Cust_Date)、論理読み取り 数十
   Key Lookup が出ないこと(Amount を INCLUDE したのでカバリングになっている)も確認する。 */

-- (7) 「インデックスを作ると提案が消える」ことを確認する
SELECT  COUNT(*) AS 残っている提案数
FROM    sys.dm_db_missing_index_group_stats AS gs
JOIN    sys.dm_db_missing_index_groups      AS g ON g.index_group_handle = gs.group_handle
JOIN    sys.dm_db_missing_index_details     AS d ON d.index_handle       = g.index_handle
WHERE   d.object_id = OBJECT_ID(N'dbo.OrdersBig');
/* → dbo.OrdersBig にインデックス DDL を実行したことで、
     このテーブルに関する提案はクリアされている(0 になる)。
     だから「作る前に提案を保存しておく」ことが実務では必須。
     例: SELECT ... INTO dbo.MissingIndexSnapshot FROM (上の結合) ... */


-- Q15. シングルユース プランの肥大化: 再現 → 検出 → 限定的な掃除

-- (1) 現状を測る
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

-- (2) パラメーター化されていない SQL を200本流す(悪い例をわざと作る)
--     ※ 単純な等値検索だと「単純なパラメーター化」が効いてプランが再利用され、
--        肥大化が再現しないことがある。そこで結合+集計を入れて自明でないプランにする。
SET NOCOUNT ON;
DECLARE @i INT = 1;
DECLARE @sql NVARCHAR(MAX);

WHILE @i <= 200
BEGIN
    SET @sql =
        N'SELECT c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 合計
          FROM   dbo.OrdersBig AS o
          JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId
          WHERE  o.OrderId BETWEEN ' + CAST(@i * 100 AS NVARCHAR(10))
        + N' AND ' + CAST(@i * 100 + 50 AS NVARCHAR(10))
        + N' GROUP BY c.Region;';

    EXEC (@sql);        -- ★リテラル埋め込み。1本ごとに別プランがキャッシュされる
    SET @i += 1;
END;
GO

-- (3) もう一度測る → シングルユース数が約200増えているはず
SELECT  SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                 THEN 1 ELSE 0 END)                                AS シングルユース数,
        COUNT(*)                                                   AS 全プラン数,
        CAST(SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                      THEN CAST(cp.size_in_bytes AS BIGINT) ELSE 0 END)
             / 1024.0 / 1024.0 AS DECIMAL(10,1))                   AS シングルユースMB
FROM    sys.dm_exec_cached_plans AS cp;

-- (4) 何が溜まったかを見る
SELECT TOP (30)
        cp.usecounts            AS 使用回数,
        cp.size_in_bytes / 1024 AS サイズKB,
        cp.objtype              AS 種別,
        LEFT(t.text, 200)       AS SQL先頭
FROM    sys.dm_exec_cached_plans AS cp
CROSS   APPLY sys.dm_exec_sql_text(cp.plan_handle) AS t
WHERE   cp.objtype = N'Adhoc'
  AND   cp.usecounts = 1
  AND   t.text LIKE N'%OrdersBig%'
ORDER   BY cp.size_in_bytes DESC;

-- (5) 同じことを sp_executesql でパラメーター化して200本 → プランは1本しか増えない
SET NOCOUNT ON;
DECLARE @j INT = 1;
DECLARE @stmt NVARCHAR(MAX) =
    N'SELECT c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 合計
      FROM   dbo.OrdersBig AS o
      JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId
      WHERE  o.OrderId BETWEEN @from AND @to
      GROUP  BY c.Region;';

WHILE @j <= 200
BEGIN
    EXEC sys.sp_executesql
         @stmt,
         N'@from INT, @to INT',
         @from = @j,          -- 値だけが変わる
         @to   = @j;
    SET @j += 1;
END;
GO

-- 確認: 同じ形の Prepared プランが1本だけで usecounts が 200 になっている
SELECT  cp.objtype      AS 種別,
        cp.usecounts    AS 使用回数,
        cp.size_in_bytes / 1024 AS サイズKB,
        LEFT(t.text, 200) AS SQL先頭
FROM    sys.dm_exec_cached_plans AS cp
CROSS   APPLY sys.dm_exec_sql_text(cp.plan_handle) AS t
WHERE   t.text LIKE N'%@from INT, @to INT%'
   OR  (cp.objtype = N'Prepared' AND t.text LIKE N'%OrdersBig%')
ORDER   BY cp.usecounts DESC;

/* Q15 (6) 影響範囲を限定した掃除の方法 — 3つ以上:

   ★大前提: DBCC FREEPROCCACHE(引数なし)は本番で絶対に実行しない。
     サーバー上の全DB・全プランを捨てるため、直後に全クエリが一斉に再コンパイルされ、
     CPU が跳ね上がり、全ユーザーが同時に遅くなる。
     同じ理由で DBCC DROPCLEANBUFFERS も本番禁止(18章 1-3節と同じ方針)。

   ① 特定のプラン1つだけを捨てる(最も影響が小さい)
        DBCC FREEPROCCACHE (<plan_handle>);
      plan_handle は dm_exec_cached_plans / dm_exec_query_stats から取得する。
      スニッフィングで固まった1本を剥がすときの実務的な手段(28章)。

   ② 特定のデータベースのプランだけ捨てる(SQL Server 2016+)
        ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
      そのDBに閉じるので、同居している他のDBには影響しない。

   ③ 特定オブジェクトを参照するプランだけ再コンパイル対象にする
        EXEC sp_recompile N'dbo.OrdersBig';
      次回実行時に作り直される。ただし Sch-M ロックを取るので、
      稼働中のテーブルに対しては一瞬ブロックが発生しうる点に注意。

   ④ アドホックプランのキャッシュストアだけ捨てる
        DBCC FREESYSTEMCACHE ('SQL Plans');
      今回の演習で溜めたゴミにはこれが効くが、
      サーバー全体のアドホックプランが対象になるので本番では慎重に。

   ⑤ そもそもキャッシュを汚さない
        SELECT ... OPTION (RECOMPILE);
      学習中に「毎回コンパイルさせて測りたい」だけならこれで十分。

   根本対策(掃除ではなく再発防止):
     ・アプリ側で sp_executesql によるパラメーター化(20章)。これが本筋。
     ・サーバー構成 optimize for ad hoc workloads を有効にする。
       初回はスタブだけをキャッシュし、2回目に本体を入れる。副作用が少なく効果が大きい。
     ・PARAMETERIZATION FORCED は、スニッフィングの影響を広げる副作用があるため安易に使わない(28章)。
*/

-- (6) 実際に掃除する。ここでは②(DB スコープ)を使う。
--     ★このステートメントは SalesLearning の中だけに影響する。
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;   -- SQL Server 2016+
GO

-- 掃除後の確認(SalesLearning 由来のアドホックプランが減っていること)
SELECT  SUM(CASE WHEN cp.objtype = N'Adhoc' AND cp.usecounts = 1
                 THEN 1 ELSE 0 END)  AS シングルユース数,
        COUNT(*)                     AS 全プラン数
FROM    sys.dm_exec_cached_plans AS cp;

-- (参考) ①を試したい場合の plan_handle の取り出し方
-- SELECT TOP (5) cp.plan_handle, cp.usecounts, LEFT(t.text, 100) AS SQL先頭
-- FROM   sys.dm_exec_cached_plans AS cp
-- CROSS  APPLY sys.dm_exec_sql_text(cp.plan_handle) AS t
-- WHERE  t.text LIKE N'%OrdersBig%'
-- ORDER  BY cp.size_in_bytes DESC;
-- DBCC FREEPROCCACHE (0x0600...);   -- ← 上で得た plan_handle を貼る


-- Q16. sys.dm_db_index_physical_stats の3モード比較
SET STATISTICS TIME ON;

-- (a) LIMITED(既定): リーフの1つ上のレベルだけを読む → 最も軽い
SELECT  i.name                              AS インデックス名,
        ips.index_type_desc                 AS 種別,
        ips.index_level                     AS レベル,
        ips.page_count                      AS ページ数,
        CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS 断片化率,
        ips.avg_page_space_used_in_percent  AS ページ使用率,   -- LIMITED では NULL
        ips.record_count                    AS 行数            -- LIMITED では 0
FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.OrdersBig'),
                                       NULL, NULL, 'LIMITED') AS ips
JOIN    sys.indexes AS i
        ON  i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE   ips.index_level = 0;

-- (b) SAMPLED: リーフページの約1%をサンプリング(1万ページ未満なら DETAILED と同等)
SELECT  i.name                              AS インデックス名,
        ips.index_level                     AS レベル,
        ips.page_count                      AS ページ数,
        CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS 断片化率,
        CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,2)) AS ページ使用率,
        ips.record_count                    AS 行数
FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.OrdersBig'),
                                       NULL, NULL, 'SAMPLED') AS ips
JOIN    sys.indexes AS i
        ON  i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE   ips.index_level = 0;

-- (c) DETAILED: 全ページを読む → 最も重い。★本番の全オブジェクトに対しては実行しない
SELECT  i.name                              AS インデックス名,
        ips.index_level                     AS レベル,
        ips.page_count                      AS ページ数,
        CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,2)) AS 断片化率,
        CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,2)) AS ページ使用率,
        ips.record_count                    AS 行数,
        ips.min_record_size_in_bytes        AS 最小行サイズ,
        ips.max_record_size_in_bytes        AS 最大行サイズ,
        ips.avg_record_size_in_bytes        AS 平均行サイズ
FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.OrdersBig'),
                                       NULL, NULL, 'DETAILED') AS ips
JOIN    sys.indexes AS i
        ON  i.object_id = ips.object_id AND i.index_id = ips.index_id;   -- 全レベルが返る

SET STATISTICS TIME OFF;

/* Q16 の答え:

   モード比較(dbo.OrdersBig ≒ 6,000ページ。時間は環境により大きく前後する目安):
     LIMITED   … 数ms〜数十ms。リーフの1つ上のレベルだけを読む。
                 取れるのは avg_fragmentation_in_percent と page_count が中心。
                 avg_page_space_used_in_percent は NULL、record_count は 0。
     SAMPLED   … 数十ms〜数百ms。リーフの約1%を読む。
                 ページ密度や行サイズも取れる。ただし推定値。
                 ページ数が1万未満のインデックスでは自動的に DETAILED 相当になる。
     DETAILED  … 最も遅い(このテーブルでも LIMITED の数倍〜数十倍)。全ページを読む。
                 index_level ごとに行が返るので、B木の各レベルの状態まで見える。

   本番で DETAILED を全オブジェクトに実行してはいけない理由:
     ・全インデックスの全ページを物理的に読むため、
       データベース全体を1回スキャンするのと同等の IO が発生する。
     ・読み込んだページがバッファプールを洗い流し、
       本来キャッシュされているべき業務データが追い出される(PLE が急落する)。
     ・数百GB のデータベースでは数時間かかることがあり、その間ずっと高負荷が続く。
     ・第2引数を NULL にすると DB 内の全オブジェクトが対象になる。
       「DETAILED × 第2引数 NULL」は本番で最もやってはいけない組み合わせ。

   実務の指針:
     ・まず LIMITED で断片化率を見て、対象を絞ってから必要なものだけ SAMPLED/DETAILED。
     ・page_count が 1000 未満(約8MB未満)の小さいインデックスの断片化率は無視してよい。
     ・断片化率の目安: 〜5% 放置 / 5〜30% REORGANIZE / 30%〜 REBUILD。
     ・SSD 環境では断片化の実害は HDD 時代よりずっと小さい。
       断片化対策より統計情報の更新(27章)のほうが効くことがよくある。 */


-- Q17. 総合シナリオ(クエリ不要。手順と使う機能を具体的に答える)
/*
  シナリオ:
    「基幹システムの受注検索画面がここ数日だけ極端に遅い」
    サーバーは3か月無停止。Query Store は有効。今も遅い状態が続いている。

  ---------------------------------------------------------------
  1) 最初に確認すること
  ---------------------------------------------------------------
     sys.dm_os_sys_info.sqlserver_start_time で稼働時間を確認する(3か月)。

     なぜここから始めるのか:
       ・DMV の累積値が「3か月ぶんの合計」だと分かって初めて数字が読める。
         3か月の合計 CPU 上位には、今回の問題と無関係な定常バッチが並ぶ可能性が高い。
         つまり「合計」ランキングは今回あまり役に立たず、
         「平均」「最近の実行(last_execution_time)」「Query Store の時間軸」で
         見なければならない、という方針がここで決まる。
       ・sys.dm_exec_query_stats の creation_time も併せて見る。
         プランが数日前に作り直されていれば、それ自体が有力な手がかりになる。

     同時に「本当に今も遅いのか」を sys.dm_exec_requests で確認する。
     再現していないのに調査を進めても空振りする。

  ---------------------------------------------------------------
  2) 「今」を掴む順序
  ---------------------------------------------------------------
     ① sys.dm_os_wait_stats(23章)
        起動からの累積だが、まず全体の待機傾向を見る。
        可能なら2回スナップショットして差分を取り、「今この5分」の待機を出す。
        → CPU 系(SOS_SCHEDULER_YIELD)/ IO 系(PAGEIOLATCH_*)/
          ロック系(LCK_M_*)/ メモリ系(RESOURCE_SEMAPHORE)/ 並列(CXPACKET)
          のどれが支配的かで、以降の道筋が分かれる。

     ② sys.dm_os_waiting_tasks
        今この瞬間、誰が何を待っているか。セッションが特定できる。

     ③ sys.dm_exec_requests + sys.dm_exec_sessions + sys.dm_exec_sql_text
        受注検索画面のクエリが実際に走っているセッションを特定する。
        program_name / host_name / login_name でアプリを絞り込める。
        status / wait_type / blocking_session_id / logical_reads を見る。

     ④ blocking_session_id が 0 でなければ、再帰CTE で先頭ブロッカーを特定(Q11)。
        ブロック元が sleeping なら dm_exec_connections.most_recent_sql_handle で SQL を取る。

     ⑤ sys.dm_exec_query_stats
        該当クエリを query_hash か text で絞り、
        execution_count / 平均CPU / 平均論理読み取り / creation_time / max と平均の比 を見る。
        max_worker_time が平均の何十倍もあればスニッフィングを疑う(28章)。

     ⑥ 実行中クエリのプランを sys.dm_exec_query_plan で取得しておく(証拠保全)。

  ---------------------------------------------------------------
  3) 「ここ数日だけ」という時間軸をどこから取るか
  ---------------------------------------------------------------
     → Query Store(24章)。これが唯一の正解。

     なぜ DMV では不十分か:
       ・sys.dm_exec_query_stats はプランキャッシュに残っているものしか見えない。
         プランが追い出されたり再コンパイルされた時点で、それ以前の実績は消える。
         creation_time が「昨日」なら、それ以前の履歴は DMV には存在しない。
       ・DMV には「時間帯別の推移」という概念が無い。累積値の1点しか取れないので、
         「3日前から遅くなった」を証明できない。
       ・sys.dm_os_wait_stats も起動からの累積で、日次の変化は分からない。

     Query Store で見るもの:
       ・[上位リソース消費クエリ] で該当クエリを特定
       ・[プランの変更履歴] … 同じ query_id に複数の plan_id があり、
         数日前を境に使われるプランが切り替わっていないか
       ・[リグレッションが発生したクエリ] … まさにこの用途のレポート
       ・sys.query_store_runtime_stats を時間間隔(runtime_stats_interval_id)別に集計し、
         「いつから平均時間が跳ねたか」を日付で特定する

  ---------------------------------------------------------------
  4) 原因が「プランが変わったこと」だと分かったら次に見るもの
  ---------------------------------------------------------------
     ・Query Store で 旧プランと新プランを並べて比較する(18章の読み方)。
         - Index Seek → Clustered Index Scan に変わっていないか
         - Nested Loops → Hash Match(または逆)に変わっていないか(29章)
         - 推定行数と実際の行数の乖離が新プランで拡大していないか
         - Key Lookup が増えていないか
     ・なぜ変わったのかを探る:
         - 統計情報の更新(sys.dm_db_stats_properties の last_updated /
           modification_counter)がきっかけになっていないか(27章)
         - パラメーター スニッフィング。再コンパイルの契機(サーバー再起動、
           統計更新、プラン追い出し)で「たまたま非典型な引数」でコンパイルされた可能性(28章)
         - データ量そのものが増えてティッピングポイントを超えた(18章 5-4節)
         - インデックスが誰かに削除・変更されていないか(sys.indexes、スキーマ変更履歴)
     ・応急処置:
         - Query Store の [計画の強制] で旧プランを強制する(最速の止血)
         - あるいは OPTION (RECOMPILE) / OPTIMIZE FOR
       恒久対策はインデックス設計かクエリ書き換え。強制は暫定であることを忘れない。

  ---------------------------------------------------------------
  5) 効果をどう証明するか
  ---------------------------------------------------------------
     ・第一の証拠は「論理読み取り数」。SET STATISTICS IO ON で
       修正前 → 修正後 を同じクエリ・同じ引数で比較する(18章の合言葉)。
       経過時間は他の負荷でブレるので主指標にしない。
     ・第二に Query Store の同じ query_id について、
       修正前後の期間で avg_duration / avg_cpu_time / avg_logical_io_reads を比較する。
       これは「実運用の実測」なので説明資料としていちばん強い。
     ・第三に、修正前に取っておいた dm_exec_query_stats のスナップショット
       (改善前に一時テーブル or 実テーブルへ SELECT INTO しておく)と差分を取る。
     ・第四に、サーバー全体として待機統計(dm_os_wait_stats の差分)が
       改善しているかを確認する。個別クエリだけ速くなって全体が変わらないなら、
       そもそも本命ではなかったということ。
     ・そして ①(待機統計)に戻る。次のボトルネックが顔を出しているはずで、
       チューニングは「一番重いものを削ると次が見える」の繰り返しになる。
*/


------------------------------------------------------------
-- Q18. 必須の後片付け
------------------------------------------------------------

-- (1) この演習で作成した非クラスタ化インデックスをすべて削除
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate  ON dbo.OrdersBig;   -- Q13
DROP INDEX IF EXISTS IX_OrdersBig_Status     ON dbo.OrdersBig;   -- Q13
DROP INDEX IF EXISTS IX_OrdersBig_Cust_Date  ON dbo.OrdersBig;   -- Q14(自分で設計した1本)
GO

-- (2) 一時テーブルの後片付け(セッションが残っている場合の保険)
DROP TABLE IF EXISTS #vfs1;
GO

-- (3) 未完了トランザクションが残っていないことを確認
SELECT @@TRANCOUNT AS 自セッションの未完了トランザクション数;   -- 0 であること

SELECT  st.session_id,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status                        AS セッション状態,
        at.transaction_begin_time       AS トラン開始時刻,
        DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()) AS 経過秒
FROM    sys.dm_tran_session_transactions AS st
JOIN    sys.dm_tran_active_transactions  AS at ON at.transaction_id = st.transaction_id
JOIN    sys.dm_exec_sessions             AS s  ON s.session_id      = st.session_id
WHERE   s.is_user_process = 1;
-- → 行が返る場合、W1〜W3 のどれかが停止していない。
--    セクションC は30秒で自動 ROLLBACK するので、待つか該当ウィンドウを確認すること。

-- (4) 負荷スクリプトが止まっていることを確認(実行中のユーザーリクエストが無いこと)
SELECT  r.session_id, s.program_name, r.status, r.command,
        DB_NAME(r.database_id) AS DB
FROM    sys.dm_exec_requests AS r
JOIN    sys.dm_exec_sessions AS s ON s.session_id = r.session_id
WHERE   s.is_user_process = 1
  AND   r.session_id <> @@SPID;

-- (5) dbo.WorkloadTest を削除する場合(05_workload.sql の【後片付け】と同じ)
--     ※ 23章・25章の演習をこれから行うなら残しておいてよい
-- DROP TABLE IF EXISTS dbo.WorkloadTest;

-- (6) 最終確認: dbo.OrdersBig が PK_OrdersBig だけの状態に戻っていること
SELECT  name        AS インデックス名,
        type_desc   AS 種別,
        index_id
FROM    sys.indexes
WHERE   object_id = OBJECT_ID(N'dbo.OrdersBig')
  AND   index_id > 0;
-- → PK_OrdersBig (CLUSTERED) の1行だけになっていれば OK

/* 補足: 途中でおかしくなったら sample-db/03_bulk_data.sql を再実行すれば
   dbo.OrdersBig を丸ごと作り直せる(既存の小さいテーブルには影響しない)。

   なお、この演習ではサーバー構成(optimize for ad hoc workloads など)は
   変更していないので、戻す作業は不要。
   もし試しに変更した場合は、既定値 0 に戻すこと:
     EXEC sp_configure 'optimize for ad hoc workloads', 0;  RECONFIGURE;
*/
