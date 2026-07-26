/* ============================================================
   解答例 25 — 拡張イベント (Extended Events)
   対象演習: exercises/25_extended_events.md

   ★★ このファイルは「全選択して一気に実行(F5)」してはいけません ★★
     - Q8(デッドロック)と Q11(ブロッキング)は 2〜3 のセッション
       (SSMS のクエリウィンドウ)が必要です。
       【セッションA】【セッションB】【セッションC】のラベルと手順番号の順に、
       該当するウィンドウへ 1ブロックずつコピーして実行してください。
     - 各セッションは「作成 → 開始 → 負荷 → 待つ → 読む → 停止 → 削除」の
       順に、ブロック単位で実行します。

   安全方針:
     - 作成する EVENT SESSION の名前はすべて xe_ex25_ で始めます。
       各問の最後で DROP EVENT SESSION し、Q16 で残っていないことを確認します。
     - サーバー設定 blocked process threshold (s) は Q11 で変更しますが、
       Q11-(6) で必ず既定値 0 に戻します。
     - 本物のテーブル(Employees / Products / Departments)を触る実験は
       値を変えない UPDATE にし、必ず ROLLBACK します。
     - event_file の出力先は C:\XE\(Linux は /var/opt/mssql/log/)。
       .xel ファイルは DROP しても残るので Q13-(5) / Q16-(6) で OS 側から削除します。

   必要な権限: ALTER ANY EVENT SESSION / VIEW SERVER STATE
   対象バージョン: SQL Server 2016 以降
     (AT TIME ZONE は 2016+。2014 以前は DATEADD(HOUR, 9, ...) で代用)
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 既定で動いているセッションを調べる

-- (a) いま実行中のセッション
SELECT name AS 実行中セッション
FROM   sys.dm_xe_sessions
ORDER  BY name;
-- → system_health / AlwaysOn_health / telemetry_xevents(2016+) /
--    hkenginexesession(インメモリOLTP)など。環境により前後する。

-- (b) 「定義」と「実行中」を1つの表にする
SELECT es.name                AS セッション名,
       es.startup_state       AS 起動時に自動開始,
       CASE WHEN dm.address IS NULL THEN N'停止中' ELSE N'実行中' END AS 状態,
       dm.create_time         AS 開始時刻
FROM   sys.server_event_sessions AS es
LEFT   JOIN sys.dm_xe_sessions   AS dm ON dm.name = es.name
ORDER  BY es.name;

-- 説明:
--  ・sys.server_event_sessions は「定義」のカタログビュー。DROP するまで永続し、
--    停止中のセッションもここには載る。
--  ・sys.dm_xe_sessions は「いまメモリ上で動いているセッション」の DMV。
--    ここに出てこない = 止まっている、ということ。
--  ・LEFT JOIN にしているのは「定義はあるが止まっている」ものを落とさないため。

-- (c) system_health のターゲット(2個ある)
SELECT s.name         AS セッション名,
       t.target_name  AS ターゲット名,
       t.bytes_written AS 書き込みバイト数
FROM   sys.dm_xe_sessions        AS s
JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
WHERE  s.name = N'system_health';
-- → ring_buffer と event_file の2つ。
--    ring_buffer はすぐ上書きされるので、過去にさかのぼるなら event_file を読む。


-- Q2. イベントを検索する

-- (a) 名前に deadlock を含むイベント
SELECT p.name        AS パッケージ,
       o.name        AS イベント名,
       o.description AS 説明
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'event'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)   -- private を除外
  AND  o.name LIKE '%deadlock%'
ORDER  BY p.name, o.name;
-- → sqlserver.xml_deadlock_report / lock_deadlock / lock_deadlock_chain /
--    database_xml_deadlock_report など。実務で使うのは xml_deadlock_report。

-- (b) 名前に blocked を含むイベント
SELECT p.name AS パッケージ, o.name AS イベント名, o.description AS 説明
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'event'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)
  AND  o.name LIKE '%blocked%'
ORDER  BY p.name, o.name;
-- → sqlserver.blocked_process_report

-- (c) 使用できるターゲット
SELECT p.name AS パッケージ, o.name AS ターゲット名, o.description AS 説明
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'target'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER  BY p.name, o.name;
-- → package0.ring_buffer / event_file / histogram / event_counter /
--    pair_matching / etw_classic_sync_target

-- (別解) アクション / 述語ソース / 列挙値も同じ形で探せる
SELECT p.name AS パッケージ, o.name AS アクション名, o.description
FROM   sys.dm_xe_objects AS o JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'action' AND (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER  BY p.name, o.name;

SELECT p.name AS パッケージ, o.name AS 述語ソース名, o.description
FROM   sys.dm_xe_objects AS o JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'pred_source' AND (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER  BY p.name, o.name;


-- Q3. duration の単位を自分の目で確かめる
SELECT oc.object_name  AS イベント,
       oc.name         AS 列名,
       oc.type_name    AS 型,
       oc.column_type  AS 種別,      -- data / readonly / customizable
       oc.description  AS 説明
FROM   sys.dm_xe_object_columns AS oc
WHERE  oc.object_name IN ('sql_statement_completed', 'blocked_process_report', 'wait_info')
ORDER  BY oc.object_name, oc.column_type, oc.name;

-- duration の description を見ると単位が書いてある:
--   sql_statement_completed : microseconds  → 1秒 = 1000000
--   blocked_process_report  : microseconds  → 1秒 = 1000000
--   wait_info               : milliseconds  → 1秒 = 1000
-- ポイント: 単位は「イベントごとに違う」。推測せず必ず description で確認する。
--           1000 倍間違えると「全部引っかかる」か「1件も採れない」になる。

-- duration だけを抜き出して並べると分かりやすい
SELECT object_name AS イベント, name AS 列名, description AS 説明
FROM   sys.dm_xe_object_columns
WHERE  name = 'duration'
  AND  object_name IN ('sql_statement_completed', 'sql_batch_completed', 'rpc_completed',
                       'module_end', 'blocked_process_report', 'wait_info')
ORDER  BY object_name;


-- Q4. 遅いクエリ捕捉セッションを作る(まだ開始しない)
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_slow')
    ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_slow')
    DROP EVENT SESSION [xe_ex25_slow] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_slow] ON SERVER

ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.sql_text
    )
    -- ★述語は左から短絡評価される。安い条件(イベント自身の列)を先に書く
    WHERE ( [duration] > 100000                                -- 100,000us = 100ms
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )
),

ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.sql_text
    )
    WHERE ( [duration] > 100000
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )
)

ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 1000 )

WITH
(
    MAX_MEMORY            = 8 MB,
    EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY  = 5 SECONDS,   -- 既定は 30 秒。学習中は短くする
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY       = OFF,
    STARTUP_STATE         = OFF
);
GO

-- 登録された内容を確認する
SELECT e.name      AS イベント,
       e.predicate AS 述語
FROM   sys.server_event_session_events AS e
JOIN   sys.server_event_sessions       AS s ON s.event_session_id = e.event_session_id
WHERE  s.name = N'xe_ex25_slow';

SELECT e.name AS イベント, a.name AS アクション
FROM   sys.server_event_session_events  AS e
JOIN   sys.server_event_sessions        AS s ON s.event_session_id = e.event_session_id
LEFT   JOIN sys.server_event_session_actions AS a
       ON  a.event_session_id = e.event_session_id
       AND a.event_id         = e.event_id
WHERE  s.name = N'xe_ex25_slow'
ORDER  BY e.name, a.name;

-- (別解) 定義そのものをスクリプト化して読む:
--   SSMS の オブジェクトエクスプローラー → 管理 → 拡張イベント → セッション →
--   右クリック「セッションのスクリプト化」


-- Q5. 開始して、捕まえて、XML を表にする
ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = START;
GO

-- わざと遅いクエリを流す(OrdersBig は100万行・非クラスタ化インデックス無し)
DECLARE @s DECIMAL(38,2);

SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'保留';           -- (a)
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;     -- (b) SARGable でない
GO

-- ★MAX_DISPATCH_LATENCY = 5 SECONDS なので、読む前に待つ
WAITFOR DELAY '00:00:06';
GO

-- ring_buffer の XML を表に展開する(★この章の中核パターン)
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name        = N'xe_ex25_slow'
      AND  t.target_name = N'ring_buffer'
)
SELECT
    x.value('@name', 'nvarchar(100)')                                       AS イベント種別,
    x.value('@timestamp', 'datetime2')
        AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'               AS 発生時刻JST,
    x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0         AS 実行時間ms,
    x.value('(data[@name="cpu_time"]/value)[1]', 'bigint') / 1000.0         AS CPU時間ms,
    x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')             AS 論理読み取り,
    x.value('(data[@name="physical_reads"]/value)[1]', 'bigint')            AS 物理読み取り,
    x.value('(data[@name="row_count"]/value)[1]', 'bigint')                 AS 行数,
    x.value('(action[@name="session_id"]/value)[1]', 'int')                 AS セッションID,
    x.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')  AS アプリ名,
    x.value('(action[@name="username"]/value)[1]', 'nvarchar(128)')         AS ログイン,
    x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')          AS 実行された文,
    x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')         AS バッチ全文
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
ORDER  BY 実行時間ms DESC;

-- ポイント:
--  ・nodes('/RingBufferTarget/event') で 1イベント = 1行 に展開する。
--  ・イベントの標準列は <data>、ACTION で足した情報は <action>。タグ名が違うだけ。
--  ・value() のパス末尾の [1] は必須(単一値であることを保証する)。忘れるとエラー。
--  ・@timestamp は UTC。AT TIME ZONE(2016+)で JST に直す。
--    2014 以前なら DATEADD(HOUR, 9, x.value('@timestamp','datetime2'))。
--  ・statement = その1文だけ / sql_text = バッチ全体。用途が違う。
--  ・数値(実行時間・論理読み取り)は環境により大きく前後する目安。


-- Q6. 文ごとに集計する
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_slow' AND t.target_name = N'ring_buffer'
),
E AS
(
    SELECT x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)') AS 文,
           x.value('(data[@name="duration"]/value)[1]', 'bigint')         AS 時間us,
           x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')    AS 論理読み取り
    FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
)
SELECT LEFT(文, 120)          AS 文の先頭,
       COUNT(*)               AS 実行回数,
       SUM(時間us) / 1000.0   AS 合計ms,
       AVG(時間us) / 1000.0   AS 平均ms,
       MAX(時間us) / 1000.0   AS 最大ms,
       SUM(論理読み取り)       AS 合計論理読み取り
FROM   E
GROUP  BY LEFT(文, 120)
ORDER  BY 合計ms DESC;

-- 答え:
--  基本は「合計ms が大きいもの」から手を付ける。
--  平均が速くても呼ばれる回数が多い文は、サーバー全体のCPU・I/Oを最も多く消費しており、
--  1回あたり数ミリ秒の改善でも総量では最大の効果が出る。
--  「1回が極端に遅い文」は、ユーザー体感やタイムアウトの観点で優先されることはあるが、
--  サーバー全体の負荷という意味では合計値のほうが正しい優先順位になる。
--  (Query Store の「合計実行時間」で並べるのと同じ考え方。24章参照)


-- Q7. イベントが落ちていないかを計測する
SELECT name                       AS セッション名,
       dropped_event_count        AS 落ちたイベント数,
       dropped_buffer_count       AS 落ちたバッファ数,
       largest_event_dropped_size AS 落ちた最大サイズ,
       blocked_event_fire_time    AS 発火がブロックされた時間,
       total_regular_buffers      AS 通常バッファ数,
       regular_buffer_size        AS 通常バッファサイズ
FROM   sys.dm_xe_sessions
ORDER  BY name;

-- 答え: dropped_event_count が 0 でなかったら、最初に疑うのは
--       「MAX_MEMORY 不足」ではなく「述語が緩すぎてイベント量が多すぎること」。
--       メモリを増やす前に、まずフィルタ(duration しきい値・database_name)を見直す。
--       largest_event_dropped_size が大きい場合だけ MAX_EVENT_SIZE を検討する。

-- 停止して削除する
ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = STOP;
GO

-- ★停止直後にもう一度読むと 0 行になる
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_slow' AND t.target_name = N'ring_buffer'
)
SELECT COUNT(*) AS 件数
FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x);
-- → 0 行。理由は2つ:
--    ① ring_buffer はメモリ上のターゲットなので、STOP した瞬間に中身が破棄される。
--    ② そもそも sys.dm_xe_sessions は「実行中」の DMV なので、停止すると行自体が消え、
--       JOIN 結果が空になる(=読みようがない)。
--    → 停止後にも読みたいなら event_file を使う(Q13)。

DROP EVENT SESSION [xe_ex25_slow] ON SERVER;
GO


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q8. デッドロックを起こして捕捉する(2セッション)

-- (1) セッションを作る 【どのウィンドウで実行してもよい】
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_deadlock')
    ALTER EVENT SESSION [xe_ex25_deadlock] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_deadlock')
    DROP EVENT SESSION [xe_ex25_deadlock] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_deadlock] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 100 )
WITH
(
    MAX_MEMORY           = 4 MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = OFF          -- 本番で常設するなら ON + event_file
);
GO

ALTER EVENT SESSION [xe_ex25_deadlock] ON SERVER STATE = START;
GO

-- 答え(なぜアクションも述語も要らないのか):
--  ・xml_deadlock_report が返す XML の中に、関与した全プロセスの SPID・inputbuf・
--    executionStack・分離レベル・待機リソース・クライアント情報が最初から含まれている。
--    ACTION で追加収集する必要がない(むしろ無駄なコスト)。
--  ・述語については、このイベントは database_name のような列を持たない
--    (デッドロックは複数DBにまたがり得るため)。加えて発生頻度が極めて低いので、
--    フィルタ無しで流しても実害がない。


/* ---- ここから2セッション ---- */

-- 【セッションA】手順1: Employees をロック(値は変えない UPDATE)
BEGIN TRAN;
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;
SELECT @@SPID AS セッションA_SPID, @@TRANCOUNT AS 深さ;


-- 【セッションB】手順2: Products をロック(A と獲得順序が逆)
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
SELECT @@SPID AS セッションB_SPID, @@TRANCOUNT AS 深さ;


-- 【セッションA】手順3: 次に Products が欲しい → B に待たされる(戻ってこない)
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;


-- 【セッションB】手順4: 次に Employees が欲しい → デッドロック成立
--   数秒後、どちらか一方に エラー 1205 が出て強制終了される
--   「トランザクション (プロセス ID nn) が別のプロセスとロック リソースで
--     デッドロック状態になったため、…」の nn を控える
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;


-- 【セッションA】【セッションB】手順5: 両方で必ず後片付け
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 であること

/* ---- 2セッションここまで ---- */


-- (3) 6秒待ってからデッドロックグラフを取り出す
WAITFOR DELAY '00:00:06';
GO

WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_deadlock' AND t.target_name = N'ring_buffer'
)
SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'          AS 発生時刻JST,
       x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]')   AS デッドロックグラフ
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER  BY 発生時刻JST DESC;

-- ポイント:
--  ・データ列名は xml_deadlock_report(イベント名と同じ)。xml_report ではない。
--  ・value ではなく query を使う。<deadlock> という「XML の塊」を丸ごと取り出すため。
--  ・結果セルの XML をクリックすると新しいタブで開く。
--    それを拡張子 .xdl で保存して SSMS で開き直すと、デッドロックグラフの「図」になる。

-- (デバッグ用) 取れないときは <event> を丸ごと表示して data name= を目で確認する
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_deadlock' AND t.target_name = N'ring_buffer'
)
SELECT x.query('.') AS イベント丸ごと
FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x);


-- Q9. デッドロックグラフを読み解く
DECLARE @dl XML;

SELECT TOP (1) @dl = x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]')
FROM  (
        SELECT CAST(t.target_data AS XML) AS TargetData
        FROM   sys.dm_xe_sessions        AS s
        JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
        WHERE  s.name = N'xe_ex25_deadlock' AND t.target_name = N'ring_buffer'
      ) AS RB
CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER BY x.value('@timestamp', 'datetime2') DESC;

-- (a) 関与したプロセス一覧(犠牲者に印を付ける)
SELECT
    CASE WHEN p.value('@id', 'nvarchar(50)')
              = @dl.value('(/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)')
         THEN N'★犠牲者' ELSE N'生存' END                          AS 判定,
    p.value('@spid', 'int')                                         AS SPID,
    p.value('@lockMode', 'nvarchar(20)')                            AS 要求ロック,
    p.value('@isolationlevel', 'nvarchar(60)')                      AS 分離レベル,
    p.value('@status', 'nvarchar(30)')                              AS 状態,
    p.value('@waitresource', 'nvarchar(200)')                       AS 待機リソース,
    p.value('@clientapp', 'nvarchar(200)')                          AS アプリ,
    p.value('@hostname', 'nvarchar(128)')                           AS ホスト,
    p.value('@loginname', 'nvarchar(128)')                          AS ログイン,
    LTRIM(RTRIM(p.value('(inputbuf)[1]', 'nvarchar(max)')))         AS 実行していたSQL
FROM   @dl.nodes('/deadlock/process-list/process') AS t(p);

-- (b) 衝突したリソース一覧
SELECT
    r.value('local-name(.)', 'nvarchar(50)')                        AS リソース種別,
    r.value('@objectname', 'nvarchar(300)')                         AS オブジェクト,
    r.value('@indexname', 'nvarchar(300)')                          AS インデックス,
    r.value('@mode', 'nvarchar(20)')                                AS リソースのモード,
    r.value('(owner-list/owner/@id)[1]', 'nvarchar(50)')            AS 保持しているプロセス,
    r.value('(owner-list/owner/@mode)[1]', 'nvarchar(20)')          AS 保持モード,
    r.value('(waiter-list/waiter/@id)[1]', 'nvarchar(50)')          AS 待っているプロセス,
    r.value('(waiter-list/waiter/@mode)[1]', 'nvarchar(20)')        AS 要求モード
FROM   @dl.nodes('/deadlock/resource-list/*') AS t(r);

-- (c) 実行スタック(どの行のどの文だったか)まで見たいとき
SELECT p.value('@spid', 'int')                              AS SPID,
       f.value('@procname', 'nvarchar(300)')                AS プロシージャ,
       f.value('@line', 'int')                              AS 行番号,
       LTRIM(RTRIM(f.value('.', 'nvarchar(max)')))          AS フレームのSQL
FROM   @dl.nodes('/deadlock/process-list/process') AS t(p)
CROSS  APPLY p.nodes('executionStack/frame')       AS s(f);

-- 答え:
--  ・犠牲者の SPID は、Q8(2) のエラー 1205 に出た「プロセス ID」と一致する。
--    (エラー 1205 を受け取った側 = 犠牲者)
--  ・読む順序は必ず 4 ステップ:
--      1. victim-list  → どちらが殺されたか(リトライ対象)
--      2. resource-list → どのテーブルの、どのインデックスで衝突したか(対策の主戦場)
--      3. 各 process の inputbuf / executionStack → 何を実行していたか
--      4. owner-list と waiter-list の対応 → 獲得順序を復元する
--  ・今回の根本原因: 「リソースの獲得順序の食い違い」。
--      A は Employees → Products、B は Products → Employees の順で触っている。
--    19章の対策表のうち最も効くのは「アクセス順序を統一する」。
--    アプリ全体で「必ず Employees → Products の順で更新する」と決めれば、
--    このデッドロックは構造的に起こらなくなる。
--    (インデックス改善・トランザクション短縮・RCSI は補助的に効くが、
--     順序不一致そのものは解消しない)


-- Q10. 既定の system_health からも同じデッドロックを取り出す
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'system_health' AND t.target_name = N'ring_buffer'
)
SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'  AS 発生時刻JST,
       x.query('(data/value/deadlock)[1]')                        AS デッドロックグラフ
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER  BY 発生時刻JST DESC;

-- (別解) system_health の event_file から読む(ring_buffer より長く残っている)
--   相対パスは SQL Server の既定 LOG フォルダーからの相対として解決される
DROP TABLE IF EXISTS #SH;

SELECT CAST(event_data AS XML) AS ED
INTO   #SH
FROM   sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL);

SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'          AS 発生時刻JST,
       x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]')   AS グラフ
FROM   #SH CROSS APPLY ED.nodes('/event') AS e(x)     -- ★event_file は /event から
WHERE  x.value('@name', 'nvarchar(100)') = N'xml_deadlock_report'
ORDER  BY 発生時刻JST DESC;

DROP TABLE IF EXISTS #SH;

-- ログフォルダーの場所を知りたいとき
SELECT SERVERPROPERTY('ErrorLogFileName') AS エラーログのパス;

-- 答え(system_health があるのに自前セッションを作る理由 3つ):
--  ① system_health の ring_buffer は容量が小さく、すぐ上書きされる。
--     event_file も既定で 4ファイル × 5MB 程度しかなく、忙しいサーバーでは数日しか残らない。
--  ② system_health はデッドロック以外(sp_server_diagnostics、重大度20以上のエラー、
--     メモリ不足、長時間の待機など)も大量に記録しており、デッドロックだけを
--     長期保存・分析する用途には向かない。
--  ③ 自前なら保持期間・ファイルサイズ・出力先ドライブを自分で設計でき、
--     STARTUP_STATE = ON にして再起動後も自動で走らせられる。

-- 後片付け
ALTER EVENT SESSION [xe_ex25_deadlock] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_ex25_deadlock] ON SERVER;
GO


-- Q11. ブロッキングを捕捉する(2〜3セッション + サーバー設定の変更)

-- (1) ★変更前の値を必ず控える
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

SELECT name, value AS 設定値, value_in_use AS 実効値, description
FROM   sys.configurations
WHERE  name = 'blocked process threshold (s)';
-- → 既定は value = 0 / value_in_use = 0(= 無効)。この値をメモしておく。

-- (2) 5秒に設定する
EXEC sp_configure 'blocked process threshold (s)', 5;
RECONFIGURE;
GO

SELECT name, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name = 'blocked process threshold (s)';   -- → 5

-- (3) セッションを作って開始する
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_blocked')
    ALTER EVENT SESSION [xe_ex25_blocked] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_blocked')
    DROP EVENT SESSION [xe_ex25_blocked] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_blocked] ON SERVER
ADD EVENT sqlserver.blocked_process_report
(
    ACTION ( sqlserver.database_name, sqlserver.client_app_name )
    WHERE  ( [sqlserver].[database_name] = N'SalesLearning' )
)
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 200 )
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

ALTER EVENT SESSION [xe_ex25_blocked] ON SERVER STATE = START;
GO

-- (4) ブロッキングを起こす
--     まず sample-db/05_workload.sql の【準備】セクションを実行して
--     dbo.WorkloadTest(1000行)を用意しておくこと。

/* ---- ここから2〜3セッション ---- */

-- 【セッションA】手順1: 05_workload.sql セクションC(ブロッカー)
--   Id 1〜10 に排他ロックを掛けたまま30秒待ち、自動で ROLLBACK する
BEGIN TRANSACTION;

UPDATE dbo.WorkloadTest
SET    Val = Val + 1000
WHERE  Id BETWEEN 1 AND 10;

PRINT N'ロックを保持中。30秒後に自動でロールバックします。';
WAITFOR DELAY '00:00:30';

ROLLBACK TRANSACTION;
SELECT @@TRANCOUNT AS 深さ;   -- 0 であること


-- 【セッションB】手順2: 05_workload.sql セクションD(ブロックされる側)
--   セクションC の実行中に流す。5秒以上待たされると blocked_process_report が発火する
SET STATISTICS TIME OFF;
DECLARE @t0 DATETIME2 = SYSDATETIME();

SELECT Id, Val, UpdatedAt
FROM   dbo.WorkloadTest
WHERE  Id BETWEEN 1 AND 10;

SELECT DATEDIFF(SECOND, @t0, SYSDATETIME()) AS 待たされた秒数;
-- → セクションC が残り何秒だったかによるが、おおむね 20〜30 秒(環境により前後する)


-- 【セッションC】手順3: 05_workload.sql セクションE(観測)
--   「今、誰が誰を待たせているか」を見る
SELECT r.session_id          AS 待っているセッション,
       r.blocking_session_id AS 待たせているセッション,
       r.status              AS 状態,
       r.wait_type           AS 待機タイプ,
       r.wait_time           AS 待機ms,
       r.wait_resource       AS 待機リソース,
       t.text                AS 実行中SQL
FROM   sys.dm_exec_requests AS r
CROSS  APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE  r.blocking_session_id <> 0;

/* ---- 2〜3セッションここまで ---- */

-- 答え:
--  blocked process threshold (s) が 0(既定)のままだと、SQL Server は
--  「ブロックされているプロセスを探して報告する」処理自体を行わないため、
--  blocked_process_report は一切発火しない。
--  設定した秒数以上ブロックされ続けたプロセスだけが、監視モニタ(既定5秒間隔)の
--  巡回時に検出されて報告される。したがって
--    ① 設定を 0 以外にする、かつ ② そのしきい値以上待たされる
--  の両方が揃わないとイベントは出ない。
--  なお小さすぎる値(1〜2秒)にすると、ブロックが続く間くり返しレポートが生成されて
--  それ自体が負荷になる。本番は 15〜30 秒から始める。


-- (5) レポートを読む
WAITFOR DELAY '00:00:06';
GO

WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_blocked' AND t.target_name = N'ring_buffer'
),
E AS
(
    SELECT x.value('@timestamp', 'datetime2')
               AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'          AS 発生時刻JST,
           x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS ブロック秒数,
           DB_NAME(x.value('(data[@name="database_id"]/value)[1]', 'int'))    AS データベース,
           x.value('(data[@name="lock_mode"]/value)[1]', 'nvarchar(30)')      AS ロックモード,
           x.query('(data[@name="blocked_process"]/value/blocked-process-report)[1]') AS レポート
    FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
)
SELECT 発生時刻JST,
       ブロック秒数,
       データベース,
       ロックモード,
       -- 待たされている側
       レポート.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int')
           AS 待機SPID,
       LTRIM(RTRIM(レポート.value('(/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')))
           AS 待機側SQL,
       レポート.value('(/blocked-process-report/blocked-process/process/@waitresource)[1]', 'nvarchar(200)')
           AS 待機リソース,
       レポート.value('(/blocked-process-report/blocked-process/process/@isolationlevel)[1]', 'nvarchar(60)')
           AS 待機側分離レベル,
       -- 待たせている側(★真犯人はこちら)
       レポート.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')
           AS ブロック元SPID,
       レポート.value('(/blocked-process-report/blocking-process/process/@status)[1]', 'nvarchar(30)')
           AS ブロック元の状態,
       LTRIM(RTRIM(レポート.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)')))
           AS ブロック元SQL,
       レポート AS 生レポートXML
FROM   E
ORDER  BY 発生時刻JST DESC;

-- 答え(ブロック元の status ごとに何を疑うか):
--  running / runnable … 実際に処理中。長いクエリが原因。
--                       インデックス不足・非SARGableな条件を疑う(18章)。
--  suspended         … ブロック元自身も何かを待っている = 連鎖ブロッキング。
--                       さらに上流(blocking_session_id をたどる)を追う。
--  sleeping          … 何も実行していないのにトランザクションを開いたまま。
--                       ほぼ確実にアプリのバグ。COMMIT 漏れ、
--                       IMPLICIT_TRANSACTIONS ON、トランザクション中の
--                       ユーザー入力待ち/外部API呼び出しを疑う(19章 第12節)。
--                       sys.dm_exec_sessions.last_request_end_time で
--                       「いつから寝ているか」を確認する(26章)。

-- (6) ★必ず実行: サーバー設定を元に戻す
EXEC sp_configure 'blocked process threshold (s)', 0;   -- (1) で控えた元の値
RECONFIGURE;
GO

SELECT name, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name = 'blocked process threshold (s)';   -- → 0 / 0 に戻っていること

EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;
GO

ALTER EVENT SESSION [xe_ex25_blocked] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_ex25_blocked] ON SERVER;
GO


-- Q12. エラーを捕捉して、生ログと集計の両方で見る

-- (1) セッションを作る(ターゲットは ring_buffer と histogram の2つ)
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_error')
    ALTER EVENT SESSION [xe_ex25_error] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_error')
    DROP EVENT SESSION [xe_ex25_error] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_error] ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.sql_text
    )
    WHERE ( [severity] >= 11                                  -- 11 未満は情報メッセージ
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )
)
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 500 ),
ADD TARGET package0.histogram
(
    SET filtering_event_name = N'sqlserver.error_reported',
        source               = N'error_number',
        source_type          = 0        -- ★0 = イベントのデータ列
)
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

ALTER EVENT SESSION [xe_ex25_error] ON SERVER STATE = START;
GO

-- 答え(source_type を 0 にする理由):
--  source_type の既定は 1(= ACTION を集計対象にする)。
--  error_number は ACTION ではなく「イベントのデータ列」なので、
--  0 を明示しないと集計対象として解決できず、histogram が何も返らない。

-- (2) わざとエラーを起こす(4種類)
BEGIN TRY  SELECT * FROM dbo.存在しない表;                  END TRY BEGIN CATCH END CATCH;   -- 208
BEGIN TRY  SELECT 1 / 0 AS ゼロ除算;                        END TRY BEGIN CATCH END CATCH;   -- 8134
BEGIN TRY  RAISERROR (N'テスト用のエラーです', 16, 1);       END TRY BEGIN CATCH END CATCH;   -- 50000
BEGIN TRY
    INSERT INTO dbo.Departments (DepartmentId, DepartmentName, Location)
    VALUES (1, N'重複', N'東京');                                                             -- 2627
END TRY BEGIN CATCH END CATCH;
GO
-- ※ TRY...CATCH で握りつぶしても、error_reported は「サーバーがエラーを報告した」
--    時点で発火するので、ちゃんと捕捉される。ここが XEvent の強み。
--    (アプリが例外を握りつぶしていても、サーバー側からは全部見える)
-- ※ 主キー違反なので dbo.Departments に行は追加されない(5行のまま)。

-- (3) 6秒待ってから読む
WAITFOR DELAY '00:00:06';
GO

-- 生ログ(ring_buffer)
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_error' AND t.target_name = N'ring_buffer'
)
SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'              AS 発生時刻JST,
       x.value('(data[@name="error_number"]/value)[1]', 'int')                AS エラー番号,
       x.value('(data[@name="severity"]/value)[1]', 'int')                    AS 重大度,
       x.value('(data[@name="state"]/value)[1]', 'int')                       AS 状態,
       x.value('(data[@name="message"]/value)[1]', 'nvarchar(max)')           AS メッセージ,
       x.value('(action[@name="session_id"]/value)[1]', 'int')                AS セッションID,
       x.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS アプリ,
       x.value('(action[@name="username"]/value)[1]', 'nvarchar(128)')        AS ログイン,
       x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')        AS 実行SQL
FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
ORDER  BY 発生時刻JST DESC;

-- 集計(histogram)
WITH H AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_error' AND t.target_name = N'histogram'
)
SELECT v.value('(value)[1]', 'int') AS エラー番号,
       v.value('@count', 'bigint')  AS 件数
FROM   H CROSS APPLY H.TargetData.nodes('/HistogramTarget/Slot') AS s(v)
ORDER  BY 件数 DESC;

-- (4) 答え:
--   208   … オブジェクト名 'dbo.存在しない表' が無効です(重大度 16)
--   8134  … 0 で除算するエラーが発生しました(重大度 16)
--   50000 … RAISERROR にメッセージ文字列を直接書いた場合の既定のエラー番号(重大度 16)
--   2627  … 制約 'PK_Departments' の PRIMARY KEY 違反(重大度 14)
--
--   本番で必ず入れるべき述語:
--     ① severity のしきい値(例: severity >= 16、または >= 17)
--        … 情報メッセージや軽微な警告で埋め尽くされるのを防ぐ。
--     ② database_name(または database_id)による対象DBの限定
--        … 他DB・システム内部のエラーを拾わない。
--     (加えて error_number による絞り込みも有効。
--      1205=デッドロック犠牲者 / 1222=ロックタイムアウト /
--      8645・8651=メモリ許可待ちタイムアウト など、目的を決めて絞る)

-- 後片付け
ALTER EVENT SESSION [xe_ex25_error] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_ex25_error] ON SERVER;
GO


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q13. event_file で永続化して、停止後にも読む
--   ★事前に C:\XE\ フォルダーを作成し、SQL Server サービスアカウントに
--     書き込み権限を与えておくこと。Linux / コンテナーなら
--     /var/opt/mssql/log/ をそのまま使える。
--     権限が無いと CREATE は成功し、START で失敗する(分かりにくいので注意)。

-- (1) 作成
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_file')
    ALTER EVENT SESSION [xe_ex25_file] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_file')
    DROP EVENT SESSION [xe_ex25_file] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_file] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION ( sqlserver.session_id, sqlserver.sql_text )
    WHERE  ( [duration] > 50000                                -- 50ms
             AND [sqlserver].[database_name] = N'SalesLearning'
             AND [sqlserver].[is_system] = 0 )
)
ADD TARGET package0.event_file
(
    SET filename           = N'C:\XE\xe_ex25_file.xel',
     -- Linux の場合: N'/var/opt/mssql/log/xe_ex25_file.xel'
        max_file_size      = 10,      -- MB
        max_rollover_files = 3
)
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

-- 答え: ディスク使用量の上限 = max_file_size × max_rollover_files = 10 MB × 3 = 30 MB。
--       本番ではこの掛け算を必ず暗算してから配置する。
--       ログドライブではなく、十分な空きのある別ドライブに置くこと。

-- (2) 開始 → 負荷 → 待つ → 停止
ALTER EVENT SESSION [xe_ex25_file] ON SERVER STATE = START;
GO

DECLARE @s DECIMAL(38,2);
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'完了';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'保留';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE ShipDate IS NULL;
GO

WAITFOR DELAY '00:00:06';
GO

ALTER EVENT SESSION [xe_ex25_file] ON SERVER STATE = STOP;   -- ★停止する
GO

-- (3) 停止したままファイルを読む
WITH F AS
(
    SELECT CAST(event_data AS XML) AS ED
    FROM   sys.fn_xe_file_target_read_file
           (
               N'C:\XE\xe_ex25_file*.xel',  -- ★ワイルドカード必須(自動サフィックスが付く)
               NULL,                         -- メタデータファイル: 2012 以降は NULL でよい
               NULL,                         -- 読み始めるファイル名
               NULL                          -- 読み始めるオフセット
           )
)
SELECT
    x.value('@timestamp', 'datetime2')
        AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'          AS 発生時刻JST,
    x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0    AS 実行時間ms,
    x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')        AS 論理読み取り,
    x.value('(data[@name="row_count"]/value)[1]', 'bigint')            AS 行数,
    x.value('(action[@name="session_id"]/value)[1]', 'int')            AS セッションID,
    x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')     AS 実行された文
FROM   F
CROSS  APPLY F.ED.nodes('/event') AS e(x)     -- ★event_file は /event から始まる
ORDER  BY 実行時間ms DESC;

-- (別解) 大きい .xel を何度も分析するなら、いったんテーブルへ取り込む
DROP TABLE IF EXISTS #XE;

SELECT CAST(event_data AS XML) AS ED
INTO   #XE
FROM   sys.fn_xe_file_target_read_file(N'C:\XE\xe_ex25_file*.xel', NULL, NULL, NULL);

SELECT COUNT(*) AS 取り込み件数 FROM #XE;
DROP TABLE IF EXISTS #XE;

-- (4) 答え:
--   ring_buffer はメモリ上のターゲットなので、STATE = STOP した瞬間に中身が破棄され、
--   さらに sys.dm_xe_sessions からセッション自体が消えるので読む手段が無くなる。
--   event_file はディスク上の .xel に書き出されているため、セッションが停止していても、
--   DROP されていても、さらには別サーバーへファイルをコピーしても読める。
--   これが「本番は event_file」と言われる理由。

-- (5) 削除 → ファイルが残っていることを確認 → OS 側で削除
DROP EVENT SESSION [xe_ex25_file] ON SERVER;
GO

-- ★DROP してもファイルは残る。まだ読めることを確認する
SELECT COUNT(*) AS まだ読める件数
FROM   sys.fn_xe_file_target_read_file(N'C:\XE\xe_ex25_file*.xel', NULL, NULL, NULL);

-- ファイルの削除は OS 側で行う(SSMS からは消せない)。
--   Windows(エクスプローラー、または管理者コマンドプロンプト):
--     del C:\XE\xe_ex25_file*.xel
--   Linux / コンテナー:
--     rm /var/opt/mssql/log/xe_ex25_file*.xel
--
-- ※セッションが動いている間はファイルがロックされているので、
--   必ず STOP / DROP してから削除すること。
-- ※どうしても T-SQL で消したい場合は xp_cmdshell が必要だが、
--   xp_cmdshell はセキュリティ上のリスクが大きいので有効化しないこと。
--   OS 側の操作で片付けるのが正解。


-- Q14. event_counter と histogram で「まず量を測る」

-- (1) 作成(★述語に duration のしきい値を付けない = 本番でやってはいけない設定)
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_count')
    ALTER EVENT SESSION [xe_ex25_count] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_count')
    DROP EVENT SESSION [xe_ex25_count] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_count] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION ( sqlserver.session_id )
    WHERE  ( [sqlserver].[database_name] = N'SalesLearning' )   -- しきい値なし
)
ADD TARGET package0.event_counter,
ADD TARGET package0.histogram
(
    SET filtering_event_name = N'sqlserver.sql_statement_completed',
        source               = N'sqlserver.session_id',
        source_type          = 1        -- ★1 = ACTION(session_id は ACTION で採っている)
)
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

ALTER EVENT SESSION [xe_ex25_count] ON SERVER STATE = START;
GO

-- (2) 別ウィンドウで 05_workload.sql のセクションA(読み取り負荷60秒)を1〜2本流す
/*
-- 【別セッション】05_workload.sql セクションA
USE SalesLearning;
SET NOCOUNT ON;
DECLARE @End DATETIME2 = DATEADD(SECOND, 60, SYSDATETIME());
DECLARE @s   DECIMAL(38,2);
WHILE SYSDATETIME() < @End
BEGIN
    SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'完了';
    SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;
END;
PRINT N'セクションA 終了';
*/

-- 20秒ほど経ったら件数を読む
WAITFOR DELAY '00:00:20';
GO

-- event_counter: 件数だけ
WITH C AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_count' AND t.target_name = N'event_counter'
)
SELECT e.value('@package', 'nvarchar(100)') AS パッケージ,
       e.value('@name', 'nvarchar(100)')    AS イベント名,
       e.value('@count', 'bigint')          AS 発火件数
FROM   C CROSS APPLY C.TargetData.nodes('/CounterTarget/Packages/Package/Event') AS n(e);

-- histogram: セッションIDごとの件数
WITH H AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_count' AND t.target_name = N'histogram'
)
SELECT v.value('(value)[1]', 'int') AS セッションID,
       v.value('@count', 'bigint')  AS 件数
FROM   H CROSS APPLY H.TargetData.nodes('/HistogramTarget/Slot') AS s(v)
ORDER  BY 件数 DESC;

-- (3) 答え(見積もり。数値は環境により大きく前後する目安):
--   セクションA を1本流すと、20秒でおよそ数千〜数万件のイベントが発火する。
--   仮に 20秒で 6,000 件だったとすると:
--     1分あたり  約 18,000 件
--     1時間あたり 約 1,080,000 件
--
--   ・ring_buffer(max_events_limit = 1000)で採っていたら
--       → 数秒で一巡して上書きされ、「直近1000件」しか残らない。
--         しかも target_data の XML は約4MBで切り捨てられ(truncated="1")、
--         CAST(... AS XML) がパースエラーになることもある。
--         つまり「調査に使える形では残らない」。
--   ・event_file で採っていたら(1イベント約500バイトと仮定)
--       → 1,080,000 件 × 500 バイト ≒ 540 MB / 時間 ≒ 13 GB / 日。
--         max_file_size × max_rollover_files を超えた分は古い世代から消えるので、
--         「思ったより短時間しか残っていない」という事故になる。
--         そもそも書き込み I/O そのものが本番の負荷になる。
--
--   → だからこそ、本番に仕掛ける前に event_counter で量を測り、
--     1分あたり数百件に収まるところまで duration のしきい値を上げるのが正しい手順。

-- (4) 答え(event_counter / histogram が軽い理由):
--   event_counter はイベントの「中身」を一切保持せずカウンタを 1 増やすだけ、
--   histogram も指定した1列の値ごとの件数しか持たない。
--   ring_buffer / event_file のように「イベント1件分のデータを組み立てて
--   メモリに積む・ディスクへ書く」処理が発生しないため、
--   メモリ消費もディスパッチ量もほぼゼロで済む。
--   ただし当然、個々のイベントの詳細は後から一切見られない。
--   「量を測る」「傾向を掴む」用途に限って使う。

-- (5) 後片付け
ALTER EVENT SESSION [xe_ex25_count] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_ex25_count] ON SERVER;
GO
-- ※セクションA は60秒で自動終了する。待たずに次へ進んでよい。


-- Q15. TRACK_CAUSALITY で因果関係を追う

-- (1) TRACK_CAUSALITY = ON で作り直す
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_ex25_slow')
    ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_ex25_slow')
    DROP EVENT SESSION [xe_ex25_slow] ON SERVER;
GO

CREATE EVENT SESSION [xe_ex25_slow] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION ( sqlserver.session_id, sqlserver.sql_text )
    WHERE  ( [duration] > 1000                                  -- 1ms
             AND [sqlserver].[database_name] = N'SalesLearning'
             AND [sqlserver].[is_system] = 0 )
),
ADD EVENT sqlserver.sql_batch_completed
(
    ACTION ( sqlserver.session_id )
    WHERE  ( [duration] > 1000
             AND [sqlserver].[database_name] = N'SalesLearning'
             AND [sqlserver].[is_system] = 0 )
)
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 1000 )
WITH
(
    MAX_MEMORY           = 8 MB,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY      = ON,          -- ★これ
    STARTUP_STATE        = OFF
);
GO

ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = START;
GO

-- (2) 1バッチの中で複数の文を実行する
DECLARE @s DECIMAL(38,2);
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'完了';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'保留';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;
GO

WAITFOR DELAY '00:00:06';
GO

-- (3) attach_activity_id を GUID とシーケンス番号に分けて表示する
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_slow' AND t.target_name = N'ring_buffer'
),
E AS
(
    SELECT x.value('@name', 'nvarchar(100)')                                   AS イベント種別,
           x.value('@timestamp', 'datetime2')                                  AS 発生時刻UTC,
           x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0     AS 実行時間ms,
           x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')      AS 実行された文,
           x.value('(action[@name="attach_activity_id"]/value)[1]', 'nvarchar(100)') AS 活動ID
    FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
)
SELECT LEFT(活動ID, CHARINDEX('-', 活動ID + '-', 30) - 1)      AS バッチGUID,
       -- 形式は "GUID-連番"。GUID は36文字なので 38文字目以降がシーケンス番号
       TRY_CAST(SUBSTRING(活動ID, 38, 20) AS INT)               AS シーケンス番号,
       イベント種別,
       実行時間ms,
       LEFT(実行された文, 80)                                    AS 文の先頭,
       発生時刻UTC AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time' AS 発生時刻JST
FROM   E
ORDER  BY バッチGUID, シーケンス番号;

-- (別解) 文字列操作を単純にするなら、GUID 部分は固定長36文字なので LEFT / SUBSTRING でよい
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_ex25_slow' AND t.target_name = N'ring_buffer'
)
SELECT LEFT(a.活動ID, 36)                          AS バッチGUID,
       TRY_CAST(SUBSTRING(a.活動ID, 38, 20) AS INT) AS シーケンス番号,
       a.イベント種別,
       LEFT(a.実行された文, 80)                     AS 文の先頭
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
CROSS  APPLY (SELECT x.value('@name', 'nvarchar(100)')                                    AS イベント種別,
                     x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')       AS 実行された文,
                     x.value('(action[@name="attach_activity_id"]/value)[1]', 'nvarchar(100)') AS 活動ID) AS a
ORDER  BY バッチGUID, シーケンス番号;

-- 確認できること:
--  ・3つの sql_statement_completed と 1つの sql_batch_completed が
--    「同じ GUID」を共有し、シーケンス番号 1, 2, 3, 4 … と並ぶ。
--  ・つまり「どの文が、どのバッチの何番目の処理だったか」が復元できる。
--  ・アプリのリクエスト1件が内部で何をしていたかを追うときに強力。

-- (4) 答え(TRACK_CAUSALITY = ON のコスト):
--   ・すべてのイベントに attach_activity_id アクションが暗黙で付与される。
--     イベント1件あたり GUID(16バイト)+ シーケンス番号が追加され、
--     イベントサイズが増える → バッファ消費・ディスパッチ量・ファイルサイズが増える。
--   ・アクションの実行コストも毎イベント発生する。
--   ・高頻度イベントを採っているセッションでは、この増分が無視できない。
--   → 「複数イベントの因果関係を追う」という明確な目的があるときだけ ON にし、
--     調査が終わったら OFF に戻す。本番の常設監視では既定の OFF のままにする。

-- (5) 後片付け
ALTER EVENT SESSION [xe_ex25_slow] ON SERVER STATE = STOP;
DROP EVENT SESSION [xe_ex25_slow] ON SERVER;
GO


-- Q16. 後片付けと棚卸し(必ず実行)

-- (1) この演習で作ったセッションが残っていないことを確認する
SELECT es.name          AS セッション名,
       es.startup_state AS 起動時に自動開始,
       CASE WHEN dm.address IS NULL THEN N'停止中' ELSE N'実行中' END AS 状態
FROM   sys.server_event_sessions AS es
LEFT   JOIN sys.dm_xe_sessions   AS dm ON dm.name = es.name
WHERE  es.name NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents')
ORDER  BY es.name;
-- → xe_ex25_ で始まるものが 0 件であること

-- 万一残っていたら、まとめて落とす(動的SQL。20章の内容)
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql
     + CASE WHEN dm.address IS NOT NULL
            THEN N'ALTER EVENT SESSION ' + QUOTENAME(es.name) + N' ON SERVER STATE = STOP;' + CHAR(13)
            ELSE N'' END
     + N'DROP EVENT SESSION ' + QUOTENAME(es.name) + N' ON SERVER;' + CHAR(13)
FROM   sys.server_event_sessions AS es
LEFT   JOIN sys.dm_xe_sessions   AS dm ON dm.name = es.name
WHERE  es.name LIKE N'xe_ex25[_]%';        -- [_] でアンダースコアをエスケープ

PRINT @sql;          -- ★まず内容を目で確認してから
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 確認
SELECT COUNT(*) AS 残っている演習用セッション数
FROM   sys.server_event_sessions
WHERE  name LIKE N'xe_ex25[_]%';   -- → 0

-- (2) サーバー設定が元に戻っていることを確認する
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

SELECT name, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN ('blocked process threshold (s)', 'show advanced options');
-- → blocked process threshold (s) は 0 / 0 であること

EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
GO

-- (3) トランザクションが残っていないことを確認する
--     ★これは「すべてのクエリウィンドウ」で実行すること
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 であること

-- (4) 本物のテーブルが元のままか確認する
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products  WHERE ProductId  = 2;   -- 2800
SELECT EmployeeId, LastName, Salary      FROM dbo.Employees WHERE EmployeeId = 3;   -- 480000
SELECT COUNT(*) AS 部署数                FROM dbo.Departments;                       -- 5

-- (5) 負荷生成用テーブルを片付ける(05_workload.sql の後片付けセクション)
DROP TABLE IF EXISTS dbo.WorkloadTest;
GO

-- (6) .xel ファイルの後始末
--     Q13 で event_file を使った場合、DROP EVENT SESSION してもファイルは残る。
--     OS 側で削除する:
--       Windows : del C:\XE\xe_ex25_file*.xel
--       Linux   : rm /var/opt/mssql/log/xe_ex25_file*.xel
--
--     残っているかどうかは、次を実行してエラーになるかで確認できる
--     (ファイルが1つも無い場合はエラー / 0行になる)。
/*
SELECT COUNT(*) AS 残存イベント数
FROM   sys.fn_xe_file_target_read_file(N'C:\XE\xe_ex25_file*.xel', NULL, NULL, NULL);
*/

PRINT N'25章 演習の後片付けが完了しました。';
GO
