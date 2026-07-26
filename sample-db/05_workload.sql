/* ============================================================
   負荷生成スクリプト: SalesLearning
   目的 : 待機統計・ブロッキング・デッドロックを「実際に発生させて」観測する
          (トピック23 待機統計 / 25 拡張イベント / 26 DMV / 19 分離レベル)
   前提 : 01 / 02 / 03(OrdersBig) を実行済みであること

   ★なぜ必要か:
     待機統計は「複数のセッションが同時に動いている」ときにしか溜まりません。
     1人で1つずつクエリを流しても、本番で見えるような待機は再現できません。

   ★安全設計:
     - すべてのループに**時間制限**があり、放置しても自動で止まります。
     - 書き込みは専用テーブル dbo.WorkloadTest だけを対象にします。
       既存の業務テーブル(Orders 等)は一切変更しません。
     - 読み取り負荷は dbo.OrdersBig を SELECT するだけです。
   ============================================================ */

USE SalesLearning;
GO

/* ============================================================
   【準備】最初に1回だけ実行する
   ============================================================ */
SET NOCOUNT ON;

DROP TABLE IF EXISTS dbo.WorkloadTest;

CREATE TABLE dbo.WorkloadTest
(
    Id      INT           NOT NULL CONSTRAINT PK_WorkloadTest PRIMARY KEY,
    Val     INT           NOT NULL,
    Payload NVARCHAR(200) NOT NULL,
    UpdatedAt DATETIME2   NOT NULL CONSTRAINT DF_WorkloadTest_UpdatedAt DEFAULT SYSDATETIME()
);

INSERT INTO dbo.WorkloadTest (Id, Val, Payload)
SELECT TOP (1000)
       ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       0,
       REPLICATE(N'x', 100)
FROM   sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

PRINT N'準備完了: dbo.WorkloadTest (1000行) を作成しました。';
GO


/* ============================================================
   【使い方】

   SSMS でクエリウィンドウを複数開き、下のセクションを
   *別々のウィンドウ(セッション)* で、ほぼ同時に実行します。

     ウィンドウ1 → セクションA (読み取り負荷)
     ウィンドウ2 → セクションA (同じものをもう1つ流すと負荷が上がる)
     ウィンドウ3 → セクションB (書き込み負荷)
     ウィンドウ4 → セクションE (観測用。何が待っているかを見る)

   ブロッキングを見たいときは C と D を使います。
   ============================================================ */


/* ------------------------------------------------------------
   セクションA: 読み取り負荷(既定60秒)
     → PAGEIOLATCH_SH(ディスク読み)、CXPACKET(並列)、
       SOS_SCHEDULER_YIELD(CPU譲渡) などが溜まる
   ------------------------------------------------------------ */
/*
USE SalesLearning;
SET NOCOUNT ON;
DECLARE @End DATETIME2 = DATEADD(SECOND, 60, SYSDATETIME());
DECLARE @s   DECIMAL(38,2);

WHILE SYSDATETIME() < @End
BEGIN
    -- インデックスが無いので大きなスキャンになる(それが狙い)
    SELECT @s = SUM(Amount)
    FROM   dbo.OrdersBig
    WHERE  Status = N'完了';

    SELECT @s = SUM(Amount)
    FROM   dbo.OrdersBig
    WHERE  YEAR(OrderDate) = 2020;      -- わざと SARGable でない書き方
END;
PRINT N'セクションA 終了';
*/


/* ------------------------------------------------------------
   セクションB: 書き込み負荷(既定60秒)
     → WRITELOG(ログ書き込み待ち)、LCK_M_U/LCK_M_X(ロック待ち)が溜まる
     ※ dbo.WorkloadTest だけを更新します
   ------------------------------------------------------------ */
/*
USE SalesLearning;
SET NOCOUNT ON;
DECLARE @End DATETIME2 = DATEADD(SECOND, 60, SYSDATETIME());
DECLARE @i   INT = 1;

WHILE SYSDATETIME() < @End
BEGIN
    UPDATE dbo.WorkloadTest
    SET    Val = Val + 1,
           UpdatedAt = SYSDATETIME()
    WHERE  Id = (@i % 1000) + 1;

    SET @i += 1;
END;
PRINT N'セクションB 終了';
*/


/* ------------------------------------------------------------
   セクションC: ブロッカー(ロックを30秒間わざと保持する)
     → これを実行してから、別セッションで D を実行するとブロックされる
     ※ 必ず ROLLBACK で終わるので、データは元に戻ります
   ------------------------------------------------------------ */
/*
USE SalesLearning;
BEGIN TRANSACTION;

UPDATE dbo.WorkloadTest
SET    Val = Val + 1000
WHERE  Id BETWEEN 1 AND 10;          -- この10行に排他ロックを掛けたまま待つ

PRINT N'ロックを保持中。30秒後に自動でロールバックします。';
WAITFOR DELAY '00:00:30';

ROLLBACK TRANSACTION;
PRINT N'セクションC 終了(ロールバック済み)';
*/


/* ------------------------------------------------------------
   セクションD: ブロックされる側
     → セクションC の実行中にこれを流すと、待たされる(LCK_M_S)
   ------------------------------------------------------------ */
/*
USE SalesLearning;
SELECT Id, Val, UpdatedAt
FROM   dbo.WorkloadTest
WHERE  Id BETWEEN 1 AND 10;
*/


/* ------------------------------------------------------------
   セクションE: 観測用(いつでも実行してよい)
     → 「今、誰が何を待っているか」を見る
   ------------------------------------------------------------ */
/*
USE SalesLearning;

-- 実行中で待たされているリクエスト
SELECT r.session_id        AS セッション,
       r.status            AS 状態,
       r.wait_type         AS 待機タイプ,
       r.wait_time         AS 待機ms,
       r.blocking_session_id AS ブロック元,
       t.text              AS 実行中SQL
FROM   sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE  r.session_id <> @@SPID
  AND  r.session_id > 50;

-- 現在保持されているロック(ブロッキング調査用)
SELECT l.request_session_id AS セッション,
       l.resource_type      AS リソース種別,
       l.request_mode       AS ロックモード,
       l.request_status     AS 状態,
       OBJECT_NAME(p.object_id) AS オブジェクト
FROM   sys.dm_tran_locks AS l
LEFT   JOIN sys.partitions AS p
       ON  l.resource_associated_entity_id = p.hobt_id
WHERE  l.request_session_id <> @@SPID
  AND  l.resource_type <> 'DATABASE';
*/


/* ============================================================
   【後片付け】実験が終わったら実行する
   ============================================================ */
/*
USE SalesLearning;

-- 放置されたトランザクションが無いか確認(0 であること)
SELECT @@TRANCOUNT AS 未完了トランザクション数;

DROP TABLE IF EXISTS dbo.WorkloadTest;
PRINT N'後片付け完了';
*/
