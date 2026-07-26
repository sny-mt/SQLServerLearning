/* ============================================================
   解答例 29 — 結合アルゴリズムと並列処理
   対象演習: exercises/29_join_algorithms_parallelism.md

   前提: sample-db/03_bulk_data.sql を実行し、dbo.OrdersBig(100万行)
         が作成済みであること。開始時点で非クラスタ化インデックスは0本。

   使い方: SSMS で Ctrl+M(★実際の★実行プランを含める)を ON にしてから、
           上から順に実行して次を記録する。
             ・物理結合演算子の名前(Nested Loops / Merge Join / Hash Match)
             ・論理読み取り数 / スキャン カウント
             ・SELECT 演算子のプロパティ MemoryGrantInfo
             ・CPU 時間 と 経過時間 の関係(並列判定)

   ★ 最後の Q17(後片付け)まで必ず実行すること。
   ★ Q15 は sp_configure を使う。共有サーバーでは実行しないこと。
   ※ 数値はすべて環境・バージョンにより前後する目安。
     大事なのは絶対値ではなく「変化の桁」。
   ============================================================ */
USE SalesLearning;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 外側が小さい結合 → Nested Loops
--     プラン       : Clustered Index Seek (PK_OrdersBig)
--                    → Nested Loops (Inner Join)
--                    → Clustered Index Seek (PK_Customers) を 100 回
--     論理読み取り : OrdersBig 数ページ + Customers 数百(スキャンカウント 100 前後)
SELECT o.OrderId,
       o.OrderDate,
       c.CustomerName
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c
       ON c.CustomerId = o.CustomerId
WHERE  o.OrderId BETWEEN 1 AND 100;

/* Q1 の説明:
   OrderId はクラスタ化主キーなので、WHERE で 100 行だけに絞れる。
   → 外側(OrdersBig)の行数が 100 しかない。
   Nested Loops のコストは「外側の行数 × 内側を1回引くコスト」。
   内側 Customers は主キーシークで 2〜3 ページ。100 × 数ページなら極めて安い。
   さらに Nested Loops はブロックしないので、1行目をすぐ返せる。
   → OLTP の「1件を引いてマスタを付ける」形の理想形。

   内側の「実行回数 (Number of Executions)」= 外側の行数 になっている点を
   ツールチップで必ず確認すること。STATISTICS IO ではスキャン カウントに現れる。 */

-- Q2. 絞り込みを外して 100万行にする → Hash Match に変わる
--     プラン       : Clustered Index Scan (PK_OrdersBig)
--                    → Hash Match (Inner Join)  ※ build 側は Customers(12行)
--                    → Hash Match (Aggregate)
--     論理読み取り : OrdersBig 約 6,000
SELECT c.CustomerName,
       COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c
       ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName;

/* Q2 の説明:
   クエリの文面(INNER JOIN)は Q1 と同じで、変わったのは「流れる行数」だけ。
   外側が 100万行になると、Nested Loops は内側を 100万回引くことになる。
   一方 Hash Join なら、小さい Customers(12行)でハッシュ表を作り、
   OrdersBig を1回流すだけで済む(= 両入力を1回ずつ読むだけ)。
   → 論理結合の種類ではなく「行数」が物理演算子を決めている。

   ★ この章の出発点: 論理結合(INNER/LEFT…)と物理演算子(Loops/Merge/Hash)は別物。 */

-- Q3-1. 素直にオプティマイザに任せる → Hash Match
--       論理読み取り : OrdersBig 約 6,000 / スキャン カウント 1(並列なら DOP 分)
SELECT e.LastName,
       COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o
       ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName;

-- Q3-2. ✗ Nested Loops を強制する(学習用。本番では絶対にやらないこと)
--       プラン       : Employees(13行)を外側、OrdersBig を内側にした Nested Loops
--                      内側は EmployeeId のインデックスが無いので Clustered Index Scan
--       論理読み取り : OrdersBig 約 78,000(= 約 6,000 × 13)
--       スキャンカウント : 13
SELECT e.LastName,
       COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o
       ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName
OPTION (LOOP JOIN, FORCE ORDER, MAXDOP 1);

/* Q3 の説明:
   差は約 13 倍。理由はそのまま「外側の行数」= 13。
   内側に EmployeeId のインデックスが無いため、外側の1行ごとに
   OrdersBig を丸ごと走査している(= フルスキャン × 13回)。
   スキャン カウントが 13 になっていることが動かぬ証拠。

   ★ 実務での典型的な事故:
     統計が古くなって外側の推定行数が「1行」になり、
     「1回だけ内側を引くなら安い」と判断されて Nested Loops が選ばれ、
     実際には10万行流れてきて内側を10万回引いた ── これが
     「ある日から急にこのクエリだけ数十倍遅い」の正体。
     実際のプランで「推定行数 vs 実際の行数」を比べれば一発で分かる(18章・27章)。

   ★ 補足: インデックスがあれば Nested Loops が常に良い、でもない。
     EmployeeId にインデックスを作ってもシーク1回あたり約 77,000 行が返るので、
     結局 100万行を読むことに変わりはなく、Hash Match のほうが速い。
     Nested Loops の条件は3つ揃ってはじめて成立する:
       ① 外側が小さい ② 内側に結合キーのインデックス ③ 1回のシークで返る行が少ない */

-- Q4. CustomerId にインデックスを作る → 両側がソート済みになり Sort なしの Merge Join
CREATE NONCLUSTERED INDEX IX_OrdersBig_CustomerId
    ON dbo.OrdersBig (CustomerId);
GO

--     プラン       : Index Scan (IX_OrdersBig_CustomerId, Ordered=True)
--                    + Clustered Index Scan (PK_Customers, Ordered=True)
--                    → Merge Join ★ Sort は現れない
--     論理読み取り : OrdersBig 約 1,700〜2,000(細い索引を順に読むだけなので 6,000 より少ない)
SELECT c.CustomerName,
       COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c
       ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (MERGE JOIN, MAXDOP 1);

/* Q4 の説明:
   Merge Join は「両方の入力が結合キーでソート済み」であることが前提。
     ・dbo.Customers … CustomerId のクラスタ化主キー順に並んでいる
     ・dbo.OrdersBig … IX_OrdersBig_CustomerId を順に読めば CustomerId 順
   どちらもインデックス順に読むだけでソート済みが手に入るので、Sort 演算子は不要。
   両入力を1回ずつなめるだけで終わるため、非常に効率的。

   このとき Customers 側は主キーで一意なので「一対多」の Merge Join になる
   (演算子プロパティ Many to Many = False)。多対多なら tempdb の
   ワークテーブルを使って巻き戻しが発生し、コストが上がる。 */

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. ソート順が用意できない列で Merge Join を強制する → 100万行の Sort が入る
--     プラン       : Clustered Index Scan → ★ Sort(実際の行数 約 1,000,000)
--                    → Merge Join
--     経過時間     : Q4 より大幅に悪化する。メモリ許可も跳ね上がる
SELECT e.LastName,
       COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o
       ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName
OPTION (MERGE JOIN, MAXDOP 1);

/* Q5 の説明:
   EmployeeId 順のインデックスが無いので、Merge Join を成立させるために
   オプティマイザは 100万行の Sort を挿入するしかない。
   この Sort は全行をメモリに載せるため、大きなメモリ許可を要求し、
   足りなければ tempdb にスピルする(Q7 につながる)。

   ★ まとめの1文:
     「Merge Join が効率的なのは、両側がすでにソート済みで手に入る場合だけ。
       ソートするところから始めるなら、たいてい Hash Join のほうが安い。」

   ※ Q3 の考察で IX_OrdersBig_EmployeeId を作った場合は先に削除してから試すこと:
     DROP INDEX IF EXISTS IX_OrdersBig_EmployeeId ON dbo.OrdersBig;          */

-- Q6-1. 自然な build 側(Customers 12行)
--       実行後、いちばん左の SELECT 演算子 → プロパティ → MemoryGrantInfo を開く
--         RequestedMemory … 数百KB〜数MB
--         MaxUsedMemory   … それよりさらに小さい
SELECT c.CustomerName,
       COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c
       ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (HASH JOIN, MAXDOP 1);

-- Q6-2. ✗ FORCE ORDER で OrdersBig(100万行)を build 側にしてしまう
--         RequestedMemory … 数十MB 以上に跳ね上がる
SELECT c.CustomerName,
       COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c
       ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (HASH JOIN, FORCE ORDER, MAXDOP 1);

/* Q6 の説明:
   Hash Join は2フェーズで動く。
     build フェーズ … 小さいほうの入力を全部読み、ハッシュ表をメモリ上に作る
     probe フェーズ … 大きいほうを1行ずつ流し、ハッシュ表を引いて一致を探す
   ハッシュ表は「build 側の行数 × 行サイズ」にほぼ比例したメモリを必要とする。

   1 は build = Customers(12行)なのでハッシュ表は極小。
   2 は FORCE ORDER によって FROM に先に書いた OrdersBig(100万行)が build 側になる。
     → 100万行分のハッシュ表を作ろうとして、要求メモリが2桁変わる。
   同じ結果を返す同じ結合なのに、build 側の選び方だけでこれだけ違う。

   ★ オプティマイザは「小さいと推定したほう」を build に選ぶ。
     つまり推定が外れると自動的に 2 の状態になる。これが Hash Join の破綻パターン。
   ★ プラン上は Hash Match の「上側の入力が build、下側が probe」。
     Hash Keys Build / Hash Keys Probe プロパティでも確認できる。          */

-- Q7-1. 正常: 100万件の Hash Aggregate。十分なメモリが許可される
SELECT COUNT_BIG(*) AS 件数
FROM   (SELECT DISTINCT OrderId, Amount FROM dbo.OrdersBig) AS x
OPTION (HASH GROUP, MAXDOP 1);

-- Q7-2. ✗ メモリ許可の上限を 1% に制限してスピルさせる
--         MAX_GRANT_PERCENT は 2012 SP3 / 2014 SP2 / 2016+ のクエリヒント
SELECT COUNT_BIG(*) AS 件数
FROM   (SELECT DISTINCT OrderId, Amount FROM dbo.OrdersBig) AS x
OPTION (HASH GROUP, MAXDOP 1, MAX_GRANT_PERCENT = 1);

/* Q7 の確認ポイント(3経路すべてで確認すること):

   (a) 実行プランの警告アイコン
       Hash Match に黄色い三角が付く。プロパティ / ツールチップに
         「ハッシュ書き込みの警告 (Hash Warning)」
         スピルしたスレッド数 (Spilled Thread Count)
         スピル レベル (SpillLevel) / 書き込みページ数 (SpilledDataSize)
       が出る。★ 推定プラン(Ctrl+L)には出ない。必ず Ctrl+M で実行すること。
       Sort がスピルした場合は「ソートの警告 (Sort Warning)」。

   (b) SET STATISTICS IO の出力
       「ワークテーブル (Worktable)」の行が現れ、その論理読み取り数が計上される。
       ★ これが tempdb への往復。メモリに載りきらなかった分が書き出されている。

   (c) 経過時間
       数倍〜十数倍に伸びる。CPU 時間よりも経過時間が伸びやすい(I/O 待ちのため)。

   ★ Hash Join でも同じことが確認できる(別解):
       SELECT COUNT_BIG(*) FROM dbo.OrdersBig AS a
       INNER JOIN dbo.OrdersBig AS b ON b.OrderId = a.OrderId
       OPTION (HASH JOIN, MAXDOP 1, MAX_GRANT_PERCENT = 1);

   ★ メモリが足りないときの劣化は3段階:
       ① In-Memory Hash Join  … 全部メモリ内。正常
       ② Grace Hash Join      … 一部を tempdb に退避(= スピル)
       ③ Recursive Hash Join  … 退避分をさらに分割し直す
     さらに偏りで分割しても小さくならないと「ハッシュ ベイルアウト」。壊滅的。

   ⚠ MAX_GRANT_PERCENT は学習と緊急避難のためのヒント。本番で常用すると
     「データが増えたら必ずスピルする」設定を焼き付けることになる。
     しかもヒントを書くとメモリ許可フィードバックが働かなくなる。       */

-- Q8. キャッシュ済みプランのスピル状況を見る
--     ★ total_spills / last_spills / max_spills は SQL Server 2016 SP2 / 2017 CU3 以降
SELECT TOP (20)
       qs.total_spills            AS 累計スピルページ数,
       qs.last_spills             AS 直近スピルページ数,
       qs.max_spills              AS 最大スピルページ数,
       qs.execution_count         AS 実行回数,
       qs.last_grant_kb           AS 直近許可KB,
       qs.last_used_grant_kb      AS 直近実使用KB,
       qs.max_grant_kb            AS 最大許可KB,
       qs.max_used_grant_kb       AS 最大実使用KB,
       qs.total_worker_time / NULLIF(qs.execution_count, 0) AS 平均CPUマイクロ秒,
       SUBSTRING(st.text,
                 (qs.statement_start_offset / 2) + 1,
                 ((CASE qs.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset
                   END - qs.statement_start_offset) / 2) + 1
       ) AS ステートメント
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE  qs.total_spills > 0
ORDER  BY qs.total_spills DESC;

/* Q8 の説明:
   last_grant_kb と last_used_grant_kb を「並べて見る」ことに意味がある。

     ・許可KB ≫ 実使用KB          → 過大推定。
                                    メモリを無駄に握って他クエリを締め出している。
                                    → 他セッションが RESOURCE_SEMAPHORE で待つ原因。
     ・total_spills が大きい       → 過小推定。
                                    許可が足りず tempdb に書き出している。自分が遅い。
     ・両方の値が近く spills が 0  → 健全。

   ★ 「過小推定は自分が遅くなり、過大推定は他人を遅くする」。
     どちらも原因はメモリ不足ではなく「推定行数の誤り」であることがほとんど。

   ★ 他の確認経路:
     ・拡張イベント(25章): sort_warning / hash_warning / exchange_spill
     ・Query Store(24章) : sys.query_store_runtime_stats の
                            avg_query_max_used_memory(2016+)
                            avg_tempdb_space_used(2017+)
       → 「先月まで出ていなかったスピルが今月から出ている」という回帰の検出に向く。 */

-- Q9. 実行中クエリのメモリ許可を観測する
SELECT mg.session_id              AS セッション,
       mg.dop                     AS DOP,
       mg.request_time            AS 要求時刻,
       mg.grant_time              AS 許可時刻,        -- NULL = まだ待っている
       mg.requested_memory_kb     AS 要求KB,
       mg.granted_memory_kb       AS 許可KB,
       mg.required_memory_kb      AS 最低必要KB,
       mg.used_memory_kb          AS 現在使用KB,
       mg.max_used_memory_kb      AS 最大使用KB,
       mg.ideal_memory_kb         AS 理想KB,
       mg.query_cost              AS 推定コスト,
       mg.timeout_sec             AS タイムアウト秒,
       mg.wait_time_ms            AS 待ちミリ秒,
       mg.is_next_candidate       AS 次の候補か,
       mg.resource_semaphore_id   AS セマフォID,
       st.text                    AS クエリ
FROM   sys.dm_exec_query_memory_grants AS mg
CROSS  APPLY sys.dm_exec_sql_text(mg.sql_handle) AS st
ORDER  BY mg.requested_memory_kb DESC;

/* Q9 の判断基準:

   1. メモリ許可を待たされている
      → grant_time が NULL で、wait_time_ms が増え続ける。
        is_next_candidate = 1 なら「次に許可される順番」。
        このとき待機タイプは RESOURCE_SEMAPHORE(23章)。

   2. 過大推定でメモリを無駄に占有している
      → granted_memory_kb ≫ max_used_memory_kb。
        (例: 許可 500MB に対して実使用 3MB)
        1本のクエリが枠を独占し、他のクエリ全員を待たせている状態。

   3. 要求が削られてスピルしそう
      → granted_memory_kb が required_memory_kb 付近まで下がっている
        (requested_memory_kb より大幅に少ない)。
        サーバーに空きが無く、最低限しかもらえていない。

   ★ サーバー全体の残量はこちらで見る。waiter_count > 0 が常態なら
     メモリ許可そのものがボトルネック。                                   */
SELECT resource_semaphore_id  AS セマフォID,   -- 0=通常 / 1=小さいクエリ専用
       target_memory_kb       AS 目標KB,
       max_target_memory_kb   AS 上限KB,
       total_memory_kb        AS 合計KB,
       available_memory_kb    AS 空きKB,
       granted_memory_kb      AS 許可済みKB,
       grantee_count          AS 実行中クエリ数,
       waiter_count           AS 待機中クエリ数,     -- ★ 0 より大きいなら要注意
       timeout_error_count    AS タイムアウト回数,
       forced_grant_count     AS 強制許可回数
FROM   sys.dm_exec_query_resource_semaphores;

-- (参考) メモリ許可まわりの待機統計(23章と接続)
SELECT wait_type            AS 待機タイプ,
       waiting_tasks_count  AS 待機回数,
       wait_time_ms         AS 合計待機ミリ秒,
       max_wait_time_ms     AS 最大待機ミリ秒,
       signal_wait_time_ms  AS シグナル待機ミリ秒
FROM   sys.dm_os_wait_stats
WHERE  wait_type IN (N'RESOURCE_SEMAPHORE',                 -- クエリ実行用メモリ待ち
                     N'RESOURCE_SEMAPHORE_QUERY_COMPILE')   -- コンパイル用メモリ待ち(別物)
ORDER  BY wait_time_ms DESC;
GO

-- Q10-1. 直列を強制 → CPU 時間 ≒ 経過時間
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region
OPTION (MAXDOP 1);

-- Q10-2. オプティマイザに任せる → 並列。CPU 時間 > 経過時間
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;

/* Q10 の説明:
   判定根拠 ── 「CPU 時間 > 経過時間」なら並列。
     複数のスレッドが同時に CPU を消費するため、CPU 時間の合計が実時間を超える。
     直列なら1スレッドしか動かないので CPU 時間 ≒ 経過時間 にしかならない。
     → プランを開かずに並列かどうかを判定できる、いちばん手軽な方法。
   プラン上は各演算子に黄色い二重矢印(並列マーク)が付く。

   論理読み取り数が変わらない理由:
     並列化は「同じ仕事を複数スレッドで分担する」だけで、
     読まなければならないページの総数は1ページも減らない。
     読むページ数を減らしたいならインデックス(18章)。
     並列は「CPU を余分に使って実時間を買う取引」であり、
     1本のクエリは速くなってもサーバー全体のスループットは下がりうる。

   並列プランが検討される条件:
     ① 直列プランの推定コスト > cost threshold for parallelism(既定 5)
     ② MAXDOP(既定 0 = 制限なし)と、実行時の空きスレッド数
   既定の 5 は 1990年代のハードウェア基準の値。現代では 25〜50 程度へ
   引き上げるのが広く行われている定石だが、必ず自分のワークロードで計測して決める。 */

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

/* Q11. Exchange (Parallelism) 演算子の読み方

   Q10-2 の並列プランで、演算子名 "Parallelism" を探し、
   右クリック → プロパティ で次の2つを見る。

   ■ Logical Operation(向き)
     Distribute Streams   直列 → 並列   1本のストリームを複数スレッドに配る
     Repartition Streams  並列 → 並列   結合キー/グループキーで配り直す
     Gather Streams       並列 → 直列   複数スレッドの結果を1本に集める

   ■ Partitioning Type(配り方)
     Hash          指定列のハッシュ値でスレッドを決める ★ 偏り(skew)の主犯
     Round Robin   順繰りに均等配分。偏りにくい
     Broadcast     全スレッドに全行を配る(小さい入力にのみ使われる)
     Range         値の範囲で分ける
     Demand        空いたスレッドが要求して取りに行く

   ■ Gather Streams はどこにいくつ出るか
     プランの ★ 左端近く(SELECT の直前あたり)に ★ 必ず1つ 現れる。
     理由: クライアントに結果を返すのは1本のストリームだから。
           並列区間はどこかで必ず直列に戻す必要があり、その境界が Gather Streams。

   ■ 読み方のコツ
     ・Repartition Streams が多いプランは「配り直し」のコストを払っている。
       結合キーが揃っていない(適切なインデックスが無い)サインであることが多い。
     ・Exchange 自身がバッファを持つので Exchange もスピルする。
       拡張イベント exchange_spill がそれ。出たら DOP を下げるか推定を直す。 */

-- Q12. 並列関連の待機統計
SELECT wait_type                       AS 待機タイプ,
       waiting_tasks_count             AS 待機回数,
       wait_time_ms                    AS 合計待機ミリ秒,
       wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS 平均待機ミリ秒,
       max_wait_time_ms                AS 最大待機ミリ秒,
       signal_wait_time_ms             AS シグナル待機ミリ秒
FROM   sys.dm_os_wait_stats
WHERE  wait_type LIKE N'CX%'
ORDER  BY wait_time_ms DESC;

/* Q12 の説明:

   1. CXCONSUMER と CXPACKET の違い / 分離されたバージョン
      ★ SQL Server 2016 SP2 / 2017 CU3 以降 で分離された。
        CXCONSUMER … 受け手 (consumer) スレッドが producer からのデータを待つ時間。
                      並列が正常に動いていても構造的に必ず発生する。★ 基本的に無害。
        CXPACKET   … 送り手 (producer) 側などの待ち。
                      ★ 意味がある。スレッド間の偏り (skew) や遅いスレッドを示唆する。
      さらに SQL Server 2019 では CXSYNC_PORT / CXSYNC_CONSUMER が追加され、
      Exchange の同期待ちがより細かく分類されている。

   2. なぜ分離が必要だったか
      分離前は「無害な受け手の待ち」まで全部 CXPACKET に計上されていたため、
      並列が正常なサーバーでも CXPACKET が待機統計の1位になるのが当たり前だった。
      その結果「CXPACKET が多い → 並列が悪い → MAXDOP を 1 にしよう」という
      ★ 誤った対処が世界中で広まった。分離はこの誤解を解くために行われた。

   3. CXPACKET が上位に出たときに最初に確認すべきこと
      ・CXCONSUMER と分けて見えているか(2016 SP2 / 2017 CU3 未満なら分けられない)
      ・そもそも遅いのか。待機統計は「待っている」ことしか教えない。
        遅いかどうかは経過時間・CPU 時間・論理読み取り数で別途確認する。
      ・軽いクエリまで並列化されていないか
        → cost threshold for parallelism を上げて直列に戻すことを検討。
      ・個別クエリなら Q13 の手順でスレッド間の偏りを確認する。

   ⚠ sys.dm_os_wait_stats はサーバー起動時からの累計。
     検証では「開始時と終了時の差分」を取るか、開発環境でのみ
       DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
     でリセットする。★ 本番でのリセットは厳禁。                          */

/* Q13. スレッド間の偏り (skew) の確認手順

   ■ 手順(実行済みのクエリを調べる)
     ① 実際の実行プラン(Ctrl+M)を ON にして Q10-2 を実行する。
        ★ 推定プラン(Ctrl+L)ではスレッド別の情報は一切見えない。
     ② 疑わしい演算子(Clustered Index Scan、Hash Match、
        Parallelism の下側など)を右クリック → プロパティ。
     ③ ★ プロパティの「Actual Number of Rows(実際の行数)」を展開する。
        Thread 0, Thread 1, Thread 2 ... とスレッド別の行数が並ぶ。
     ④ ★ Thread 0 は「調整スレッド(コーディネータ)」なので通常 0 行。
        これは行を処理する側ではないため、★ 偏りの判定からは除外する。
     ⑤ Thread 1 以降の行数を見比べる。

   ■ 判断の目安
     理想は全スレッドがほぼ同数。
     ★ 最大スレッドと最小スレッドで数倍以上の開きがあれば「偏っている」。
     極端な例では1スレッドに大半が集中し、直列とほぼ変わらない時間になる。
     並列は「全スレッドが終わるまで完了しない」ため、
     いちばん遅いスレッドが全体の時間を決めてしまう。
     同じ要領で「Actual Time Statistics」を展開すればスレッド別の経過時間も見える。

   ■ 主な原因
     ・Repartition Streams の Partitioning Type = Hash で偏った列に分配した。
       例: dbo.OrdersBig の Status(N'完了' 95% / N'保留' 5%)。
           ハッシュ値が2種類しかなければ最大2スレッドにしか行が届かない。
     ・Nested Loops の並列で外側の分配が不均等だった。
     ・統計の偏りで範囲分割の境界がずれた。

   ■ 対処(影響範囲の狭い順)
     ① 偏った列を分配キーから外せないか検討する
     ② インデックスを追加して Repartition Streams 自体を不要にする
     ③ そのクエリだけ OPTION (MAXDOP 1) にする

   ⚠ 偏りはデータの分布に依存するため、環境によって出たり出なかったりする。
     身につけるべきは「偏っているか確かめる手順」そのもの。                */

-- Q13(続き). 実行中のクエリをライブに観測する(sys.dm_exec_query_profiles は 2014+)
--   別セッションで長時間クエリを走らせながら実行する。
--   2016 SP1+ の軽量プロファイリングなら本番でも比較的安全に観測できる(26章)。
SELECT p.session_id              AS セッション,
       p.node_id                 AS ノードID,          -- 同じ値 = 同じ演算子
       p.physical_operator_name  AS 演算子,
       p.thread_id               AS スレッド,
       p.row_count               AS 処理済み行数,       -- ★ ここがスレッド間で偏る
       p.estimate_row_count      AS 推定行数,
       p.elapsed_time_ms         AS 経過ミリ秒
FROM   sys.dm_exec_query_profiles AS p
WHERE  p.session_id = 99                                -- ★ 調べたいセッションIDに変える
ORDER  BY p.node_id, p.thread_id;
GO

/* Q13 の見方:
   同じ node_id(= 同じ演算子)の中で row_count がスレッドごとに大きく違えば偏り。
   自分のセッションIDは SELECT @@SPID; で確認できる。                      */

------------------------------------------------------------
-- Q14. データベース スコープ構成で MAXDOP を変える(★必ず戻す)
------------------------------------------------------------

-- ★ STEP 1: 変更前の値を必ず記録する(既定は 0 = サーバー設定に従う)
SELECT configuration_id     AS ID,
       name                 AS 設定名,
       value                AS 現在値,          -- ← この値をメモしておく
       value_for_secondary  AS セカンダリ用
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';

-- ★ STEP 2: 変更する(このデータベースだけ直列にする)
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 1;

-- ★ STEP 3: 効果を確認する(Q10-2 と同じクエリが直列になる = CPU時間 ≒ 経過時間)
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;

-- ★ STEP 4: 【必須】元に戻す(STEP 1 で記録した値。既定は 0)
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;

-- ★ STEP 5: 戻ったことを確認する
SELECT name AS 設定名, value AS 現在値
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';
GO

/* Q14 の説明:
   ALTER DATABASE SCOPED CONFIGURATION は SQL Server 2016+。

   クエリヒント OPTION (MAXDOP n) との違い:
     ・DB スコープ構成 … そのデータベースの ★ すべてのクエリ ★ に効く。
                          他人のセッションにも影響する。
     ・クエリヒント     … ★ そのクエリ1本だけ ★。他人に一切影響しない。

   ★ 検証では必ずクエリヒントを優先して使うこと。
     影響範囲がいちばん狭く、戻し忘れの事故も起きないため。

   ⚠ STEP 4 を忘れると、以降この教材のすべての並列の例が再現しなくなる。
     STEP 2 を書いたら、同じバッチに STEP 4 も一緒に書いておくのが安全な習慣。 */

------------------------------------------------------------
-- Q15. サーバー設定(★ローカル環境限定。共有サーバーでは実行しないこと)
------------------------------------------------------------

/* ⚠⚠⚠ sp_configure はインスタンス全体に効く。
        共有の開発サーバーや本番では絶対に実行しないこと。
        共有環境の場合は STEP 1 の確認クエリだけ実行し、以降は読むだけでよい。 */

-- ★ STEP 1: 変更前の値を必ず記録する
SELECT name          AS 設定名,
       value         AS 設定値,        -- ← この値をメモしておく
       value_in_use  AS 実効値,
       minimum       AS 最小,
       maximum       AS 最大
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism',
                N'cost threshold for parallelism');
-- 既定は max degree of parallelism = 0 / cost threshold for parallelism = 5

-- ★ STEP 2: 変更する
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;

-- ★ STEP 3: 効果を確認する(推定コスト 50 以下のクエリは直列になる)
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;

-- ★ STEP 4: 【必須】STEP 1 で記録した元の値に戻す
EXEC sp_configure 'cost threshold for parallelism', 5;   -- ← 記録した元の値
RECONFIGURE;
EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;

-- ★ STEP 5: 戻ったことを確認する
SELECT name AS 設定名, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism',
                N'cost threshold for parallelism');
GO

/* Q15 の説明:

   ■ MAXDOP の設定粒度(★ 優先順位の高い順 = 狭い順)
     ① クエリヒント        OPTION (MAXDOP n)                       そのクエリ1本
     ② Resource Governor   ワークロードグループの MAX_DOP           そのグループ
     ③ DB スコープ構成     ALTER DATABASE SCOPED CONFIGURATION      そのDB(2016+)
     ④ サーバー            sp_configure 'max degree of parallelism' インスタンス全体
     狭いほうが優先される。①が指定されていれば④は無視される。

   ■ 並列を抑止したいときに試す順序(★ 影響範囲の狭い順)
     ① そのクエリだけ OPTION (MAXDOP 1)
     ② そのデータベースだけ ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = n
     ③ サーバーの cost threshold for parallelism を上げる(軽いクエリを直列に戻す)
     ④ サーバーの MAXDOP を変える   ← いちばん影響が大きい。最後の手段

   ■ MAXDOP の値の決め方(一般的な出発点)
     ・論理プロセッサ 8 以下 … プロセッサ数以下
     ・論理プロセッサ 8 超   … 8 から始める
     ・NUMA 構成なら1つの NUMA ノードの論理プロセッサ数を超えない
     ・SQL Server 2019+ のセットアップはこの目安に沿った値を自動提案する
     ・OLTP 中心なら低め(1〜4)、DWH/バッチ中心なら高め
     いずれも出発点。決めたら必ずワークロードで計測して調整する。

   ■ 並列を抑止すべきケース
     ・短時間の OLTP クエリが並列化されている(準備コストのほうが高い)
     ・CXPACKET が高く、偏りが確認できた
     ・同時実行が多くワーカースレッドが枯渇(THREADPOOL 待機)
     ・Exchange のスピル(exchange_spill)が出ている
     ・スカラー UDF を含む(2019 未満はプラン全体が直列化される。
       2019+ のスカラー UDF インライン化で改善)                          */

/* Q16. 前任者のチューニングの問題点

   対象:
     SELECT c.CustomerName, COUNT(*) AS 件数
     FROM   dbo.OrdersBig AS o
     INNER LOOP JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
     GROUP  BY c.CustomerName;

   ■ 問題1: 結合レベルの結合ヒントは、暗黙に FORCE ORDER を適用する
     ★ INNER LOOP JOIN のように FROM 句に書く「結合レベルのヒント」を使うと、
       そのクエリ全体に FORCE ORDER が暗黙に適用される。
       つまりアルゴリズムだけ指定したつもりが、★ 結合順序まで固定している。
       ここでは OrdersBig(100万行)が外側に固定され、
       内側の Customers を 100万回引くことになる。最悪の Nested Loops。

     修正: アルゴリズムだけ指定したいならクエリレベルヒントを使う。
             OPTION (LOOP JOIN)      ← 順序は固定されない
           そもそもこのクエリに Nested Loops は不適切なので、
           ★ ヒントを外してオプティマイザに任せるのが正解(Hash Match が選ばれる)。

   ■ 問題2: 今日のデータ分布を永久に焼き付けている
     ヒントは「提案」ではなく「オプティマイザの判断を禁止する命令」。
     dbo.Customers が 500万行に増えても、LOOP JOIN は Nested Loops を選び続ける。
     500万行を内側にした入れ子ループは事実上終わらない。
     さらに:
       ・原因(推定行数の誤り)を隠すので、同じ誤りが他のクエリでも悪さをし続ける。
       ・Adaptive Join やメモリ許可フィードバックは「選択の余地」があるときだけ
         働くので、★ 将来のバージョンアップの恩恵も受けられなくなる。
       ・指定した方式が物理的に不可能になると(例: 非等値結合に MERGE JOIN)
         ★ ある日突然クエリがエラーで落ちる。

   ■ 修正版
     SELECT c.CustomerName, COUNT(*) AS 件数
     FROM   dbo.OrdersBig AS o
     INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
     GROUP  BY c.CustomerName;                     -- ヒントを外すだけ

   ■ 結合ヒントに手を伸ばす前に試すこと(★ この順番で)
     ① 統計を更新する                                      → 27章
     ② 推定行数と実際の行数の乖離を特定する                  → 18章 / 27章
     ③ SARGable に書き換える                               → 18章
     ④ インデックスを足す / 直す                            → 18章
     ⑤ 中間結果を一時テーブルに落として統計を持たせる        → 15章
     ⑥ OPTION (RECOMPILE) / OPTIMIZE FOR                    → 28章
     ⑦ Query Store でプランを固定する                       → 24章
        ★ ソースコードを書き換えずに固定でき、後から解除できるので
          ヒントより優先して検討する価値がある。
     ────────────────────────────────
     ⑧ ここではじめて結合ヒント

   ■ それでもヒントを使うなら
     ・「なぜ・いつ・誰が」をコメントで残す(数年後に必ず「これ何?」となる)
     ・見直す期限を決める(「データ量が10倍になったら再評価」など)
     ・ヒントを外したときのプランを、外す前に記録しておく               */

------------------------------------------------------------
-- Q17. 【必須】後片付け — 演習前の状態に戻す
------------------------------------------------------------

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ① この演習で作成したインデックスをすべて削除する
--    DROP INDEX IF EXISTS は SQL Server 2016+(存在しなくてもエラーにならない)
DROP INDEX IF EXISTS IX_OrdersBig_CustomerId ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_EmployeeId ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate  ON dbo.OrdersBig;
GO

-- ② 確認: PK_OrdersBig(CLUSTERED)だけが残っていれば成功
SELECT i.name      AS インデックス名,
       i.type_desc AS 種別
FROM   sys.indexes AS i
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
ORDER  BY i.index_id;

-- ③ データベース スコープ構成が既定(0)に戻っていることを確認
SELECT name AS 設定名, value AS 現在値
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';

-- ④ サーバー設定が元の値に戻っていることを確認
--    (既定は max degree of parallelism = 0 / cost threshold for parallelism = 5)
SELECT name         AS 設定名,
       value        AS 設定値,
       value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism',
                N'cost threshold for parallelism');
GO

/* 補足:
   ・PK_OrdersBig は主キー制約に紐づくクラスタ化インデックスなので、
     DROP INDEX では削除できない。ここでは残しておくのが正しい状態。
   ・途中でおかしくなったら sample-db/03_bulk_data.sql を再実行すれば
     dbo.OrdersBig を丸ごと作り直せる(小さいテーブルには一切影響しない)。
     ★ ただしサーバー設定は元に戻らない。設定は必ず自分で戻すこと。

   ★ この章の要点(復習)
     ・論理結合(INNER/LEFT…)と物理演算子(Loops/Merge/Hash)は別物。
       決めているのは「流れる行数」と「インデックス」と「推定の正しさ」。
     ・Nested Loops … 外側が小さい・内側にインデックス・1回の取得が少ない、
                      3条件が揃ってはじめて最速。非等値結合で使える唯一の方式。
     ・Merge Join   … 両側がソート済みなら最強。Sort が要るなら一転して高コスト。
     ・Hash Join    … ソートもインデックスも不要だが ★ メモリを大量に使う。
                      build 側の選択ミスで破綻する。
     ・メモリ許可はコンパイル時の推定行数で決まり、実行中は変えられない。
         過小推定 → tempdb にスピル(自分が遅い)
         過大推定 → 他クエリが RESOURCE_SEMAPHORE で待つ(他人が遅い)
       → 足りないのはメモリではなく「推定の精度」であることがほとんど。
     ・並列は CPU 時間 > 経過時間 で判定。CXCONSUMER は無害、CXPACKET は要調査。
     ・設定を変えたら ★ 必ず戻す。検証はいちばん狭い OPTION (MAXDOP n) から。 */
