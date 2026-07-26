# 演習 13 — データ操作 (INSERT / UPDATE / DELETE / MERGE)

対象解説: [docs/13_dml.md](../docs/13_dml.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/13_dml.sql](solutions/13_dml.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

> ⚠️ **サンプルDBを壊さないこと。すべての問題は次のどちらかで実行すること。**
> - `BEGIN TRAN` で始め、確認したら **必ず `ROLLBACK`** で元に戻す。
> - もしくは `SELECT * INTO #コピー FROM 本物のテーブル` で **一時テーブルにコピー**し、
>   コピーの方を操作する。
>
> 本番テーブルに対して `COMMIT` してはいけません(この演習では常に取り消します)。

---

## 基礎

**Q1.** `dbo.Employees` に新しい社員を1人追加しなさい。
値は `EmployeeId=14`, 姓 `新井`, 名 `翔太`, `DepartmentId=1`(営業部), `ManagerId=1`,
`HireDate='2024-04-01'`, `Salary=400000`, `Email='arai@example.com'`。
追加後に `SELECT` で確認し、最後に `ROLLBACK` で戻すこと。列リストは必ず明示すること。

**Q2.** `dbo.Categories` に、`(6, N'雑貨')` `(7, N'ソフトウェア')` の **2行を1文で** 追加しなさい。
確認後 `ROLLBACK` すること。

**Q3.** `dbo.Products` の商品 `ProductId=2`(ワイヤレスマウス)の単価(`UnitPrice`)を
**10%値下げ**する `UPDATE` を書きなさい(`UnitPrice * 0.9`)。更新後に対象行を `SELECT` で確認し、
`ROLLBACK` すること。

**Q4.** `dbo.Categories` から `CategoryId=5`(書籍)の行を削除する `DELETE` を書きなさい。
`@@ROWCOUNT` で削除件数を確認し、`ROLLBACK` すること。

---

## 応用

**Q5.** **UPDATE ... FROM を使った結合更新。** `開発部`(`DepartmentName = N'開発部'`)に
所属する社員全員を **5%昇給**(`Salary * 1.05`)しなさい。`Departments` と結合して
部門名で絞り込むこと。更新後、開発部の社員の給与を `SELECT` で確認し `ROLLBACK` すること。

**Q6.** **廃番商品の扱い。** `dbo.Products` のうち `Discontinued = 1`(廃番)で、かつ
**どの注文明細(`OrderDetails`)にも使われていない**商品を `DELETE` しなさい
(`NOT EXISTS` を使う)。削除件数を `@@ROWCOUNT` で確認し `ROLLBACK` すること。
(ヒント: 廃番は USBハブ=5 とホチキス=12。注文で使われている方は外部キーの都合でも消せない)

**Q7.** **INSERT ... SELECT で売上集計テーブルを作る。** 一時テーブル
`#SalesSummary(ProductId, ProductName, 合計数量, 売上合計)` を `CREATE TABLE` で作り、
`OrderDetails` を **商品ごとに集計**して流し込みなさい。
売上は `Quantity * UnitPrice * (1 - Discount)` の合計。
流し込んだ後、売上合計の高い順に `SELECT` で確認すること(一時テーブルなので `ROLLBACK` 不要でもよいが、
`BEGIN TRAN ... ROLLBACK` で囲んでおくとより安全)。

**Q8.** **OUTPUT 句。** `経理部`(`DepartmentId=5`)…ではなく `人事部`(`DepartmentName=N'人事部'`)の
社員を **3%昇給**する `UPDATE` に `OUTPUT` を付け、`EmployeeId`・昇給前給与・昇給後給与の
3列を出力しなさい(`deleted` が昇給前、`inserted` が昇給後)。`ROLLBACK` すること。

---

## チャレンジ

**Q9.** **WHERE 付け忘れの危険を体感する。** 次のクエリはなぜ危険か説明しなさい。
そのうえで、「営業部の社員だけ」を対象にする **正しい `UPDATE`** に直しなさい
(直したものは `BEGIN TRAN ... ROLLBACK` で囲むこと)。

```sql
UPDATE dbo.Employees SET Salary = Salary + 50000;
```

**Q10.** **MERGE による UPSERT。** `Categories` のコピー `#CatTarget` を作り、
次のソースを `MERGE` で反映しなさい。
- `(3, N'ステーショナリー')` … 既存(3=文房具)→ **名称を更新**
- `(6, N'雑貨')` … 新規 → **追加**

`WHEN MATCHED` と `WHEN NOT MATCHED BY TARGET` を使い、`OUTPUT $action` で
各行が INSERT / UPDATE のどちらで処理されたかを表示すること。文末のセミコロンを忘れないこと。

**Q11.** **MERGE で在庫マスタを同期する(BY SOURCE を含む3方向)。** 一時テーブル
`#Stock(ProductId, Qty)` を作り、`(1,10),(2,5),(99,0)` を入れておく(99 は今は存在しない商品)。
次に「新しい在庫データ」ソース `(1,8),(2,7),(3,20)` を `MERGE` で反映し、
- 両方にある(1,2)→ `Qty` を新しい値に **更新**
- ソースのみ(3)→ **挿入**
- ターゲットのみ(99)→ **削除**
となるよう `WHEN MATCHED` / `WHEN NOT MATCHED BY TARGET` / `WHEN NOT MATCHED BY SOURCE` の
3節を書きなさい。結果を `SELECT` で確認すること(`#Stock` は一時テーブルなので DB は汚れない)。

**Q12.** **トランザクションの原子性を確認する。** `BEGIN TRAN` の中で
`dbo.Products` を1件 `UPDATE`(任意の1商品を値下げ)し、続けて別の1件を `DELETE` したうえで、
**`ROLLBACK` すると両方とも元に戻る**ことを、`ROLLBACK` の前後で同じ `SELECT` を実行して
確認しなさい。「なぜ2つの操作がまとめて取り消されるのか」を1〜2行で説明すること。
