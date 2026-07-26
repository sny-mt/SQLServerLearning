/* ============================================================
   解答例 11 — 条件式と NULL 処理
   対象演習: exercises/11_conditional_null.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. Email 未登録を「(未登録)」表示(COALESCE)
--     中村大輔(EmployeeId=8)が「(未登録)」になる。
SELECT LastName, FirstName,
       COALESCE(Email, N'(未登録)') AS メール
FROM   dbo.Employees;

-- Q2. 同じことを ISNULL で。結果は同じ。
--     違い: COALESCE は ANSI 標準・引数可変・戻り型はデータ型優先順位で決まる。
--           ISNULL は SQL Server 専用・2引数固定・戻り型は第1引数の型に合わせる。
SELECT LastName, FirstName,
       ISNULL(Email, N'(未登録)') AS メール
FROM   dbo.Employees;

-- Q3. 給与区分(検索 CASE)
SELECT LastName, FirstName, Salary,
       CASE
           WHEN Salary >= 800000 THEN N'高'
           WHEN Salary >= 500000 THEN N'中'
           ELSE                       N'低'
       END AS 給与区分
FROM   dbo.Employees;

-- Q4. DepartmentId を単純 CASE で部署名に。NULL は「未配属」。
--     ※ 単純 CASE の WHEN NULL は = 比較のため一致しない。
--       NULL は ELSE に落ちて「未配属」になる。
SELECT LastName, DepartmentId,
       CASE DepartmentId
           WHEN 1 THEN N'営業部'
           WHEN 2 THEN N'開発部'
           WHEN 3 THEN N'マーケティング部'
           WHEN 4 THEN N'人事部'
           WHEN 5 THEN N'経理部'
           ELSE        N'未配属'
       END AS 部署名
FROM   dbo.Employees;

-- Q5. 未出荷フラグ(IIF)。1006 と 1012 が「未出荷」。
SELECT OrderId, OrderDate, ShipDate,
       IIF(ShipDate IS NULL, N'未出荷', N'出荷済') AS 出荷状況
FROM   dbo.Orders;

-- Q6. CategoryId NULL を「未分類」表示(COALESCE)
--     CategoryId は数値なので、文字列の既定値とそろえるため文字列に変換してから連結する。
--     高級万年筆・ノベルティグッズが「未分類」になる。
SELECT ProductName,
       COALESCE(CAST(CategoryId AS NVARCHAR(10)), N'未分類') AS カテゴリ表示
FROM   dbo.Products;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q7. COUNT(*) と COUNT(Email) の違い
--     COUNT(*) = 13(全行)、COUNT(Email) = 12(Email が NULL の中村を無視)。
--     集約関数(COUNT(列)/SUM/AVG/MIN/MAX)は NULL を無視するため差が出る。
SELECT COUNT(*)     AS 全社員数,
       COUNT(Email) AS メール登録数
FROM   dbo.Employees;

-- Q8. DepartmentId で集計。NULL(佐々木彩)は 1 グループにまとまる。
SELECT DepartmentId, COUNT(*) AS 人数
FROM   dbo.Employees
GROUP  BY DepartmentId;

-- (ラベル版) NULL を「未配属」にして集計。
--     別名は GROUP BY で使えないため、同じ式を両方に書く。
SELECT COALESCE(CAST(DepartmentId AS NVARCHAR(10)), N'未配属') AS 部署,
       COUNT(*) AS 人数
FROM   dbo.Employees
GROUP  BY COALESCE(CAST(DepartmentId AS NVARCHAR(10)), N'未配属');

-- Q9. Email 昇順。SQL Server は NULL 最小のため NULL が先頭に来る。
SELECT LastName, Email
FROM   dbo.Employees
ORDER  BY Email ASC;

-- (NULL を最後に回す) CASE の補助キーで NULL を後ろへ。
SELECT LastName, Email
FROM   dbo.Employees
ORDER  BY CASE WHEN Email IS NULL THEN 1 ELSE 0 END,
          Email ASC;

-- Q10. 数量あたり売上。分母 0 を NULLIF で NULL 化してゼロ除算回避。
SELECT ProductId,
       SUM(Quantity)                                 AS 数量計,
       SUM(Quantity * UnitPrice * (1 - Discount))
         / NULLIF(SUM(Quantity), 0)                  AS 数量あたり売上
FROM   dbo.OrderDetails
GROUP  BY ProductId;

-- Q11. 給与区分ごとの人数を横並びで(条件付きカウント)
SELECT
    SUM(CASE WHEN Salary >= 800000 THEN 1 ELSE 0 END) AS 高,
    SUM(CASE WHEN Salary >= 500000
             AND  Salary <  800000 THEN 1 ELSE 0 END) AS 中,
    SUM(CASE WHEN Salary <  500000 THEN 1 ELSE 0 END) AS 低
FROM   dbo.Employees;

-- (別解) COUNT(CASE WHEN 条件 THEN 1 END) でも同じ(ELSE 無し→NULL を COUNT が無視)。
SELECT
    COUNT(CASE WHEN Salary >= 800000 THEN 1 END) AS 高,
    COUNT(CASE WHEN Salary >= 500000
               AND  Salary <  800000 THEN 1 END) AS 中,
    COUNT(CASE WHEN Salary <  500000 THEN 1 END) AS 低
FROM   dbo.Employees;

-- Q12. 価格帯で区分して商品数・平均単価(GROUP BY に CASE)
SELECT CASE WHEN UnitPrice >= 10000 THEN N'高価格'
            WHEN UnitPrice >= 1000  THEN N'中価格'
            ELSE                         N'低価格'
       END            AS 価格帯,
       COUNT(*)       AS 商品数,
       AVG(UnitPrice) AS 平均単価
FROM   dbo.Products
GROUP  BY CASE WHEN UnitPrice >= 10000 THEN N'高価格'
               WHEN UnitPrice >= 1000  THEN N'中価格'
               ELSE                         N'低価格'
          END;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q13. 理由: + 連結は片方が NULL だと結果全体が NULL(NULL 伝播)。
--       Email が NULL の中村は連絡先が丸ごと NULL になる。
--       → NULL を空文字扱いする CONCAT / CONCAT_WS で氏名を残す。
SELECT LastName,
       CONCAT(LastName, N' <', Email, N'>')      AS 連絡先_CONCAT,   -- NULL は空文字
       CONCAT_WS(N' ', LastName, Email)          AS 連絡先_WS        -- NULL 引数は飛ばす
FROM   dbo.Employees;

-- Q14. 出荷済み売上 と 全売上 を1行に(SUM(CASE ...))
SELECT
    SUM(CASE WHEN o.ShipDate IS NOT NULL
             THEN od.Quantity * od.UnitPrice * (1 - od.Discount)
             ELSE 0 END)                                AS 出荷済売上,
    SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 全売上
FROM   dbo.Orders       AS o
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId;

-- Q15. 担当者ID = 受注担当 → 顧客の営業担当 → 0 の優先順(COALESCE)
--       ISNULL は2引数固定なので3候補を一度に書けず、
--       ISNULL(ISNULL(o.EmployeeId, c.SalesRepId), 0) と入れ子にする必要がある。
--       COALESCE なら候補を並べるだけで済む。
SELECT o.OrderId,
       o.EmployeeId,
       c.SalesRepId,
       COALESCE(o.EmployeeId, c.SalesRepId, 0) AS 担当者ID
FROM   dbo.Orders    AS o
JOIN   dbo.Customers AS c ON c.CustomerId = o.CustomerId;

-- Q16. CHOOSE で DepartmentId(1〜5)を部署名に。
--       索引が 1 未満・個数超・NULL のときは NULL を返すため、
--       DepartmentId=NULL の佐々木彩は結果も NULL になる。
--       CHOOSE は「索引が 1 始まりの連番に対応している」場合にだけ使える。
--       歯抜けや NULL を別ラベルにしたいなら CASE を使う。
SELECT LastName, DepartmentId,
       CHOOSE(DepartmentId, N'営業部', N'開発部', N'マーケ部', N'人事部', N'経理部')
         AS 部署名
FROM   dbo.Employees;
