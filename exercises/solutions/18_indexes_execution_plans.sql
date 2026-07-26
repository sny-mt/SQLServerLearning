/* ============================================================
   解答例 18 — インデックスと実行プラン
   対象演習: exercises/18_indexes_execution_plans.md

   前提: sample-db/03_bulk_data.sql を実行し、dbo.OrdersBig(100万行)
         が作成済みであること。開始時点で非クラスタ化インデックスは0本。

   使い方: SSMS で Ctrl+M(実際の実行プランを含める)を ON にしてから、
           上から順に実行して「演算子名」と「論理読み取り数」を記録する。

   ★ 最後の Q13(後片付け)まで必ず実行すること。
   ※ 論理読み取り数のコメントは目安。環境・バージョンで多少前後する。
   ============================================================ */
USE SalesLearning;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 特定日(2023-06-01)の注文件数【Before の基準値】
--     プラン       : Clustered Index Scan (PK_OrdersBig)
--     論理読み取り : 約 6,000
--     → 274 行を得るために 100万行ぶんのページを全部めくっている。
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

-- Q2. クラスタ化主キーで1行だけ取り出す
--     プラン       : Clustered Index Seek (PK_OrdersBig)
--     論理読み取り : 3〜4
SELECT *
FROM   dbo.OrdersBig
WHERE  OrderId = 500000;

/* Q2 の説明:
   OrderId は「クラスタ化主キー」= テーブル本体が OrderId 順に並んでいる。
   B木のルート→中間→葉と数回たどるだけで目的の行に到達できるので、
   100万行あっても 3〜4 ページしか読まない(木の深さぶんだけ)。
   一方 Q1 の OrderDate には索引が無いため、全ページを走査するしかない。
   → 「どの列で引けるか」を決めているのがインデックス。            */

-- Q3. OrderDate に非クラスタ化インデックスを作る
CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate);
GO

-- Q3(続き). Q1 とまったく同じクエリを再実行【After】
--     プラン       : Index Seek (IX_OrdersBig_OrderDate)
--     論理読み取り : 3〜5
--     → 約 6,000 から一桁台へ。1000 倍以上の改善。
--       COUNT(*) は OrderDate 以外の列を必要としないため、
--       この細い索引だけで完結する(= カバリングできている)。
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

-- Q4. OrdersBig に存在するインデックス一覧
SELECT i.name        AS インデックス名,
       i.type_desc   AS 種別,
       i.is_primary_key AS 主キーか
FROM   sys.indexes AS i
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0                       -- 0 はヒープなので除外
ORDER  BY i.index_id;
GO

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 非SARGable な YEAR() を範囲条件に書き換える
--
-- ✗ Before: 列に関数を適用しているのでシークできない
--     プラン       : Index Scan (IX_OrdersBig_OrderDate)
--     論理読み取り : 約 1,800(索引は本体より細いのでスキャンでも 6,000 より安い)
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  YEAR(OrderDate) = 2023;

-- ○ After: 範囲条件に書き換える(結果は同じ約 100,000 件)
--     プラン       : Index Seek (IX_OrdersBig_OrderDate)
--     論理読み取り : 約 180
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01'
  AND  OrderDate <  '2024-01-01';

/* Q5 の説明:
   インデックスは「OrderDate の値そのもの」を順に並べたもの。
   YEAR(OrderDate) の値は並んでいないので、全行に関数を適用してみるまで
   該当行が分からず、走査するしかない(非SARGable)。
   → 「>= 期間の開始 AND < 翌期間の開始」に書き換えるのが定番イディオム。
     BETWEEN '2023-01-01' AND '2023-12-31' でも DATE なら同値だが、
     列が DATETIME だと 12/31 の時刻付きの行が漏れるため < の形を推奨。 */

-- Q6-1. ✗ 列に算術演算 → ○ 定数側へ移す
SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig WHERE Amount * 2 > 1000;   -- ✗ Scan
SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig WHERE Amount     >  500;   -- ○ 同値な変形

-- Q6-2. ✗ 列を文字列化して比較 → ○ 日付は日付のまま比較
SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig
WHERE  CONVERT(VARCHAR(8), OrderDate, 112) = '20230601';              -- ✗ Scan

SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';                                     -- ○ Seek

-- Q6-3. ✗ ISNULL で列を包む → ○ OR に分けて素の列で比較
SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig
WHERE  ISNULL(ShipDate, '9999-12-31') > '2024-12-01';                -- ✗ Scan

SELECT COUNT(*) AS 件数 FROM dbo.OrdersBig
WHERE  ShipDate IS NULL OR ShipDate > '2024-12-01';                  -- ○

/* Q6 のポイント:
   共通する原則は「WHERE の左辺で列を裸のまま置く」。
   12章で覚えた YEAR / CONVERT / FORMAT / ISNULL は SELECT に書くのは自由だが、
   WHERE・JOIN の左辺に置いた瞬間にインデックスが使えなくなる。
   なお、先頭ワイルドカードの LIKE も同じ理由でシークできない:
       ✗ WHERE Status LIKE N'%了'      ○ WHERE Status LIKE N'完%'          */

-- Q7. Key Lookup を発生させる(Amount はインデックスに入っていない)
--     プラン       : Index Seek (IX_OrdersBig_OrderDate)
--                    + Key Lookup (PK_OrdersBig) + Nested Loops
--     論理読み取り : 約 900
SELECT OrderId, OrderDate, Amount
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

/* Q7 の説明:
   非クラスタ化インデックスの葉には「キー列(OrderDate)＋クラスタ化キー(OrderId)」
   しか入っていない。Amount はそこに無いので、該当した 274 行それぞれについて
   本体(PK_OrdersBig)を引き直す必要がある。これが Key Lookup。
   1行あたり 3〜4 ページのランダムアクセスなので、
   274 行 × 3〜4 ≒ 900 ページとなり、該当行が増えるほど急激に高くつく。 */

-- Q8. クエリを変えずに Key Lookup を消す = カバリングインデックスにする
DROP INDEX IX_OrdersBig_OrderDate ON dbo.OrdersBig;

CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate)
    INCLUDE (Amount);                 -- 検索には使わないが葉に載せておく
GO

-- Q8(続き). Q7 とまったく同じクエリを再実行
--     プラン       : Index Seek (IX_OrdersBig_OrderDate) のみ
--                    → Key Lookup も Nested Loops も消える
--     論理読み取り : 約 5(Q7 の約 900 から 200 分の 1)
SELECT OrderId, OrderDate, Amount
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

/* Q8 のポイント:
   キー列 = WHERE / JOIN / ORDER BY に使う列(順序に意味がある)
   INCLUDE 列 = SELECT に出るだけの列(順序に意味はなく、葉ページにのみ載る)
   ただし SELECT * を丸ごとカバーしようとするとテーブルの複製になるので、
   まず SELECT の列を必要最小限に削るのが先。                         */

-- Q9. Status に非クラスタ化インデックスを作る
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status
    ON dbo.OrdersBig (Status);
GO

-- Q9-1. 保留(約 50,000 行 = 5%)→ Index Seek が選ばれる
SELECT COUNT(*) AS 保留件数
FROM   dbo.OrdersBig
WHERE  Status = N'保留';

-- Q9-2. 完了(約 950,000 行 = 95%)→ 全件走査(Scan)が選ばれる
SELECT COUNT(*) AS 完了件数
FROM   dbo.OrdersBig
WHERE  Status = N'完了';

/* Q9 の説明:
   選択度 = 該当行数 ÷ 全行数。小さいほど「よく絞れる」= インデックス向き。
     N'保留' … 5%   → 絞れるのでシークが有効
     N'完了' … 95%  → ほとんど全部が該当。シークして1行ずつ辿るより
                       端から全部読んだほうが速い、とオプティマイザが判断する
   同じ形のクエリでも「リテラルの値」だけでプランが変わる。統計情報の
   ヒストグラムを見て、実際の分布に基づいて決めているため。

   ⚠ この性質が、ストアドプロシージャでの「パラメーター スニッフィング」問題の正体。
     WHERE Status = @s と書くと初回実行時の引数でプランが固定され、
     逆の値で呼ばれたときに極端に遅くなる。OPTION (RECOMPILE) 等で対処する。 */

-- (参考) ヒストグラムを直接見てみる
DBCC SHOW_STATISTICS ('dbo.OrdersBig', IX_OrdersBig_Status);
GO

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q10. 複合インデックス (Status, OrderDate)
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status_OrderDate
    ON dbo.OrdersBig (Status, OrderDate);
GO

-- Q10-1. 先頭列 Status で絞れる + 2列目でさらに絞れる → 理想的な Seek
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  Status = N'保留'
  AND  OrderDate >= '2023-01-01'
  AND  OrderDate <  '2024-01-01';

-- Q10-2. 先頭列 Status だけで絞る → Seek できる
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  Status = N'保留';

-- Q10-3. 先頭列 Status の条件が無い → Seek できない(良くて Index Scan)
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01'
  AND  OrderDate <  '2024-01-01';

/* Q10 の説明:
   複合インデックスは「姓 → 名」の順に並んだ電話帳と同じ。
     (Status, OrderDate) は Status 順に並び、同じ Status の中で OrderDate 順。
   1・2 は先頭列 Status が決まるので木をたどれる → Seek。
   3 は先頭列が不明なので、どこから探せばよいか決められない → Seek 不可。
     「名が『太郎』の人」を電話帳から探せないのと同じ理屈。

   → (A, B) のインデックスは A 単独の検索にも使えるが、B 単独には使えない。

   もし (OrderDate, Status) の順にしていたら、3 は先頭列 OrderDate で
   絞れるので Index Seek になっていた。逆に 2(Status 単独)が Seek できなくなる。
   つまり「同じ2列だからどちらでもいい」は誤りで、想定クエリで順序を決める。

   列順序の指針:
     ① 等値条件(=)の列を先、範囲条件(>, <, BETWEEN, LIKE 'x%')を後ろに
     ② 等値が複数なら選択度が高い(絞れる)列を先に
     ③ ORDER BY の順序と一致させられれば Sort 演算子を丸ごと省略できる     */

-- Q11. 推定行数と実際の行数の乖離
--     Ctrl+M を ON にして実行し、Index Seek のツールチップで
--     「推定行数」と「実際の行数」を比較する。
DECLARE @d DATE = '2024-12-01';

SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= @d;
GO

/* Q11 の説明:
   ローカル変数の中身はコンパイル時点では未知なので、オプティマイザは
   ヒストグラムを使えず「範囲条件なら全体の約30%」という既定の見積もりを使う。
   → 推定 約 300,000 行 に対して 実際は 約 8,500 行、と桁が違う。
   推定が外れると、結合方式の誤選択や、メモリ確保不足による
   tempdb への spill(プランの警告アイコン)につながる。             */

-- Q11(解消策). OPTION (RECOMPILE) で実際の値を見てからコンパイルさせる
DECLARE @d2 DATE = '2024-12-01';

SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= @d2
OPTION (RECOMPILE);          -- 推定行数が実際の行数とほぼ一致するようになる
GO

/* (別解) 変数を使わずリテラルを直接書く / 統計が古いなら更新する
     SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= '2024-12-01';
     UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN;                        */

-- Q12-a. 各インデックスの使用サイズ
SELECT i.name                       AS インデックス名,
       i.type_desc                  AS 種別,
       SUM(ps.used_page_count) * 8  AS 使用KB,
       SUM(ps.row_count)            AS 行数
FROM   sys.indexes AS i
JOIN   sys.dm_db_partition_stats AS ps
       ON  ps.object_id = i.object_id
       AND ps.index_id  = i.index_id
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
GROUP  BY i.name, i.type_desc
ORDER  BY 使用KB DESC;

-- Q12-b. 各インデックスの使われ方(シーク/スキャン/ルックアップ/更新)
SELECT i.name                        AS インデックス名,
       ISNULL(us.user_seeks,   0)    AS シーク回数,
       ISNULL(us.user_scans,   0)    AS スキャン回数,
       ISNULL(us.user_lookups, 0)    AS ルックアップ回数,
       ISNULL(us.user_updates, 0)    AS 更新回数
FROM   sys.indexes AS i
LEFT   JOIN sys.dm_db_index_usage_stats AS us
       ON  us.object_id   = i.object_id
       AND us.index_id    = i.index_id
       AND us.database_id = DB_ID()
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
ORDER  BY i.index_id;

/* Q12 の考察例:
   - IX_OrdersBig_OrderDate (INCLUDE Amount 付き) … 日付範囲の検索は業務で最頻出。
     カバリングにより Key Lookup も消せるので、残す価値が最も高い。
   - IX_OrdersBig_Status … 単独では選択度が低い(完了95%)。
     「保留の案件だけ探す」用途が本当にあるなら、フィルター選択されたインデックス
        CREATE INDEX ... ON dbo.OrdersBig(OrderDate) WHERE Status = N'保留';
     のほうが小さく更新も軽い。単独インデックスとしては削除候補。
   - IX_OrdersBig_Status_OrderDate … IX_OrdersBig_Status を包含している
     (先頭列が同じ)ので、両方を残す意味は薄い。統合して1本にする。

   判断の原則:
     ・インデックスは「更新コストと容量」を払って「読み取り速度」を買うもの。
     ・user_seeks/scans/lookups がほぼ 0 なのに user_updates が大きいものは削除候補。
       (これらの統計は SQL Server の再起動でリセットされる点に注意)
     ・SSMS のプランに出る「不足しているインデックス」の緑の提案は鵜呑みにしない。
       そのクエリ1本しか見ていないので、INCLUDE に列を並べすぎる傾向がある。
     ・そもそもクエリの書き換え(SARGable 化)で済むならノーコストでそれが最善。   */

------------------------------------------------------------
-- Q13. 【必須】後片付け — 演習前の状態に戻す
------------------------------------------------------------

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- DROP INDEX IF EXISTS は SQL Server 2016+(存在しなくてもエラーにならない)
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate        ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status           ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status_OrderDate ON dbo.OrdersBig;
GO

-- 2016 より前の場合の書き方(参考)
-- IF EXISTS (SELECT 1 FROM sys.indexes
--            WHERE name = 'IX_OrdersBig_OrderDate'
--              AND object_id = OBJECT_ID('dbo.OrdersBig'))
--     DROP INDEX IX_OrdersBig_OrderDate ON dbo.OrdersBig;

-- 確認: PK_OrdersBig(CLUSTERED)だけが残っていれば成功
SELECT i.name      AS インデックス名,
       i.type_desc AS 種別
FROM   sys.indexes AS i
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
ORDER  BY i.index_id;
GO

/* 補足:
   PK_OrdersBig は主キー制約に紐づくクラスタ化インデックスなので、
   DROP INDEX では削除できない(削除するなら ALTER TABLE ... DROP CONSTRAINT)。
   ここでは残しておくのが正しい状態。

   演習をやり直したい / 途中でおかしくなった場合は、
   sample-db/03_bulk_data.sql を再実行すれば OrdersBig を丸ごと作り直せる。
   既存の小さいテーブル(Orders/OrderDetails 等)には一切影響しない。      */
