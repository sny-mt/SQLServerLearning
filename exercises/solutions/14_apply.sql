/* ============================================================
   解答例 14 — APPLY (CROSS APPLY / OUTER APPLY)
   対象演習: exercises/14_apply.md

   注意: Q12 で関数を作成します。末尾の DROP FUNCTION まで
         必ず実行して、サンプルDBを散らかさないこと。
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 各顧客の最新の注文1件 (CROSS APPLY)
--     ポイント: 右辺の WHERE から左辺の c.CustomerId を参照できるのが APPLY。
--               TOP には必ず ORDER BY を付け、キーは一意になるまで足す。
SELECT c.CustomerId,
       c.CustomerName AS 顧客名,
       x.OrderId      AS 最新注文Id,
       x.OrderDate    AS 最新注文日
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (1) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerId;

-- Q2. Q1 を OUTER APPLY にする
--     結果: 11行 → 12行に増える。増えるのは顧客11(ラムダソフト)。
--     理由: ラムダソフトには注文が1件も無いため右辺が0行を返す。
--           CROSS APPLY は「右辺が0行なら左行も落とす」(INNER JOIN 的)ので消えていた。
--           OUTER APPLY は左行を残し、右辺の列を NULL で埋める(LEFT JOIN 的)。
SELECT c.CustomerId,
       c.CustomerName AS 顧客名,
       x.OrderId      AS 最新注文Id,
       x.OrderDate    AS 最新注文日
FROM   dbo.Customers AS c
OUTER  APPLY (SELECT TOP (1) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerId;

-- Q3. カテゴリごとに単価が高い商品2件 (CROSS APPLY)
--     CategoryId が NULL の商品(高級万年筆・ノベルティグッズ)が出ない理由:
--     右辺の p.CategoryId = cat.CategoryId は NULL とは決して等しくならないため、
--     どのカテゴリの右辺にも拾われない(NULL の比較は UNKNOWN)。
SELECT cat.CategoryName AS カテゴリ,
       x.ProductName    AS 商品名,
       x.UnitPrice      AS 単価
FROM   dbo.Categories AS cat
CROSS  APPLY (SELECT TOP (2) p.ProductName, p.UnitPrice
              FROM   dbo.Products AS p
              WHERE  p.CategoryId = cat.CategoryId
              ORDER  BY p.UnitPrice DESC, p.ProductId) AS x
ORDER  BY cat.CategoryName, x.UnitPrice DESC;

-- (別解) 同額の2位も含めたいなら TOP (2) WITH TIES
SELECT cat.CategoryName AS カテゴリ,
       x.ProductName    AS 商品名,
       x.UnitPrice      AS 単価
FROM   dbo.Categories AS cat
CROSS  APPLY (SELECT TOP (2) WITH TIES p.ProductName, p.UnitPrice
              FROM   dbo.Products AS p
              WHERE  p.CategoryId = cat.CategoryId
              ORDER  BY p.UnitPrice DESC) AS x
ORDER  BY cat.CategoryName, x.UnitPrice DESC;

-- Q4. 顧客ごとの 最終注文日 / 初回注文日 / 注文件数 を1つの右辺から取得
--     ポイント: 相関サブクエリなら同じ相関条件を3回書くことになるが、
--               APPLY なら右辺1つで複数列をまとめて返せる(これが APPLY の強み)。
--     注意:   右辺が GROUP BY 無しの集約だけなので必ず1行返る。
--             よって CROSS APPLY でも結果は同じで、顧客11 は 注文件数 = 0 になる。
SELECT c.CustomerId,
       c.CustomerName AS 顧客名,
       s.最終注文日,
       s.初回注文日,
       s.注文件数
FROM   dbo.Customers AS c
OUTER  APPLY (SELECT MAX(o.OrderDate) AS 最終注文日,
                     MIN(o.OrderDate) AS 初回注文日,
                     COUNT(*)         AS 注文件数
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId) AS s
ORDER  BY c.CustomerId;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q5. 顧客ごとの最新注文3件 + その注文の明細合計金額 (APPLY を2段)
--     ポイント: 2つ目の APPLY からは、左辺 c だけでなく
--               1つ目の APPLY の結果 x も参照できる(左から右への一方向)。
SELECT c.CustomerName AS 顧客名,
       x.OrderId      AS 注文Id,
       x.OrderDate    AS 注文日,
       t.合計金額
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
CROSS  APPLY (SELECT SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 合計金額
              FROM   dbo.OrderDetails AS od
              WHERE  od.OrderId = x.OrderId) AS t
ORDER  BY c.CustomerName, x.OrderDate DESC;

-- Q6. Q3 と同じ結果を ROW_NUMBER + CTE で
WITH 順位付き AS (
    SELECT p.CategoryId,
           p.ProductName,
           p.UnitPrice,
           ROW_NUMBER() OVER (PARTITION BY p.CategoryId
                              ORDER BY p.UnitPrice DESC, p.ProductId) AS 順位
    FROM   dbo.Products AS p
    WHERE  p.CategoryId IS NOT NULL
)
SELECT cat.CategoryName AS カテゴリ,
       r.ProductName    AS 商品名,
       r.UnitPrice      AS 単価
FROM   順位付き AS r
JOIN   dbo.Categories AS cat ON cat.CategoryId = r.CategoryId
WHERE  r.順位 <= 2
ORDER  BY cat.CategoryName, r.順位;

/* Q6 の考察 — APPLY 版と ROW_NUMBER 版の違い

   - CTE の要否:
       ウィンドウ関数は WHERE では使えない(評価順序の都合)ため、
       ROW_NUMBER 版は必ず CTE/サブクエリで一度列にしてから絞り込む必要がある。
       APPLY 版は右辺に TOP (2) を書くだけで、そのまま FROM に書ける。

   - 親テーブルの扱い:
       APPLY 版は「カテゴリを起点に、そのカテゴリの商品を2件取りに行く」構造。
       ROW_NUMBER 版は「商品全体に番号を振ってから、あとでカテゴリを結合して絞る」構造。

   - 全カテゴリを残したい場合:
       商品が1件も無いカテゴリも行として出したいなら、
       APPLY 版は CROSS APPLY を OUTER APPLY に変えるだけで済む。
       ROW_NUMBER 版は Categories と LEFT JOIN する段をもう1つ足す必要があり手間がかかる。

   - 性能:
       親が少なく N が小さく、子側に (親キー, 並べ替えキー) のインデックスがあれば APPLY が有利。
       親が非常に多い / N が大きいなら、子を1回スキャンする ROW_NUMBER が有利なことが多い。
       いずれにせよ実行プランで確認すること(18章)。
*/

-- Q7. CROSS APPLY (VALUES ...) で 1明細 → 3行に展開
--     ポイント: 右辺の別名は AS v(項目, 値) のように列名まで書く。
--               VALUES の同じ列に入る値は型を揃える(ここでは CAST で明示)。
SELECT od.OrderId   AS 注文Id,
       od.ProductId AS 商品Id,
       v.項目,
       v.値
FROM   dbo.OrderDetails AS od
CROSS  APPLY (VALUES (N'単価', CAST(od.UnitPrice AS DECIMAL(12, 2))),
                     (N'数量', CAST(od.Quantity  AS DECIMAL(12, 2))),
                     (N'金額', CAST(od.Quantity * od.UnitPrice * (1 - od.Discount) AS DECIMAL(12, 2)))
             ) AS v(項目, 値)
WHERE  od.OrderId = 1001
ORDER  BY od.ProductId, v.項目;

-- Q8. CROSS APPLY (VALUES ...) で式に名前を付けて使い回す
--     ポイント: SELECT で付けた別名は同じ SELECT の他の式からは参照できない(1章)。
--               1行1列の VALUES を APPLY すれば、その式に名前を付けて何度でも使える。
--               CROSS APPLY (VALUES (...)) は必ず1行返すので行数は変わらない。
SELECT od.OrderId   AS 注文Id,
       od.ProductId AS 商品Id,
       m.金額,
       m.金額 * 0.1 AS 消費税,
       m.金額 * 1.1 AS 税込金額
FROM   dbo.OrderDetails AS od
CROSS  APPLY (VALUES (od.Quantity * od.UnitPrice * (1 - od.Discount))) AS m(金額)
ORDER  BY od.OrderId, od.ProductId;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

/* Q9. エラーの理由

   Msg 4104: The multi-part identifier "c.CustomerId" could not be bound.

   JOIN の右辺に置いた派生テーブルは「単独で成立する1つの問い合わせ」として評価されるため、
   同じ階層にいる左辺 c の列を参照できない。ON は「できあがった2つの表をどう対応づけるか」を
   書く場所であって、右辺の中身を左辺の行ごとに変えるための仕組みではない。

   TOP (3) を派生テーブルの外側に出す直し方が要件を満たさない理由:
   外側の TOP (3) は「結果全体で3件」になってしまい、
   「顧客ごとに3件」という要件にならないため。TOP は APPLY の右辺に置く必要がある。
*/

-- Q9. 修正版: JOIN ... ON 1 = 1 を CROSS APPLY に変えるだけでよい
SELECT c.CustomerName AS 顧客名,
       x.OrderId      AS 注文Id,
       x.OrderDate    AS 注文日
FROM   dbo.Customers AS c
CROSS  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerName, x.OrderDate DESC;

-- (別解) 注文が無い顧客も一覧に残したいなら OUTER APPLY にする
SELECT c.CustomerName AS 顧客名,
       x.OrderId      AS 注文Id,
       x.OrderDate    AS 注文日
FROM   dbo.Customers AS c
OUTER  APPLY (SELECT TOP (3) o.OrderId, o.OrderDate
              FROM   dbo.Orders AS o
              WHERE  o.CustomerId = c.CustomerId
              ORDER  BY o.OrderDate DESC, o.OrderId DESC) AS x
ORDER  BY c.CustomerName, x.OrderDate DESC;

-- Q10. 各社員の「直属の部下のうち給与が高い順に2名」(部下がいない社員も残す)
--      ポイント: 自己参照なので左辺 m(上司) と右辺 e(部下) で別名を必ず分ける。
--                部下がいない社員(高橋・田中・渡辺 など)も残したいので OUTER APPLY。
SELECT m.EmployeeId                        AS 上司Id,
       m.LastName + N' ' + m.FirstName     AS 上司,
       s.部下,
       s.給与
FROM   dbo.Employees AS m
OUTER  APPLY (SELECT TOP (2) e.LastName + N' ' + e.FirstName AS 部下,
                             e.Salary                        AS 給与
              FROM   dbo.Employees AS e
              WHERE  e.ManagerId = m.EmployeeId
              ORDER  BY e.Salary DESC, e.EmployeeId) AS s
ORDER  BY m.EmployeeId, s.給与 DESC;

-- Q11. STRING_AGG でまとめ → CROSS APPLY STRING_SPLIT で行に戻す
--      STRING_AGG は SQL Server 2017 以降、STRING_SPLIT は 2016 以降(互換性レベル130以上)。
WITH 注文商品 AS (
    SELECT od.OrderId,
           STRING_AGG(CAST(od.ProductId AS NVARCHAR(10)), N',') AS 商品IDリスト
    FROM   dbo.OrderDetails AS od
    GROUP  BY od.OrderId
)
SELECT t.OrderId AS 注文Id,
       t.商品IDリスト,
       CAST(s.value AS INT) AS 商品Id
FROM   注文商品 AS t
CROSS  APPLY STRING_SPLIT(t.商品IDリスト, N',') AS s
ORDER  BY t.OrderId, CAST(s.value AS INT);

/* Q11 の考察 — なぜ JOIN ではなく APPLY か

   STRING_SPLIT はテーブル値関数(表を返す関数)で、その第1引数に
   「行ごとに違う値」である t.商品IDリスト を渡している。
   JOIN の右辺(や FROM のカンマ結合)は左辺と独立に評価されるため、
   そこに左辺の列 t.商品IDリスト を渡すことはできず Q9 と同じ束縛エラーになる。
   左辺の列を引数に取る TVF を呼ぶには APPLY が必須。

   なお STRING_SPLIT の返す value は NVARCHAR なので、数値として扱うなら CAST が必要。
   また分割結果の順序は保証されない(順序が要るなら SQL Server 2022 の ordinal 引数)。
*/

-- Q12. インラインTVF を作って CROSS APPLY で全顧客に適用する
GO
CREATE FUNCTION dbo.fn_顧客直近注文 (@CustomerId INT, @N INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (@N) o.OrderId, o.OrderDate, o.ShipDate
    FROM   dbo.Orders AS o
    WHERE  o.CustomerId = @CustomerId
    ORDER  BY o.OrderDate DESC, o.OrderId DESC;
GO

-- 全顧客に対して直近2件を取得(注文が無い顧客も残すなら OUTER APPLY に変える)
SELECT c.CustomerId,
       c.CustomerName AS 顧客名,
       f.OrderId      AS 注文Id,
       f.OrderDate    AS 注文日,
       f.ShipDate     AS 出荷日
FROM   dbo.Customers AS c
CROSS  APPLY dbo.fn_顧客直近注文(c.CustomerId, 2) AS f
ORDER  BY c.CustomerId, f.OrderDate DESC;
GO

-- ★ 後片付け(必ず実行すること)
DROP FUNCTION dbo.fn_顧客直近注文;
GO
