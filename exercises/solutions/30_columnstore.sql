/* ============================================================
   解答例 30 — 列ストアインデックスとバッチモード
   対象演習: exercises/30_columnstore.md

   前提 : sample-db/04_analytics_data.sql を実行済み
          (dbo.SalesFact = 1000万行・列ストア未作成)
          Q13 のみ sample-db/03_bulk_data.sql (dbo.OrdersBig = 100万行) も使う

   注意 : Q1 は 1000万行のコピーと CCI 構築です。
          合計 2〜6 分・数百MB のディスクを消費します。
          ★ 最後に Q14 の後片付けまで必ず実行してください。

   計測値はすべて「環境により前後する目安」です。
   大事なのは絶対値ではなく「桁がいくつ変わったか」です。
   ============================================================ */
USE SalesLearning;
GO

SET NOCOUNT ON;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. dbo.SalesFact を dbo.SalesFactCS にコピーし、CCI を作る
--
--     条件① SaleId 順に並べて入れる
--       → SaleDate は SaleId に比例しているので、日付順に格納されることになる。
--         これでロウグループごとの SaleDate の範囲が分かれ、セグメント除外が効く(Q7/Q8)。
--     条件② CCI の構築は MAXDOP = 1
--       → 並列構築するとスレッドごとに中途半端なロウグループができ、min/max も重なる。
--         1 スレッドなら先頭から 1,048,576 行ずつ綺麗に詰まる(Q5)。

DROP TABLE IF EXISTS dbo.SalesFactCS;
GO

-- ① 行ストアのヒープとしてコピー(SELECT INTO は最小ログ記録が効くので速い)
SELECT SaleId, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
       Quantity, UnitPrice, Discount, Amount
INTO   dbo.SalesFactCS
FROM   dbo.SalesFact
ORDER  BY SaleId;                 -- ★ 条件①
GO

-- ② クラスター化列ストアインデックスを作る
CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesFactCS
    ON dbo.SalesFactCS
    WITH (MAXDOP = 1);            -- ★ 条件②
GO

-- 行数が一致していることを確認(どちらも 10000000)
SELECT (SELECT COUNT_BIG(*) FROM dbo.SalesFact)   AS 行ストア行数,
       (SELECT COUNT_BIG(*) FROM dbo.SalesFactCS) AS 列ストア行数;
GO


-- Q2. 行ストア(dbo.SalesFact)で集計する ← Before の基準値
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT YEAR(SaleDate) AS 年, RegionId AS 地域,
       SUM(Amount) AS 売上合計, COUNT_BIG(*) AS 件数
FROM   dbo.SalesFact
GROUP  BY YEAR(SaleDate), RegionId
ORDER  BY 年, 地域;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
--  典型的な出力(目安):
--    論理読み取り数     : 60,000〜80,000
--    LOB 論理読み取り数 : 0
--    CPU 時間           : 10,000〜40,000 ミリ秒
--    実際の実行モード   : Row
--                         (SQL Server 2019+ かつ互換性レベル 150 以上なら Batch のこともある。
--                          その場合でも I/O は減らない。Q12 参照)


-- Q3. 列ストア(dbo.SalesFactCS)で同じ集計をする ← テーブル名以外は 1 文字も同じ
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT YEAR(SaleDate) AS 年, RegionId AS 地域,
       SUM(Amount) AS 売上合計, COUNT_BIG(*) AS 件数
FROM   dbo.SalesFactCS
GROUP  BY YEAR(SaleDate), RegionId
ORDER  BY 年, 地域;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
--  典型的な出力(目安):
--    論理読み取り数     : 0        ← ここに騙されないこと
--    LOB 論理読み取り数 : 3,000〜8,000
--    CPU 時間           : 500〜3,000 ミリ秒
--    実際の実行モード   : Batch
--
--  Q3-1. 何倍の差か
--    I/O  : 71,000 → 5,000 前後 = おおむね 10〜20倍
--    CPU  : 24,000ms → 900ms 前後 = おおむね 10〜40倍
--    差の内訳は「必要な列だけ読む(10列→3列)」×「圧縮」×「バッチモード」の掛け算。
--    このクエリが使う列は SaleDate / RegionId / Amount の 3 列だけ。
--    行ストアは使わない 7 列も一緒にページから読まされている。
--
--  Q3-2. 論理読み取り数が 0 なのはなぜか
--    列ストアのセグメントは内部的に LOB として格納されるため、
--    I/O は「論理読み取り数」ではなく ★「LOB 論理読み取り数」★ に計上される。
--    → 比較するときは
--         行ストアの「論理読み取り数」 ↔ 列ストアの「LOB 論理読み取り数」
--       を突き合わせる。「論理読み取り数 0 = I/O ゼロ」ではない。


-- Q4. 行ストア版と列ストア版のサイズ比較
SELECT OBJECT_NAME(p.object_id)              AS テーブル,
       i.type_desc                           AS 種別,
       SUM(ps.used_page_count) * 8 / 1024    AS 使用MB,
       SUM(ps.row_count)                     AS 行数
FROM   sys.dm_db_partition_stats AS ps
JOIN   sys.partitions AS p
       ON  p.partition_id = ps.partition_id
JOIN   sys.indexes AS i
       ON  i.object_id = p.object_id
       AND i.index_id  = p.index_id
WHERE  p.object_id IN (OBJECT_ID('dbo.SalesFact'), OBJECT_ID('dbo.SalesFactCS'))
GROUP  BY p.object_id, i.type_desc
ORDER  BY テーブル;
GO
--  目安: 行ストア 500〜700MB → 列ストア 50〜120MB(おおむね 1/5〜1/10)
--  同じ列の値は型も傾向もそろっているため、ディクショナリ化・RLE・bit-packing が
--  非常によく効く。サイズが減ると物理読み取りも減り、バッファプールにも載りやすくなる。


-- Q5. ロウグループの一覧(sys.dm_db_column_store_row_group_physical_stats は 2016+)
SELECT rg.row_group_id                                   AS ロウグループ,
       rg.state_desc                                     AS 状態,
       rg.total_rows                                     AS 総行数,
       rg.deleted_rows                                   AS 削除済み行数,
       rg.size_in_bytes / 1024 / 1024                    AS サイズMB,
       rg.trim_reason_desc                               AS 打ち切り理由,
       rg.transition_to_compressed_state_desc            AS 圧縮経路
FROM   sys.dm_db_column_store_row_group_physical_stats AS rg
WHERE  rg.object_id = OBJECT_ID('dbo.SalesFactCS')
ORDER  BY rg.row_group_id;
GO
--  Q5-1. ロウグループ数
--        10,000,000 ÷ 1,048,576 = 9.54 → ★ 10 個 ★(0〜9)
--        MAXDOP = 1 で構築したので、この計算どおりになる。
--        並列構築していたら 15〜20 個の中途半端なロウグループができていたはず。
--
--  Q5-2. state_desc は全部 COMPRESSED。
--        CCI をゼロから構築したので、デルタストアを経由していない。
--
--  Q5-3. trim_reason_desc
--        ロウグループ 0〜8 : NO_TRIM            … 1,048,576 行ちょうど。理想の状態
--        ロウグループ 9    : RESIDUAL_ROW_GROUP … 最後の端数(約 563,000 行)。正常
--        ここに BULKLOAD や MEMORY_LIMITATION が並んでいたら、
--        ロード方法かメモリに問題があるというサイン。


------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q6. 読む列の数と I/O の関係
SET STATISTICS IO ON;

-- ① 1 列だけ(Amount)
SELECT SUM(Amount) AS 売上合計
FROM   dbo.SalesFactCS;

-- ② 全 10 列(TOP 100 でも全セグメントを開く必要がある)
SELECT TOP (100) SaleId, SaleDate, CustomerId, ProductId, EmployeeId,
                 RegionId, Quantity, UnitPrice, Discount, Amount
FROM   dbo.SalesFactCS;

SET STATISTICS IO OFF;
GO
--  ① LOB 論理読み取り数 : 1,000〜3,000 前後(Amount 列の 10 セグメントだけ)
--  ② ①より明確に多い。列数に比例して増える。
--
--  説明:
--    列ストアの読み取り単位は「セグメント = 1列 × 1ロウグループ」。
--    1 行を組み立てるには、その行が属するロウグループの ★全列のセグメント★ を
--    開いて突き合わせる必要がある。
--    したがって列ストアでは「SELECT に書いた列の数 = そのまま I/O 量」になる。
--    行ストアでは 1 ページに全列が載っているので、列を減らしても I/O はあまり減らない。
--    → 「SELECT * を避けよ」(01章)の効果が、列ストアでは最大化される。


-- Q7. セグメント除外(segment elimination)の効き具合を測る
SET STATISTICS IO ON;

-- ① 日付で絞る → 除外が効く
SELECT SUM(Amount) AS 売上合計_2024
FROM   dbo.SalesFactCS
WHERE  SaleDate >= '2024-01-01' AND SaleDate < '2025-01-01';

-- ② 顧客で絞る → 除外が効かない
SELECT SUM(Amount) AS 売上合計_顧客500
FROM   dbo.SalesFactCS
WHERE  CustomerId = 500;

SET STATISTICS IO OFF;
GO
--  メッセージ タブの出力(目安):
--    ① テーブル 'SalesFactCS'。セグメント読み取り数 2、セグメントのスキップ数 8。
--    ② テーブル 'SalesFactCS'。セグメント読み取り数 10、セグメントのスキップ数 0。
--
--  説明:
--    各セグメントは自分が持つ値の min/max をメタデータとして持っている。
--    SQL Server はセグメントを「開く前に」min/max と述語を突き合わせ、
--    条件に合う行が 1 行も無いセグメントを丸ごと読み飛ばす。
--
--    ① SaleDate は SaleId に比例して並んでいるので、
--       ロウグループごとに日付の範囲が分かれている。
--       2024年の行は末尾 2 ロウグループにしか存在しない → 8 個スキップできる。
--    ② CustomerId は 1〜1000 が全行にわたって循環している。
--       どのロウグループも min=1 / max=1000 → 1 個もスキップできない。
--
--    ★ 同じテーブル・同じ 1000万行でも、述語の列が「並んでいるか」だけでこの差が出る。


-- Q8. Q7 をメタデータで裏付ける(sys.column_store_segments の min/max)
SELECT c.name                     AS 列名,
       s.segment_id               AS ロウグループ,
       s.row_count                AS 行数,
       s.min_data_id              AS 最小,
       s.max_data_id              AS 最大,
       s.on_disk_size / 1024      AS セグメントKB
FROM   sys.column_store_segments AS s
JOIN   sys.partitions AS p
       ON  p.hobt_id = s.hobt_id
JOIN   sys.indexes AS i
       ON  i.object_id = p.object_id
       AND i.index_id  = p.index_id
JOIN   sys.columns AS c
       ON  c.object_id  = p.object_id
       AND c.column_id  = s.column_id
WHERE  p.object_id = OBJECT_ID('dbo.SalesFactCS')
  AND  c.name IN (N'SaleId', N'CustomerId')
ORDER  BY c.name, s.segment_id;
GO
--  結果の読み方(目安):
--    SaleId     : 1〜1048576 / 1048577〜2097152 / ... と ★綺麗に分かれる★
--                 → どのロウグループにどの範囲があるかが一意に決まる = 除外が効く
--    CustomerId : どのロウグループも 1〜1000。★全部が重なっている★
--                 → 「このロウグループに CustomerId=500 は無い」と言えない = 除外できない
--
--  伏線回収 —— sample-db/04_analytics_data.sql がなぜ日付を SaleId に比例させたか:
--
--      DATEADD(DAY, (n - 1) / @PerDay, '2015-01-01')
--
--    セグメント除外は「セグメント内の値の範囲が狭いこと」でしか効かない。
--    もし SaleDate をランダムに散らして生成していたら、
--    SaleDate の min/max も CustomerId と同じように
--    全ロウグループが 2015-01-01〜2024-12-31 を含むことになり、
--    ★日付で絞っても 1 個もスキップできなくなる★。
--    現実の売上ファクト表は取引が発生順に積み上がるので自然に日付順になる。
--    それを模した「意図的な設計」であり、この演習の①と②の差はその設計の直接の帰結。
--
--    → 実務上の教訓: 列ストアの性能の半分は「どの順序でロードしたか」で決まる。
--      インデックス定義に順序を書く場所は無い(2022 の ORDER 句を除く)。
--
--  ⚠ min_data_id / max_data_id は内部表現の整数。INT/BIGINT ならほぼ値そのものだが、
--    base_id / magnitude が -1 以外のときはオフセット表現になり、DATE や文字列列では
--    別のエンコードになる。厳密な値の復元にこだわらず「範囲が分かれているか、重なっているか」
--    を見ること。除外が効いたかの決定的な証拠は Q7 の「セグメントのスキップ数」。


-- Q9. 列を関数で包むとセグメント除外が消える
SET STATISTICS IO ON;

-- ✗ 非SARGable: YEAR(SaleDate) の値は min/max として持っていない
--    → セグメントを開いて全行に YEAR() を計算するまで判定できない
SELECT SUM(Amount) AS 売上合計
FROM   dbo.SalesFactCS
WHERE  YEAR(SaleDate) = 2024;
--    → セグメント読み取り数 10、セグメントのスキップ数 0

-- ○ 範囲条件に書き換える → min/max と直接比較できる
SELECT SUM(Amount) AS 売上合計
FROM   dbo.SalesFactCS
WHERE  SaleDate >= '2024-01-01' AND SaleDate < '2025-01-01';
--    → セグメント読み取り数 2、セグメントのスキップ数 8

SET STATISTICS IO OFF;
GO
--  18章の SARGability は列ストアでもそのまま生きている。
--  書き換えのイディオムも同じ: 「>= 期間の開始 かつ < 翌期間の開始」。
--  (結果はどちらも同じ。読んだセグメント数だけが 5 倍違う)


-- Q10. デルタストアの挙動 —— 102,400 行の壁
--      ※ SaleId を +100000000 してずらしておく(後の確認をしやすくするため)

-- ① 小さい INSERT(1,000 行)→ デルタストアへ
INSERT INTO dbo.SalesFactCS
    (SaleId, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
     Quantity, UnitPrice, Discount, Amount)
SELECT TOP (1000)
       SaleId + 100000000, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
       Quantity, UnitPrice, Discount, Amount
FROM   dbo.SalesFact
ORDER  BY SaleId;
GO

-- ①の直後にロウグループを確認
SELECT rg.row_group_id AS ロウグループ,
       rg.state_desc   AS 状態,
       rg.total_rows   AS 総行数,
       rg.trim_reason_desc AS 打ち切り理由,
       rg.delta_store_hobt_id AS デルタストアHOBTID
FROM   sys.dm_db_column_store_row_group_physical_stats AS rg
WHERE  rg.object_id = OBJECT_ID('dbo.SalesFactCS')
ORDER  BY rg.row_group_id;
GO
--  → 新しいロウグループ(row_group_id = 10)が ★ state_desc = OPEN ★ で現れる。
--    total_rows = 1000、trim_reason_desc は NULL / UNKNOWN(まだ圧縮されていないため)。
--    delta_store_hobt_id が NULL でない = ★ 実体は行ストア(B木)のデルタストア ★。
--    この 1000 行は列ストアの恩恵(圧縮・セグメント除外・列単位I/O)を一切受けていない。

-- ② 102,400 行以上の一括ロード(200,000 行 + TABLOCK)→ 直接 COMPRESSED へ
INSERT INTO dbo.SalesFactCS WITH (TABLOCK)
    (SaleId, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
     Quantity, UnitPrice, Discount, Amount)
SELECT TOP (200000)
       SaleId + 200000000, SaleDate, CustomerId, ProductId, EmployeeId, RegionId,
       Quantity, UnitPrice, Discount, Amount
FROM   dbo.SalesFact
ORDER  BY SaleId;
GO

-- ②の直後にロウグループを確認(Q5 と同じクエリ)
SELECT rg.row_group_id      AS ロウグループ,
       rg.state_desc        AS 状態,
       rg.total_rows        AS 総行数,
       rg.trim_reason_desc  AS 打ち切り理由,
       rg.delta_store_hobt_id AS デルタストアHOBTID
FROM   sys.dm_db_column_store_row_group_physical_stats AS rg
WHERE  rg.object_id = OBJECT_ID('dbo.SalesFactCS')
ORDER  BY rg.row_group_id;
GO
--  → 200,000 行のロウグループが ★ state_desc = COMPRESSED ★ で現れる。
--    trim_reason_desc = BULKLOAD(1,048,576 行に届かないまま一括ロードで確定したという意味)。
--    ①の OPEN なロウグループはそのまま残っている(タプルムーバーは OPEN に触らない)。
--
--  Q10 の答え:
--    ・境目は ★ 102,400 行 ★。
--    ・一括ロード(BULK INSERT / bcp / INSERT...SELECT WITH (TABLOCK))のバッチが
--      102,400 行以上なら、デルタストアを経由せず直接 COMPRESSED ロウグループになる。
--      102,400 行未満なら、単独で圧縮しても割に合わない(圧縮率が出ず、セグメントが細切れになる)
--      ので、いったんデルタストアに入れて 1,048,576 行たまってからまとめて圧縮する。
--    ・102,400 は 1,048,576 の約 1/10。「これ以下のかたまりを単独で圧縮しても割に合わない」しきい値。
--
--  ★ 実務で最も多い失敗:
--    ETL で 1万行ずつ 100 回 INSERT する → 100万行すべてがデルタストア行きになり、
--    列ストアにしたのに何も速くならない。
--    対策は「バッチを 102,400 行以上(理想は 1,048,576 行)にそろえ、WITH (TABLOCK) を付ける」。


-- Q11. タプルムーバーを待たずに、OPEN のロウグループを今すぐ圧縮する(2016+)
ALTER INDEX CCI_SalesFactCS ON dbo.SalesFactCS
    REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

SELECT rg.row_group_id     AS ロウグループ,
       rg.state_desc       AS 状態,
       rg.total_rows       AS 総行数,
       rg.deleted_rows     AS 削除済み行数,
       rg.trim_reason_desc AS 打ち切り理由
FROM   sys.dm_db_column_store_row_group_physical_stats AS rg
WHERE  rg.object_id = OBJECT_ID('dbo.SalesFactCS')
ORDER  BY rg.row_group_id;
GO
--  → OPEN だった 1000 行のロウグループが ★ COMPRESSED / trim_reason_desc = REORG ★ になる。
--    TOMBSTONE 状態の行が一時的に見えることもある(圧縮済みになった元デルタストア。
--    バックグラウンドで自動的に消える)。
--
--  使い分け:
--    ・REORGANIZE                                 … 通常のメンテナンス。オンラインで軽い。
--    ・REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS=ON) … OPEN/CLOSED も強制的に圧縮。
--                                                    ★ロード直後に必ず実行するのが定石★
--    ・REBUILD                                    … 全体を作り直す。重い。
--                                                    圧縮方式(COLUMNSTORE_ARCHIVE)の
--                                                    変更や、REORGANIZE で直らない断片化に。
--
--  タプルムーバーは約 5 分ごとに動くが、★ CLOSED しか圧縮しない ★。
--  1,048,576 行に達していない OPEN なデルタストアは放置すると永遠に圧縮されない。


------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q12. 行ストアに対するバッチモード (Batch Mode on Rowstore, 2019+)

-- まず互換性レベルを確認する(★変更はしない。確認だけ★)
SELECT name AS DB名, compatibility_level AS 互換性レベル
FROM   sys.databases
WHERE  name = N'SalesLearning';
GO
--  150 以上なら 2019 のバッチモードが有効になり得る。

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ① 強制的に行モード
SELECT YEAR(SaleDate) AS 年, RegionId AS 地域,
       SUM(Amount) AS 売上合計, COUNT_BIG(*) AS 件数
FROM   dbo.SalesFact
GROUP  BY YEAR(SaleDate), RegionId
ORDER  BY 年, 地域
OPTION (USE HINT('DISALLOW_BATCH_MODE'));

-- ② バッチモードを積極的に使わせる
SELECT YEAR(SaleDate) AS 年, RegionId AS 地域,
       SUM(Amount) AS 売上合計, COUNT_BIG(*) AS 件数
FROM   dbo.SalesFact
GROUP  BY YEAR(SaleDate), RegionId
ORDER  BY 年, 地域
OPTION (USE HINT('ALLOW_BATCH_MODE'));

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
--  確認方法: Ctrl+M で実際のプランを表示 → Clustered Index Scan や
--            Hash Match (Aggregate) を右クリック →[プロパティ]→
--            ★「実際の実行モード」★(「推定実行モード」ではない)
--
--  典型的な結果(2019+ / 互換性レベル 150 以上):
--    ① 実際の実行モード = Row  、CPU 時間 20,000〜40,000 ms
--    ② 実際の実行モード = Batch、CPU 時間  5,000〜10,000 ms
--    ★ 論理読み取り数は①②で ほぼ変わらない ★(60,000〜80,000 のまま)
--
--  Q12-1. 2019 未満 / 互換性レベル 150 未満の環境では
--    ・USE HINT('ALLOW_BATCH_MODE') / ('DISALLOW_BATCH_MODE') 自体が
--      認識されずエラーになるか、認識されても効果が無く、②も Row のままになる。
--    ・その場合は「行ストアのバッチモードは使えない」が正しい結論。
--      互換性レベルはデータベース全体に影響する設定なので、
--      学習のためだけに変更しないこと(変更したなら必ず元の値に戻す)。
--
--  Q12-2.「行ストアのバッチモードがあるなら列ストアは要らない」が誤りである理由
--    行ストアのバッチモードは ★実行モデルだけ★ を借りたもの。
--    列ストアだけが持つ利点は次の3つで、いずれも付いてこない:
--      (1) 列単位の I/O 削減 … 必要な列のセグメントだけ読む。
--          → ①②とも論理読み取り数が 70,000 前後のまま変わらないのが証拠。
--             列ストア版(Q3)は LOB 論理読み取り数 5,000 前後だった。
--      (2) 圧縮          … サイズが 1/5〜1/10(Q4)。物理I/Oもメモリ使用量も減る。
--      (3) セグメント除外 … min/max で読まずに捨てる(Q7)。行ストアには min/max が無い。
--    → CPU は近づけられても、I/O の桁は列ストアに勝てない。


-- Q13. HTAP —— フィルター選択された非クラスター化列ストアインデックス (2016+)
--      ※ dbo.OrdersBig が無い場合は sample-db/03_bulk_data.sql を先に実行

-- 13-1. 「完了」の行だけを対象にした NCCI を作る
DROP INDEX IF EXISTS NCCI_OrdersBig_Done ON dbo.OrdersBig;
GO

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_OrdersBig_Done
    ON dbo.OrdersBig (OrderDate, CustomerId, Amount)
    WHERE Status = N'完了';
GO

-- 13-2. インデックスの WHERE を包含するクエリ → 使われる
SET STATISTICS IO ON;

SELECT YEAR(OrderDate) AS 年,
       COUNT_BIG(*)    AS 件数,
       SUM(Amount)     AS 売上合計
FROM   dbo.OrdersBig
WHERE  Status = N'完了'
GROUP  BY YEAR(OrderDate)
ORDER  BY 年;

SET STATISTICS IO OFF;
GO
--  → プランに ★ Columnstore Index Scan (NCCI_OrdersBig_Done) ★ が現れ、
--    実際の実行モードは Batch。論理読み取り数は 0 に近く、
--    I/O は LOB 論理読み取り数 側に出る(数百〜数千)。

-- 13-3. インデックスの WHERE を書かないと使われない
SET STATISTICS IO ON;

SELECT YEAR(OrderDate) AS 年,
       COUNT_BIG(*)    AS 件数,
       SUM(Amount)     AS 売上合計
FROM   dbo.OrdersBig
GROUP  BY YEAR(OrderDate)
ORDER  BY 年;

SET STATISTICS IO OFF;
GO
--  → Clustered Index Scan に戻り、論理読み取り数が 6,000 前後に跳ね上がる。
--
--  説明:
--    フィルター選択されたインデックスは、その WHERE 条件を満たす行しか含んでいない。
--    クエリ側が「Status = N'完了'」を書いていないと、
--    オプティマイザは「N'保留' の行も必要かもしれない」と判断せざるを得ず、使えない。
--    → クエリの述語が ★インデックスの WHERE を論理的に包含している★ 必要がある。
--      (18章のフィルター選択されたインデックスとまったく同じ制約)
--
--  13-4. なぜ「完了だけ」に絞るのが筋が良いのか
--    列ストアは更新に弱い:
--      ・DELETE は削除ビットマップに印を付けるだけでセグメントからは消えない。
--      ・UPDATE は「削除ビットマップに印 + デルタストアへ挿入」として処理される。
--      → 更新のたびに断片化が進み、REORGANIZE / REBUILD のコストが増え続ける。
--    dbo.OrdersBig では:
--      ・N'保留'(約5%) = まだ動いている「熱い」行。頻繁に更新される。
--      ・N'完了'(約95%) = もう変わらない「冷えた」行。
--    冷えた行だけを列ストアに載せれば、
--      ・更新コストをほとんど払わずに済み、
--      ・それでも分析対象の 95% をカバーできる。
--    これが HTAP における「ホット/コールド分離」。
--    業務側の点検索(WHERE OrderId = ?)は従来どおり B木のクラスタ化インデックスが処理するので、
--    OLTP の性能を一切犠牲にしない。


------------------------------------------------------------
-- Q14. ★必須の後片付け★
------------------------------------------------------------

-- 14-1. 列ストア版のコピーをテーブルごと削除(CCI も一緒に消える)
DROP TABLE IF EXISTS dbo.SalesFactCS;
GO

-- 14-2. dbo.OrdersBig に作った NCCI を削除
DROP INDEX IF EXISTS NCCI_OrdersBig_Done ON dbo.OrdersBig;
DROP INDEX IF EXISTS NCCI_OrdersBig      ON dbo.OrdersBig;   -- 解説で試した場合
GO

-- 14-3. 列ストアインデックスが1つも残っていないことを確認(0 行なら OK)
SELECT OBJECT_NAME(i.object_id) AS テーブル,
       i.name                   AS インデックス名,
       i.type_desc              AS 種別
FROM   sys.indexes AS i
WHERE  i.type_desc LIKE N'%COLUMNSTORE%';
GO

-- 14-4. 元のテーブルが無傷であることを確認
--       SalesFact = 10000000 行 / OrdersBig = 1000000 行 なら OK
SELECT N'dbo.SalesFact' AS テーブル, COUNT_BIG(*) AS 行数 FROM dbo.SalesFact
UNION ALL
SELECT N'dbo.OrdersBig',            COUNT_BIG(*)          FROM dbo.OrdersBig;
GO

/* ============================================================
   ⚠ dbo.SalesFact は絶対に削除しないこと。
     トピック31(パーティショニング)で引き続き使用します。

   もし途中でおかしくなったら sample-db/04_analytics_data.sql を
   再実行すれば dbo.SalesFact を丸ごと作り直せます
   (既存の小さいテーブルには影響しません)。
   ============================================================ */
