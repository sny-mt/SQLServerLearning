# 演習 19 — トランザクションと分離レベル

対象解説: [docs/19_transactions_isolation.md](../docs/19_transactions_isolation.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/19_transactions_isolation.sql](solutions/19_transactions_isolation.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

> ⚠️ **この演習の進め方 — 必ず読むこと**
>
> **1. クエリウィンドウを2つ用意する。**
> Q5 以降は **2つのセッション**がないと再現できません。SSMS で「新しいクエリ」(`Ctrl` + `N`)を
> もう1つ開き、両方で `USE SalesLearning;` と `SELECT @@SPID;` を実行して、
> どちらが **セッションA** / **セッションB** か決めてから始めてください。
> 問題文の `【セッションA】` `【セッションB】` と **手順番号の順序どおり**に実行します。
>
> **2. データを変更する例は必ず `BEGIN TRAN` … `ROLLBACK` で戻す。**
> 本物のテーブル(`Employees` / `Products` / `Orders`)に `COMMIT` してはいけません。
> `COMMIT` が必要な実験には、**グローバル一時テーブル `##IsoDemo`** を使います(Q5 の前に作ります)。
>
> **3. 実験用トランザクションを放置しない。**
> 各問の最後、そしてウィンドウを閉じる前に、**両方のセッションで**次を実行して `0` を確認すること。
> ```sql
> IF @@TRANCOUNT > 0 ROLLBACK;
> SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 深さ = 0 であること
> ```
>
> **4. 分離レベルを変えたら必ず戻す。**
> `SET TRANSACTION ISOLATION LEVEL` はセッションに効き続けます。
> 各問の最後に `SET TRANSACTION ISOLATION LEVEL READ COMMITTED;` を実行してください。

---

## 基礎

**Q1.** **`@@TRANCOUNT` とネストの挙動を確かめる。**
次の骨組みの ①〜⑤ の位置で `@@TRANCOUNT` を出力するクエリを書き、
**実行する前に自分で値を予想してから**実行して答え合わせをしなさい。

```sql
--①  BEGIN TRAN;  --②  BEGIN TRAN;  --③  COMMIT;  --④  ROLLBACK;  --⑤
```

そのうえで、次の2点を1〜2行ずつで説明しなさい。
- ③ の `COMMIT` は何をしたのか(何を確定したのか)。
- ④ の `ROLLBACK` はどこまで戻すのか。

**Q2.** **内側の `COMMIT` は確定しないことを、実データで確かめる。**
`BEGIN TRAN` の中で `dbo.Products` の `ProductId = 2` を更新し、さらに内側で `BEGIN TRAN` して
`ProductId = 3` を更新してから内側だけ `COMMIT` しなさい。その後いちばん外側で `ROLLBACK` し、
**内側で `COMMIT` した `ProductId = 3` の変更も消えている**ことを `SELECT` で確認しなさい。

**Q3.** **`SAVE TRANSACTION` で部分的に取り消す。**
1つのトランザクションの中で、
- ① `dbo.Products` の `ProductId = 2`(ワイヤレスマウス)を10%値下げする
- ② セーブポイント `値下げ後` を打つ
- ③ `ProductId = 3`(メカニカルキーボード)の単価を `0` にする
- ④ セーブポイントまで戻して、**③ だけを取り消す**

という手順を書きなさい。④ の直後に `@@TRANCOUNT` と対象2行を `SELECT` して、
「② の変更は残り、③ の変更は消え、トランザクションはまだ開いている」ことを確認し、
最後に全体を `ROLLBACK` すること。

**Q4.** **現在の分離レベルを確認する。**
`sys.dm_exec_sessions` から **自分のセッションの分離レベル**を、数値と日本語名の両方で
表示するクエリを書きなさい(`CASE` で `1`〜`5` を READ UNCOMMITTED〜SNAPSHOT に変換する)。
続けて `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;` を実行してから同じクエリを再実行し、
表示が変わることを確認したうえで `READ COMMITTED` に戻しなさい。

**Q5.** **エラー処理のひな形を書く。**
`SET XACT_ABORT ON` を指定し、`TRY...CATCH` で囲んだトランザクションを書きなさい。
`TRY` の中では `dbo.Employees` の開発部(`DepartmentId = 2`)を1万円昇給させたあと、
**わざと 0 除算エラー**を起こすこと。`CATCH` では
`XACT_STATE()` の値を見て `-1`(コミット不能)なら `ROLLBACK` し、
`ERROR_NUMBER()` / `ERROR_MESSAGE()` / `XACT_STATE()` を表示してから `THROW` しなさい。
最後に `@@TRANCOUNT` が `0` であることを確認すること。

---

## 応用

> ここから2セッションを使います。まず **【セッションA】** で実験用テーブルを作ってください。
> ```sql
> SELECT EmployeeId, LastName, FirstName, DepartmentId, Salary
> INTO   ##IsoDemo
> FROM   dbo.Employees;
> ```
> `##` で始まるグローバル一時テーブルは **他のセッションからも見えます**。
> この中でなら自由に `COMMIT` して構いません(本物のテーブルは変わりません)。

**Q6.** **ダーティリードを再現する。**
- 【セッションA】`##IsoDemo` の `EmployeeId = 3` の `Salary` を `9999999` に `UPDATE`。**`COMMIT` しない**。
- 【セッションB】`READ UNCOMMITTED` にして同じ行を `SELECT`。何が見えるか確認する。
- 【セッションA】`ROLLBACK`。
- 【セッションB】もう一度 `SELECT`。値がどうなったか確認する。

そのうえで「セッションBが読んだ `9999999` は何が問題なのか」を1〜2行で説明しなさい。
最後にセッションBの分離レベルを `READ COMMITTED` に戻すこと。

**Q7.** **同じことを `READ COMMITTED` でやるとどうなるか(ブロッキングの観察)。**
Q6 とまったく同じ手順を、セッションBの分離レベルを **`READ COMMITTED`(既定)** にして実行しなさい。
セッションBの `SELECT` は返ってこないはずです。その状態で
**3つ目のクエリウィンドウ(セッションC)** を開き、次の2つを実行して観察しなさい。

- `sp_who2` を実行し、**`BlkBy` 列**に「待たせている側のSPID」が出ていることを確認する。
- `sys.dm_exec_requests` から、`blocking_session_id <> 0` の行(待っているセッション・
  待たせているセッション・待機種別・待機時間・実行中SQL)を取り出すクエリを書く。

さらに `sys.dm_tran_locks` を使って、**セッションAがどのオブジェクトにどのモードのロックを
握っているか**、および **セッションBのロック要求が `WAIT` 状態であること** を確認するクエリを
書きなさい(`sys.partitions` と結合してオブジェクト名を出すこと)。
最後にセッションAで `ROLLBACK` し、セッションBの `SELECT` が完了することを確認しなさい。

**Q8.** **ノンリピータブルリードを再現し、`REPEATABLE READ` で防ぐ。**
まず既定の `READ COMMITTED` で、
- 【セッションA】`BEGIN TRAN` して `##IsoDemo` の `EmployeeId = 3` を `SELECT`(1回目)
- 【セッションB】同じ行の `Salary` を `500000` に更新して **`COMMIT`**
- 【セッションA】**同じトランザクションの中で**もう一度同じ行を `SELECT`(2回目)

を実行し、1回目と2回目で値が違うことを確認しなさい(確認後 `ROLLBACK`)。
次に、セッションAの分離レベルを **`REPEATABLE READ`** にして同じ手順をやり直し、
- セッションBの `UPDATE` が **ブロックされる**こと
- セッションAは何度読んでも **同じ値**であること
- セッションAが `ROLLBACK` するとセッションBが動き出すこと

を確認しなさい。最後に `##IsoDemo` の `EmployeeId = 3` の `Salary` を `480000` に戻し、
セッションAの分離レベルを `READ COMMITTED` に戻すこと。

**Q9.** **ファントムリードを再現し、`SERIALIZABLE` で防ぐ。**
`REPEATABLE READ` でも防げない異常があることを確認します。
- 【セッションA】`REPEATABLE READ` で `BEGIN TRAN` し、
  `##IsoDemo` の `DepartmentId = 1` の **件数** を数える(1回目)
- 【セッションB】`DepartmentId = 1` の新しい行(`EmployeeId = 14`, 姓 `新井`, 名 `翔太`, `Salary = 400000`)を `INSERT`
- 【セッションA】同じトランザクションの中でもう一度数える(2回目)

件数が変わることを確認したら `ROLLBACK` し、今度は **`SERIALIZABLE`** で同じ手順をやり直して、
**セッションBの `INSERT` 自体がブロックされる**ことを確認しなさい。
「なぜ `REPEATABLE READ` では防げず、`SERIALIZABLE` では防げるのか」を、
**ロックの対象の違い**に触れて2〜3行で説明しなさい。
最後に追加した行を削除し、分離レベルを戻すこと。

**Q10.** **`NOLOCK` の実害を説明する。**
次のクエリについて答えなさい。

```sql
SELECT SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上合計
FROM   dbo.OrderDetails AS od WITH (NOLOCK)
JOIN   dbo.Orders       AS o  WITH (NOLOCK) ON o.OrderId = od.OrderId;
```

1. このヒントを付けると、事実上どの分離レベルで読むことになるか。
2. ダーティリード **以外に**起こり得る問題を **2つ**挙げ、それぞれ何が起きるか説明しなさい。
3. 2 で挙げた問題が「エラーにならない」ことが、なぜ特に危険なのか。
4. 「ブロックされたくない」という当初の目的を、`NOLOCK` を使わずに達成する方法を **3つ**挙げなさい。

---

## チャレンジ

**Q11.** **デッドロックを意図的に起こす。**
`dbo.Employees` と `dbo.Products` を **逆の順序**で更新する2つのトランザクションを書き、
デッドロックを発生させなさい(どちらのセッションも `BEGIN TRAN` のみで `COMMIT` しないこと。
値は変えなくてよいので `SET Salary = Salary` のように **同じ値で更新**すればロックだけ取れる)。

- どちらかのセッションに出るエラー番号は何か。
- 犠牲者に選ばれた側のトランザクションはどうなったか(`@@TRANCOUNT` で確認しなさい)。
- 生き残った側で `ROLLBACK` して後片付けしなさい。
- 続けて、`system_health` 拡張イベントのリングバッファから
  **デッドロックレポート(XML)** を取り出すクエリを書きなさい。
- 最後に、この2つの処理を **デッドロックしないように書き直す**にはどうすればよいか説明しなさい。

**Q12.** **`SNAPSHOT` 分離で「読み手がブロックされない」ことを確認する。**
- `ALTER DATABASE` で `ALLOW_SNAPSHOT_ISOLATION` を `ON` にする。
- 【セッションA】`BEGIN TRAN` で `dbo.Products` の `ProductId = 2` を `UPDATE`(**`COMMIT` しない**)。
- 【セッションB】既定の `READ COMMITTED` で同じ行を `SELECT` → **ブロックされる**ことを確認してキャンセル。
- 【セッションB】`SNAPSHOT` にして同じ `SELECT` → **待たされずに変更前の値**が返ることを確認。
- 【セッションA】`ROLLBACK`。
- 設定を `OFF` に戻す。

そのうえで、「`SNAPSHOT` が返した値はダーティリードではない」のはなぜかを説明し、
`SNAPSHOT` を使う場合に **アプリ側で対処が必要になるエラー**(番号と内容)を挙げなさい。

**Q13.** **分離レベル対応表を自分で埋める。**
次の表を、`○`(防ぐ)/ `×`(起こる)で埋めなさい。
埋めたら解答例と照合し、間違えた行について「なぜそうなるのか」を説明できるようにしなさい。

| 分離レベル | ダーティリード | ノンリピータブルリード | ファントムリード |
|---|---|---|---|
| READ UNCOMMITTED | | | |
| READ COMMITTED | | | |
| REPEATABLE READ | | | |
| SERIALIZABLE | | | |
| SNAPSHOT | | | |
| READ COMMITTED SNAPSHOT | | | |

あわせて、`SNAPSHOT` と `READ COMMITTED SNAPSHOT` の違いを
**「見えるデータの基準時点」** という観点で1行で述べなさい。

**Q14.** **後片付け(必ず実行すること)。**
すべての実験が終わったら、次をすべて実施しなさい。

1. **両方(3つ目を開いたなら3つとも)のセッション**で `@@TRANCOUNT` が `0` であることを確認する
   (`0` でなければ `ROLLBACK` する)。
2. すべてのセッションの分離レベルを `READ COMMITTED` に戻す。
3. `##IsoDemo` を破棄する(存在確認をしてから `DROP TABLE`)。
4. データベースオプション(`ALLOW_SNAPSHOT_ISOLATION` / `READ_COMMITTED_SNAPSHOT`)を `OFF` に戻す。
5. `dbo.Products` の `ProductId = 2, 3` と `dbo.Employees` の `EmployeeId = 3` が
   **元の値のまま**であることを `SELECT` で確認する
   (それぞれ `2800` / `9800` / `480000`)。
