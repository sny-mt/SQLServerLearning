/* ============================================================
   解答例 07 — 共通表式 (CTE) と再帰
   対象演習: exercises/07_cte.md
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. CTE HighPaid: 給与 500000 以上を降順で
WITH HighPaid AS (
    SELECT EmployeeId, LastName, FirstName, Salary
    FROM   dbo.Employees
    WHERE  Salary >= 500000
)
SELECT EmployeeId, LastName, FirstName, Salary
FROM   HighPaid
ORDER  BY Salary DESC;

-- Q2. 部署別平均を CTE にして部署名と結合
WITH DeptAvg AS (
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees
    WHERE  DepartmentId IS NOT NULL
    GROUP  BY DepartmentId
)
SELECT d.DepartmentName AS 部署名,
       a.平均給与
FROM   dbo.Departments AS d
JOIN   DeptAvg AS a ON a.DepartmentId = d.DepartmentId
ORDER  BY a.平均給与 DESC;

-- Q3. 理由: CTE は「直後の 1 文」でのみ有効。1 つ目の SELECT で HighPaid は
--     使い切られており、2 つ目の SELECT からは見えないためエラーになる。
--     → 必要な集計を 1 文にまとめる(または CTE 定義を各文の前に書き直す)。
WITH HighPaid AS (
    SELECT EmployeeId, Salary FROM dbo.Employees WHERE Salary >= 500000
)
SELECT COUNT(*) AS 人数, AVG(Salary) AS 平均給与
FROM   HighPaid;

-- (別解) 2 つの結果が欲しいなら、それぞれの文の前で CTE を定義し直す
WITH HighPaid AS (
    SELECT EmployeeId, Salary FROM dbo.Employees WHERE Salary >= 500000
)
SELECT COUNT(*) AS 人数 FROM HighPaid;

WITH HighPaid AS (
    SELECT EmployeeId, Salary FROM dbo.Employees WHERE Salary >= 500000
)
SELECT AVG(Salary) AS 平均給与 FROM HighPaid;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q4. 2 つの CTE を連結: 自部署平均を上回る社員
WITH DeptAvg AS (
    -- ① 部署別平均
    SELECT DepartmentId, AVG(Salary) AS 平均給与
    FROM   dbo.Employees
    WHERE  DepartmentId IS NOT NULL
    GROUP  BY DepartmentId
),
AboveAvg AS (
    -- ② 自部署平均を上回る社員(①を参照)
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.Salary, a.平均給与
    FROM   dbo.Employees AS e
    JOIN   DeptAvg AS a ON a.DepartmentId = e.DepartmentId
    WHERE  e.Salary > a.平均給与
)
SELECT LastName, FirstName, Salary, 平均給与
FROM   AboveAvg
ORDER  BY Salary DESC;

-- Q5. 再帰 CTE で組織階層を展開(社長=レベル1)
WITH OrgTree AS (
    -- アンカー: 社長(上司なし)
    SELECT e.EmployeeId,
           e.LastName,
           e.FirstName,
           e.ManagerId,
           1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL

    UNION ALL

    -- 再帰: 1 段上の社員が OrgTree に居る社員を取り込み、レベル+1
    SELECT e.EmployeeId,
           e.LastName,
           e.FirstName,
           e.ManagerId,
           t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   OrgTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT レベル, EmployeeId, LastName, FirstName, ManagerId
FROM   OrgTree
ORDER  BY レベル, EmployeeId;

-- Q6. Q5 にインデント表示を追加(全角スペースで字下げ)
WITH OrgTree AS (
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, 1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   OrgTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT レベル,
       REPLICATE(N'　', レベル - 1) + LastName + FirstName AS 氏名インデント,
       EmployeeId,
       ManagerId
FROM   OrgTree
ORDER  BY レベル, EmployeeId;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q7. 社長からのパス(上司チェーン)を文字列化
WITH Path AS (
    -- アンカー: 社長。パスは自分の氏名だけ。型を NVARCHAR(400) に固定しておく
    SELECT e.EmployeeId,
           e.ManagerId,
           CAST(e.LastName + e.FirstName AS NVARCHAR(400)) AS パス,
           1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL

    UNION ALL

    -- 再帰: 親のパスに ' > 本人' を継ぎ足す
    SELECT e.EmployeeId,
           e.ManagerId,
           CAST(p.パス + N' > ' + e.LastName + e.FirstName AS NVARCHAR(400)),
           p.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   Path AS p ON e.ManagerId = p.EmployeeId
)
SELECT EmployeeId, レベル, パス
FROM   Path
ORDER  BY パス;

-- Q8. 特定管理職(伊藤愛=EmployeeId 5)の配下ツリーを列挙(起点=レベル1)
WITH SubTree AS (
    -- アンカー: 起点となる社員そのもの
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, 1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.EmployeeId = 5

    UNION ALL

    -- 再帰: その配下をたどる
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   SubTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT レベル, EmployeeId, LastName, FirstName, ManagerId
FROM   SubTree
ORDER  BY レベル, EmployeeId;

-- Q9. 説明:
--   OPTION (MAXRECURSION n) は再帰 CTE の再帰回数の上限を指定するクエリヒント。
--   循環参照などによる無限ループを防ぐ安全装置で、上限を超えるとエラーで停止する。
--   ・既定の上限は 100 回。
--   ・n は 0〜32767。MAXRECURSION 0 は「無制限」を意味する(循環が無いと確信できる場合のみ)。
--   ・このデータの階層は最大 3 レベルなので、MAXRECURSION 2 を付けると
--     3 段目(担当者)に到達する前に上限に達し、
--     「ステートメントが終了しました。文の完了前に最大再帰数 2 を使い果たしました。」
--     というエラーになる(それまでの部分結果は返るがエラー扱い)。
WITH OrgTree AS (
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, 1 AS レベル
    FROM   dbo.Employees AS e
    WHERE  e.ManagerId IS NULL
    UNION ALL
    SELECT e.EmployeeId, e.LastName, e.FirstName, e.ManagerId, t.レベル + 1
    FROM   dbo.Employees AS e
    JOIN   OrgTree AS t ON e.ManagerId = t.EmployeeId
)
SELECT レベル, EmployeeId, LastName, FirstName, ManagerId
FROM   OrgTree
ORDER  BY レベル, EmployeeId
OPTION (MAXRECURSION 2);   -- 3 レベル目で上限超過エラーになることを確認
