/* ============================================================
   解答例 19 — トランザクションと分離レベル
   対象演習: exercises/19_transactions_isolation.md

   ★★ このファイルは「全選択して一気に実行(F5)」してはいけません ★★
   Q6 以降は 2つのセッション(SSMS のクエリウィンドウを2つ)で
   【セッションA】【セッションB】のラベルと手順番号の順に、
   該当するウィンドウへ 1ブロックずつコピーして実行してください。

   安全方針:
     - 本物のテーブル(Employees / Products / Orders)は必ず ROLLBACK で戻す。
     - COMMIT が必要な実験はグローバル一時テーブル ##IsoDemo で行う。
     - 各問の最後に @@TRANCOUNT = 0 と 分離レベル READ COMMITTED を確認する。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. @@TRANCOUNT とネストの挙動(予想 → 実行して答え合わせ)
--     予想: ① 0 / ② 1 / ③ 2 / ④ 1 / ⑤ 0
SELECT @@TRANCOUNT AS ①開始前;          -- 0

BEGIN TRAN;
SELECT @@TRANCOUNT AS ②外側BEGIN後;     -- 1

    BEGIN TRAN;
    SELECT @@TRANCOUNT AS ③内側BEGIN後; -- 2

    COMMIT;
    SELECT @@TRANCOUNT AS ④内側COMMIT後; -- 1  ← まだ何も確定していない

ROLLBACK;
SELECT @@TRANCOUNT AS ⑤ROLLBACK後;      -- 0

-- 説明:
--  ・③ の COMMIT は「何も確定していない」。SQL Server に本当のネストは無く、
--    内側の COMMIT は @@TRANCOUNT を 1 減らすだけ。実際に確定されるのは
--    @@TRANCOUNT が 1 → 0 になる、いちばん外側の COMMIT だけ。
--  ・④ の ROLLBACK は深さに関係なく「いちばん外側の BEGIN TRAN まで」一気に戻し、
--    @@TRANCOUNT を 0 にする。部分的に戻したいなら SAVE TRANSACTION を使う(Q3)。


-- Q2. 内側の COMMIT では確定しないことを実データで確認する
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
-- 実行前: 2 = 2800 / 3 = 9800

BEGIN TRAN;                                                        -- @@TRANCOUNT = 1
    UPDATE dbo.Products SET UnitPrice = 1 WHERE ProductId = 2;

    BEGIN TRAN;                                                    -- @@TRANCOUNT = 2
        UPDATE dbo.Products SET UnitPrice = 2 WHERE ProductId = 3;
    COMMIT;                                                        -- @@TRANCOUNT = 1(確定しない)

    -- トランザクションの中では両方とも変わって見える
    SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);

ROLLBACK;                                                          -- @@TRANCOUNT = 0(両方取り消し)

-- 内側で COMMIT した ProductId=3 の変更も消えている
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
SELECT @@TRANCOUNT AS 深さ;   -- 0


-- Q3. SAVE TRANSACTION で部分的に取り消す
BEGIN TRAN;

    -- ① 残したい変更: ワイヤレスマウス(2)を10%値下げ
    UPDATE dbo.Products SET UnitPrice = UnitPrice * 0.9 WHERE ProductId = 2;

    -- ② セーブポイントを打つ(@@TRANCOUNT は変わらない)
    SAVE TRANSACTION 値下げ後;

    -- ③ 取り消したい変更: メカニカルキーボード(3)の単価を 0 に
    UPDATE dbo.Products SET UnitPrice = 0 WHERE ProductId = 3;

    -- ④ セーブポイントまで戻す → ③ だけが取り消される。トランザクションは開いたまま
    ROLLBACK TRANSACTION 値下げ後;

    SELECT @@TRANCOUNT AS 深さ;   -- 1(閉じていない)
    SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
    -- → 2 は 2520(値下げが残る) / 3 は 9800(元のまま)

ROLLBACK;   -- 最後に全体を取り消す

SELECT @@TRANCOUNT AS 深さ;   -- 0
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId IN (2, 3);
-- ポイント: 名前付きの ROLLBACK TRANSACTION セーブポイント名 は「そこまで戻すだけ」で
--           トランザクションを閉じない。裸の ROLLBACK は全体の取り消し。


-- Q4. 現在の分離レベルを確認する
SELECT session_id                    AS セッションID,
       transaction_isolation_level   AS 値,
       CASE transaction_isolation_level
            WHEN 0 THEN N'未指定'
            WHEN 1 THEN N'READ UNCOMMITTED'
            WHEN 2 THEN N'READ COMMITTED'
            WHEN 3 THEN N'REPEATABLE READ'
            WHEN 4 THEN N'SERIALIZABLE'
            WHEN 5 THEN N'SNAPSHOT'
       END                           AS 分離レベル
FROM   sys.dm_exec_sessions
WHERE  session_id = @@SPID;
-- → 既定は 2 = READ COMMITTED

-- 変更してみる
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

SELECT transaction_isolation_level AS 値
FROM   sys.dm_exec_sessions
WHERE  session_id = @@SPID;         -- → 4 = SERIALIZABLE

-- (別解) DBCC でも確認できる。結果の "isolation level" 行を見る
DBCC USEROPTIONS;

-- ★ 必ず既定に戻す(戻し忘れはセッション中ずっと効き続ける)
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;


-- Q5. XACT_ABORT + TRY...CATCH + XACT_STATE() のひな形
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRAN;

        UPDATE dbo.Employees
        SET    Salary = Salary + 10000
        WHERE  DepartmentId = 2;          -- 開発部

        DECLARE @x INT = 1 / 0;           -- わざとエラーを起こす(0 除算)

    COMMIT;                               -- ここには到達しない
END TRY
BEGIN CATCH
    -- -1 = アクティブだがコミット不能(doomed)→ ROLLBACK するしかない
    IF XACT_STATE() = -1
        ROLLBACK;
    -- 1 = まだコミット可能。学習用なので取り消しておく
    ELSE IF XACT_STATE() = 1
        ROLLBACK;
    --  0 = トランザクションが無い → 何もしない(ROLLBACK するとエラーになる)

    SELECT ERROR_NUMBER()  AS エラー番号,     -- 8134
           ERROR_MESSAGE() AS メッセージ,     -- 0 で除算しようとしました。
           XACT_STATE()    AS 状態;          -- 0(すでにロールバック済み)

    THROW;   -- 呼び出し元へ再送出(SQL Server 2012+)
END CATCH;

-- CATCH で THROW しているのでメッセージが出るが、トランザクションは残っていない
SELECT @@TRANCOUNT AS 深さ;   -- 0
SET XACT_ABORT OFF;

-- 給与が元に戻っていることを確認
SELECT EmployeeId, LastName, Salary FROM dbo.Employees WHERE DepartmentId = 2;


------------------------------------------------------------
-- 応用(ここから 2セッション)
------------------------------------------------------------

/* -----------------------------------------------------------
   準備: 実験用のグローバル一時テーブルを作る
   ----------------------------------------------------------- */

-- 【セッションA】手順0
SELECT EmployeeId, LastName, FirstName, DepartmentId, Salary
INTO   ##IsoDemo
FROM   dbo.Employees;

SELECT @@SPID AS セッションAのSPID;
SELECT * FROM ##IsoDemo ORDER BY EmployeeId;

-- 【セッションB】手順0'(別ウィンドウで実行。他セッションからも見えることを確認)
SELECT @@SPID AS セッションBのSPID;
SELECT * FROM ##IsoDemo ORDER BY EmployeeId;


-- Q6. ダーティリードを再現する ------------------------------

-- 【セッションA】手順1: 更新するが COMMIT しない
BEGIN TRAN;
UPDATE ##IsoDemo SET Salary = 9999999 WHERE EmployeeId = 3;
-- ここで止める

-- 【セッションB】手順2: READ UNCOMMITTED なら未コミットの値が読めてしまう
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT EmployeeId, LastName, Salary FROM ##IsoDemo WHERE EmployeeId = 3;
-- → 9999999(ダーティリード)。ブロックもされない

-- 【セッションA】手順3: 取り消す
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0

-- 【セッションB】手順4: もう一度読むと元の値
SELECT EmployeeId, LastName, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 480000
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- ★ 既定に戻す

-- 説明: セッションBが読んだ 9999999 は、結局 ROLLBACK されて
--       「データベース上に一度も存在したことがない値」。
--       その値で集計・判断・出力をしてしまうと、後から辻褄が合わない。


-- Q7. READ COMMITTED ではブロックされる(ブロッキングの観察) --

-- 【セッションA】手順1: 排他ロックを握ったまま止める
BEGIN TRAN;
UPDATE ##IsoDemo SET Salary = 9999999 WHERE EmployeeId = 3;

-- 【セッションB】手順2: 既定の分離レベルで読む → 返ってこない(ブロックされる)
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT EmployeeId, LastName, Salary FROM ##IsoDemo WHERE EmployeeId = 3;
-- 実行したまま放置して、セッションC で観察する

-- 【セッションC】手順3-1: 古典的な確認方法。BlkBy 列に「待たせている側のSPID」が出る
EXEC sp_who2;

-- 【セッションC】手順3-2: DMV のほうが情報量が多い
SELECT r.session_id          AS 待っているセッション,
       r.blocking_session_id AS 待たせているセッション,
       r.wait_type           AS 待機種別,          -- LCK_M_S など
       r.wait_time           AS 待機ミリ秒,
       r.wait_resource       AS 待機リソース,
       t.text                AS 実行中のSQL
FROM   sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE  r.blocking_session_id <> 0;

-- 【セッションC】手順3-3: 実際に握られているロックを見る
--   ##IsoDemo は tempdb 上のオブジェクトなので、resource_database_id は tempdb になる。
--   sys.partitions は「現在のデータベース」のものしか見えないため、
--   オブジェクト名まで出したいときは USE tempdb; に切り替えて実行する
--   (dbo.Products で試す場合は SalesLearning のままでよい)。
SELECT l.request_session_id     AS セッションID,
       l.resource_type          AS リソース種別,   -- OBJECT / PAGE / KEY / RID
       l.request_mode           AS ロックモード,   -- X / S / IX / IS / U
       l.request_status         AS 状態,          -- GRANT(獲得済) / WAIT(待機中)
       DB_NAME(l.resource_database_id) AS データベース,
       OBJECT_NAME(p.object_id, l.resource_database_id) AS オブジェクト
FROM   sys.dm_tran_locks AS l
LEFT   JOIN sys.partitions AS p
       ON p.hobt_id = l.resource_associated_entity_id
WHERE  l.request_session_id <> @@SPID
ORDER  BY l.request_session_id, l.request_status DESC, l.resource_type;
-- → セッションA が X / IX ロックを GRANT で保持し、
--    セッションB の S ロック要求が WAIT になっているのが見える

-- 【セッションA】手順4: 解放する
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0
-- → セッションB の SELECT が即座に完了する(値は 480000)

-- ポイント: ブロッキングは「エラーにならず、ただ待つ」。
--           いつかは解けるので、デッドロック(永久に解けない)とは別物。


-- Q8. ノンリピータブルリード ---------------------------------

-- 《前半: READ COMMITTED では起こる》

-- 【セッションA】手順1: 1回目の読み取り
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
BEGIN TRAN;
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 480000

-- 【セッションB】手順2: 更新して確定させる
BEGIN TRAN;
UPDATE ##IsoDemo SET Salary = 500000 WHERE EmployeeId = 3;
COMMIT;

-- 【セッションA】手順3: 同じトランザクション内で2回目の読み取り
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 500000(値が変わった)
ROLLBACK;
-- 同一トランザクション内で「合計 → 内訳」の順に読むと、両者が食い違う形で表面化する

-- 《後半: REPEATABLE READ なら防げる》

-- 【セッションA】手順4
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRAN;
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- 1回目 → 500000
-- 読んだ行の共有ロックをトランザクション終了まで保持する

-- 【セッションB】手順5: 更新しようとするとブロックされる
UPDATE ##IsoDemo SET Salary = 700000 WHERE EmployeeId = 3;
-- → 実行中のまま止まる

-- 【セッションA】手順6: 何度読んでも同じ値。終わったら解放
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 500000 のまま
ROLLBACK;                                          -- ← セッションB のブロックが解ける
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;    -- ★ 既定に戻す
SELECT @@TRANCOUNT AS 深さ;   -- 0

-- 【セッションB】手順7: 手順5 の UPDATE は自動コミットなので、値を元に戻す
UPDATE ##IsoDemo SET Salary = 480000 WHERE EmployeeId = 3;
SELECT EmployeeId, Salary FROM ##IsoDemo WHERE EmployeeId = 3;   -- → 480000
SELECT @@TRANCOUNT AS 深さ;   -- 0


-- Q9. ファントムリード ---------------------------------------

-- 《前半: REPEATABLE READ でも防げない》

-- 【セッションA】手順1
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRAN;
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 4

-- 【セッションB】手順2: 条件に合う「新しい行」を追加(ブロックされずに成功する)
INSERT INTO ##IsoDemo (EmployeeId, LastName, FirstName, DepartmentId, Salary)
VALUES (14, N'新井', N'翔太', 1, 400000);

-- 【セッションA】手順3: 同じ条件でもう一度数える
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5(幻の行)
ROLLBACK;

-- 《後半: SERIALIZABLE なら防げる》

-- 【セッションA】手順4
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRAN;
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5

-- 【セッションB】手順5: INSERT 自体がブロックされる
INSERT INTO ##IsoDemo (EmployeeId, LastName, FirstName, DepartmentId, Salary)
VALUES (15, N'岡田', N'亮', 1, 390000);
-- → 実行中のまま止まる

-- 【セッションA】手順6: 何度数えても同じ。終わったら解放
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 5
ROLLBACK;                                          -- ← セッションB のブロックが解ける
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;    -- ★ 既定に戻す
SELECT @@TRANCOUNT AS 深さ;   -- 0

-- 【セッションB】手順7: 追加した行を消して元に戻す
DELETE FROM ##IsoDemo WHERE EmployeeId IN (14, 15);
SELECT COUNT(*) AS 営業部人数 FROM ##IsoDemo WHERE DepartmentId = 1;   -- → 4

-- 説明:
--  ・REPEATABLE READ が守るのは「すでに読んだ行」だけ。
--    まだ存在しない行にはロックの掛けようがないので、INSERT を止められない。
--  ・SERIALIZABLE は WHERE 条件に合致する「キーの範囲」そのものにロック
--    (キー範囲ロック)を掛けるため、その範囲への INSERT がブロックされる。
--    代償として同時実行性は大きく下がり、デッドロックも増える。


-- Q10. NOLOCK の実害(記述問題)-------------------------------
--
-- 1. WITH (NOLOCK) は、そのテーブルの読み取りを事実上 READ UNCOMMITTED にする
--    (= WITH (READUNCOMMITTED) と同義)。共有ロックを取らない。
--
-- 2. ダーティリード以外に起こり得る問題(2つ):
--    (a) 行の重複読み取り
--        スキャン中に他セッションの更新でページ分割/行移動が起きると、
--        まだ読んでいない位置へ移動した行を「もう一度」読んでしまう。
--        → 上のクエリでは同じ明細を二重に足し込み、売上合計が過大になる。
--    (b) 行の読み飛ばし
--        逆に、まだ読んでいない行が「読み終えた位置」へ移動すると、
--        その行は結果に一度も現れない。
--        → 売上合計が過小になる。
--    (おまけ) エラー 601「NOLOCK が指定されているため、データ移動により
--             スキャンを続行できませんでした」でクエリ自体が失敗することもある。
--
-- 3. (a)(b) は例外が出ず、結果セットも普通に返るため、誰も異常に気づかない。
--    「たまに合計が合わない」という再現困難な障害になり、
--    しかも高負荷時(=同時更新が多いとき)ほど起きやすい。
--
-- 4. NOLOCK を使わずに「ブロックされない」を達成する方法:
--    (1) READ_COMMITTED_SNAPSHOT(RCSI)を ON にする
--        → 読み手が共有ロックを取らなくなり、正しい(コミット済みの)値を読める。
--    (2) 適切なインデックスを張る(docs/18_indexes_execution_plans.md)
--        → 走査行数が減り、取るロックも保持時間も激減する。
--    (3) トランザクションを短くする / 大量更新はバッチ分割する
--        → そもそも長時間ロックを握らない。
--    (4) 分析・レポート用途なら読み取り専用レプリカや別DBへ分離する。


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q11. デッドロックを意図的に起こす -------------------------

-- 【セッションA】手順1: Employees をロック(値は変えず、ロックだけ取る)
BEGIN TRAN;
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;

-- 【セッションB】手順2: Products をロック(A とは逆の順序)
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;

-- 【セッションA】手順3: 次に Products が欲しい → B に待たされる
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;

-- 【セッションB】手順4: 次に Employees が欲しい → A に待たされる = デッドロック成立
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;

/* 数秒後、どちらか一方に次のエラーが出る:

   メッセージ 1205、レベル 13、状態 45
   トランザクション (プロセス ID nn) が別のプロセスとロック リソースでデッドロック状態に
   なったため、このトランザクションはデッドロックの対象として選択されました。
   トランザクションを再実行してください。

   ・エラー番号は 1205。
   ・犠牲者(deadlock victim)に選ばれた側は「自動的に完全ロールバック」される。
     → 犠牲者側で SELECT @@TRANCOUNT すると 0 になっている(自分では何もしていないのに)。
   ・生き残った側は何事もなかったように続行しており、@@TRANCOUNT は 1 のまま。
   ・犠牲者は基本的に「ロールバックのコストが低いほう」が選ばれる。
     SET DEADLOCK_PRIORITY LOW / HIGH で明示的に指示することもできる。
*/

-- 【セッションA】【セッションB】手順5: 両方で必ず後片付け
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 を確認

-- 手順6: system_health からデッドロックレポート(XML)を取り出す
--        SSMS で結果の XML をクリックするとデッドロックグラフの図が開く
SELECT CAST(xet.target_data AS XML) AS レポート
FROM   sys.dm_xe_session_targets AS xet
JOIN   sys.dm_xe_sessions        AS xe ON xe.address = xet.event_session_address
WHERE  xe.name        = N'system_health'
  AND  xet.target_name = N'ring_buffer';

-- (別解) デッドロック要素だけを取り出す
;WITH RB AS (
    SELECT CAST(xet.target_data AS XML) AS x
    FROM   sys.dm_xe_session_targets AS xet
    JOIN   sys.dm_xe_sessions        AS xe ON xe.address = xet.event_session_address
    WHERE  xe.name = N'system_health' AND xet.target_name = N'ring_buffer'
)
SELECT n.value(N'(@timestamp)[1]', N'DATETIME2')        AS 発生時刻,
       n.query(N'.')                                    AS デッドロックXML
FROM   RB
CROSS  APPLY RB.x.nodes(N'//event[@name="xml_deadlock_report"]') AS q(n);

-- 書き直し方:
--   両方の処理で「必ず dbo.Employees → dbo.Products の順に触る」と決めれば、
--   後から来たほうは最初のリソースで待つだけになり、待ち合いが成立しない。
--   = アクセス順序の統一。これがデッドロック対策として最も効果が大きい。
--   加えて、トランザクションを短くする / 適切なインデックスで走査行を減らす /
--   エラー 1205 を捕まえてリトライする、を組み合わせる。

-- リトライのひな形
DECLARE @試行 INT = 0;

WHILE @試行 < 3
BEGIN
    BEGIN TRY
        SET @試行 = @試行 + 1;

        BEGIN TRAN;
            -- ★ アクセス順序を統一する(Employees → Products)
            UPDATE dbo.Employees SET Salary    = Salary    WHERE EmployeeId = 3;
            UPDATE dbo.Products  SET UnitPrice = UnitPrice WHERE ProductId  = 2;
        ROLLBACK;   -- 学習用(本番は COMMIT)

        BREAK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        IF ERROR_NUMBER() = 1205 AND @試行 < 3
            CONTINUE;   -- デッドロックならリトライ
        ELSE
            THROW;
    END CATCH
END

SELECT @@TRANCOUNT AS 深さ;   -- 0


-- Q12. SNAPSHOT 分離で読み手がブロックされないことを確認 -----

-- 手順0: データベースオプションを有効にする(どのセッションで実行してもよい)
ALTER DATABASE SalesLearning SET ALLOW_SNAPSHOT_ISOLATION ON;

SELECT name,
       snapshot_isolation_state_desc  AS SNAPSHOT設定,
       is_read_committed_snapshot_on  AS RCSI設定
FROM   sys.databases
WHERE  name = N'SalesLearning';

-- 【セッションA】手順1: 更新して COMMIT しない
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = 9999 WHERE ProductId = 2;

-- 【セッションB】手順2: 既定(READ COMMITTED)ではブロックされる
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
-- → 返ってこない。SSMS の「実行の取り消し」でキャンセルする

-- 【セッションB】手順3: SNAPSHOT なら待たされずに変更前の値が返る
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
SELECT ProductId, ProductName, UnitPrice FROM dbo.Products WHERE ProductId = 2;
-- → 即座に 2800(トランザクション開始時点のスナップショット)
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- ★ 既定に戻す
SELECT @@TRANCOUNT AS 深さ;   -- 0

-- 【セッションA】手順4: 後片付け
ROLLBACK;
SELECT @@TRANCOUNT AS 深さ;   -- 0

-- 手順5: 設定を戻す
ALTER DATABASE SalesLearning SET ALLOW_SNAPSHOT_ISOLATION OFF;

-- 説明:
--  ・SNAPSHOT が返した 2800 は「トランザクション開始時点で確定していた値」であり、
--    tempdb のバージョンストアに保存された行バージョンから読んでいる。
--    未コミットの 9999 を読んだわけではないので、ダーティリードではない。
--    しかも共有ロックを取らないので、書き手をブロックせず、書き手にブロックもされない。
--  ・アプリ側で対処が必要なエラー: 3960(更新競合)
--    「Snapshot isolation transaction aborted due to update conflict.」
--    SNAPSHOT トランザクションが読んだ行を他セッションが先にコミットして書き換えていると、
--    こちらの UPDATE が失敗する。捕まえてリトライする設計が必要。
--  ・その他の代償: tempdb のバージョンストア消費。長時間開いたトランザクションがあると肥大化する。


-- Q13. 分離レベル対応表(○ = 防ぐ / × = 起こる)---------------
--
-- | 分離レベル                 | ダーティリード | ノンリピータブルリード | ファントムリード |
-- |----------------------------|----------------|------------------------|------------------|
-- | READ UNCOMMITTED           | ×              | ×                      | ×                |
-- | READ COMMITTED(既定)      | ○              | ×                      | ×                |
-- | REPEATABLE READ            | ○              | ○                      | ×                |
-- | SERIALIZABLE               | ○              | ○                      | ○                |
-- | SNAPSHOT                   | ○              | ○                      | ○                |
-- | READ COMMITTED SNAPSHOT    | ○              | ×                      | ×                |
--
-- 理由の要点:
--  ・READ UNCOMMITTED は共有ロックを取らない → 何も防げない。
--  ・READ COMMITTED は「文の実行中だけ」共有ロックを保持 → 未コミットは読まないが、
--    文と文の間に他セッションがコミットすれば値も行数も変わる。
--  ・REPEATABLE READ は読んだ行の共有ロックをトランザクション終了まで保持 →
--    既存行は固定できるが、新しい行の INSERT は止められない(ファントム)。
--  ・SERIALIZABLE はキー範囲ロックで「条件の範囲」ごと固める → ファントムも防ぐ。
--  ・SNAPSHOT / RCSI はロックではなく行バージョン管理。読み手はブロックされない。
--
-- SNAPSHOT と READ COMMITTED SNAPSHOT の違い(見えるデータの基準時点):
--   SNAPSHOT は「トランザクション開始時点」のスナップショットを最後まで見続けるのに対し、
--   RCSI は「各ステートメント開始時点」のスナップショットを見るため、
--   文が変われば他セッションのコミットが見え、ノンリピータブルリードとファントムは起こる。


-- Q14. 後片付け(必ず実行)-----------------------------------

-- ① すべてのセッションで、開いているトランザクションが無いことを確認
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 深さ = 0

-- ② すべてのセッションで分離レベルを既定に戻す
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET XACT_ABORT OFF;
SET IMPLICIT_TRANSACTIONS OFF;

-- ③ 実験用のグローバル一時テーブルを破棄
IF OBJECT_ID(N'tempdb..##IsoDemo') IS NOT NULL
    DROP TABLE ##IsoDemo;

-- ④ データベースオプションを OFF に戻す(有効にした場合のみ)
ALTER DATABASE SalesLearning SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE SalesLearning SET ALLOW_SNAPSHOT_ISOLATION OFF;

SELECT name,
       snapshot_isolation_state_desc AS SNAPSHOT設定,
       is_read_committed_snapshot_on AS RCSI設定
FROM   sys.databases
WHERE  name = N'SalesLearning';
-- → OFF / 0 であること

-- ⑤ 本物のテーブルが元の値のままであることを確認
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
WHERE  ProductId IN (2, 3);          -- → 2 = 2800 / 3 = 9800

SELECT EmployeeId, LastName, FirstName, Salary
FROM   dbo.Employees
WHERE  EmployeeId = 3;               -- → 480000

-- 念のため、開きっぱなしのトランザクションが他に残っていないかも確認しておく
SELECT st.session_id            AS セッションID,
       at.name                  AS 名前,
       at.transaction_begin_time AS 開始時刻
FROM   sys.dm_tran_session_transactions AS st
JOIN   sys.dm_tran_active_transactions  AS at ON at.transaction_id = st.transaction_id;
-- → 行が返らなければ OK
