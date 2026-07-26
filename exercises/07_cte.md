# 演習 07 — 共通表式 (CTE) と再帰

対象解説: [docs/07_cte.md](../docs/07_cte.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/07_cte.sql](solutions/07_cte.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

社員の上司関係は `Employees.ManagerId`(自己参照)で表され、**社長は EmployeeId 1(佐藤太郎)**、
その `ManagerId` は `NULL` です。

---

## 基礎

**Q1.** CTE `HighPaid` を定義して、`Salary` が 500000 以上の社員(`EmployeeId`・`LastName`・
`FirstName`・`Salary`)を抽出し、給与の降順で表示しなさい。

**Q2.** CTE を使って、部署ごとの平均給与を求める `DeptAvg`(`DepartmentId`・平均給与)を作り、
それを `Departments` と結合して「部署名・平均給与」を表示しなさい。
(`DepartmentId` が NULL の社員は集計対象外でよい)

**Q3.** 次のクエリはエラーになります。**理由を説明**し、正しく動くように直しなさい。

```sql
WITH HighPaid AS (
    SELECT EmployeeId, Salary FROM dbo.Employees WHERE Salary >= 500000
)
SELECT COUNT(*) FROM HighPaid;
SELECT AVG(Salary) FROM HighPaid;   -- ここでエラー
```

---

## 応用

**Q4.** 2 つの CTE を連結して、「自部署の平均給与を上回る社員」を求めなさい。
出力は `LastName`・`FirstName`・`Salary`・自部署平均、給与の降順。
(ヒント: ①部署別平均を作る CTE → ②それを社員に結合して絞り込む CTE)

**Q5.** 再帰 CTE で組織階層を展開しなさい。社長を **レベル 1** とし、各社員の
`EmployeeId`・`LastName`・`FirstName`・`ManagerId`・階層レベルを出力し、
レベル・`EmployeeId` の順に並べなさい。

**Q6.** Q5 を発展させ、`REPLICATE` を使って氏名を階層レベルに応じてインデント表示しなさい
(例: レベル 2 なら全角スペース 1 個ぶん字下げ)。組織図のように見えることを確認すること。

---

## チャレンジ

**Q7.** 再帰 CTE で、各社員について「社長からその社員までの上司チェーン」を
`佐藤太郎 > 鈴木花子 > 田中健` のような文字列(パス)にして表示しなさい。
`EmployeeId`・階層レベル・パスを出力すること。
(ヒント: アンカーの文字列は `CAST(... AS NVARCHAR(400))` で長さを固定する)

**Q8.** 特定の管理職(例: 伊藤愛 = EmployeeId 5)を起点に、その **配下の全社員(部分ツリー)** を
再帰 CTE で列挙しなさい。起点をレベル 1 とすること。
(ヒント: アンカーの `WHERE` を `EmployeeId = 5` にする)

**Q9.** 再帰 CTE に `OPTION (MAXRECURSION n)` を付ける意味を説明しなさい。
また、既定の上限は何回か、`MAXRECURSION 0` は何を意味するかを述べなさい。
実際に Q5 のクエリへ `OPTION (MAXRECURSION 2)` を付けるとどうなるか予想し、実行して確かめなさい。
