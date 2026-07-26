# 演習 32 — インメモリOLTP

対象解説: [docs/32_in_memory_oltp.md](../docs/32_in_memory_oltp.md)
使用DB: **`SalesLearningIM`(この演習の中で新規に作る検証用データベース)**

---

> ⚠️ **【最重要】`SalesLearning` には絶対に触らないこと**
>
> メモリ最適化ファイルグループは **一度追加するとデータベースから削除できません**。
> `SalesLearning` に対して `ALTER DATABASE ... ADD FILEGROUP ... CONTAINS MEMORY_OPTIMIZED_DATA`
> を実行してしまうと、**元に戻す手段はデータベースの作り直ししかありません**。
>
> この演習では **Q1 で専用の検証用データベース `SalesLearningIM` を作り、
> すべての作業をその中で行い、Q15 で `DROP DATABASE` して丸ごと捨てます**。
> `SalesLearning` から読み取るのは Q4 のデータコピーのときだけで、書き込みは一切行いません。
>
> 途中で中断する場合も、**必ず Q15 の後片付けだけは実行**してください。

> ⚠️ **前提条件の確認**
> ```sql
> SELECT SERVERPROPERTY('ProductVersion') AS バージョン,
>        SERVERPROPERTY('Edition')        AS エディション,
>        SERVERPROPERTY('IsXTPSupported') AS インメモリOLTP対応;
> ```
> `IsXTPSupported` が `1` で、バージョンが **13.x(SQL Server 2016)以上**であること。
> `0` の場合、この演習は実行できません(解答例を読み物として確認してください)。
> コンテナ用に **数百MB〜数GB のディスク空き容量**も必要です。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/32_in_memory_oltp.sql](solutions/32_in_memory_oltp.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** 検証用データベース **`SalesLearningIM`** を新規に作り、
`MEMORY_OPTIMIZED_DATA` ファイルグループ **`IM_fg`** と、そのコンテナを追加しなさい。
作成後、`sys.filegroups` と `sys.database_files` を結合して、
ファイルグループの種別(`type_desc`)とコンテナの物理パスを表示しなさい。

> ヒント: コンテナの `FILENAME` に指定するのは **これから作られるディレクトリのパス**で、
> **既に存在するディレクトリを指定するとエラー**になります。
> パスは環境依存なので `SERVERPROPERTY('InstanceDefaultDataPath')` から組み立て、
> 動的SQL で `ALTER DATABASE ... ADD FILE` を実行するとよいでしょう。

---

**Q2.** `SalesLearningIM` の中に、**耐久性のあるメモリ最適化テーブル `dbo.OrderQueue`** を
次の仕様で作りなさい。

| 列名 | 型 | 備考 |
|---|---|---|
| `OrderId` | `INT` | NOT NULL・主キー |
| `CustomerId` | `INT` | NOT NULL |
| `EmployeeId` | `INT` | NOT NULL |
| `OrderDate` | `DATE` | NOT NULL |
| `Amount` | `DECIMAL(12, 0)` | NOT NULL |
| `受付時刻` | `DATETIME2(3)` | NOT NULL・既定値は `SYSDATETIME()` |

- 主キーは **ハッシュインデックス**とし、`BUCKET_COUNT` は **262144** にすること。
- `OrderDate` に **範囲検索が可能なインデックス** `IX_OrderQueue_OrderDate` を付けること。
- 耐久性は **`SCHEMA_AND_DATA`** にすること。

> ヒント: メモリ最適化テーブルにクラスタ化インデックスは作れません。

---

**Q3.** `DURABILITY = SCHEMA_ONLY` のメモリ最適化テーブル **`dbo.SessionState`** を作りなさい
(列は `SessionId UNIQUEIDENTIFIER`(主キー・ハッシュ・`BUCKET_COUNT = 65536`)、
`EmployeeId INT`、`最終アクセス DATETIME2(3)`、`状態JSON NVARCHAR(MAX) NULL`)。
作成後、`sys.tables` を使って **2つのテーブルの `durability_desc` を並べて表示**し、
`SCHEMA_ONLY` と `SCHEMA_AND_DATA` で **何が違うのか**をコメントで説明しなさい
(再起動時の挙動 / ログ / バックアップの3点に触れること)。

---

**Q4.** `SalesLearning` から実データを持ってきて `dbo.OrderQueue` に入れなさい。

1. `SalesLearning.dbo.Orders` と `SalesLearning.dbo.OrderDetails` から
   注文ごとの合計金額(`Quantity * UnitPrice * (1 - Discount)` の合計)を求め、
   `SalesLearningIM` 内の **ディスクベースの作業表 `dbo.OrdersStage`** に格納する。
2. さらに `SalesLearning.dbo.Customers` と `SalesLearning.dbo.Employees` も
   ローカルの `dbo.Customers` / `dbo.Employees` に複製する。
3. `dbo.OrdersStage` から `dbo.OrderQueue` へ `INSERT` する。

**なぜ「作業表を経由する」必要があるのか**を、実際にクロスDBで直接 `INSERT` を試して
エラーを確認したうえで、コメントで説明しなさい。

---

**Q5.** 同時実行の実験ができるよう、**10万行の合成データ**を作りなさい。
`SalesLearningIM` 内にディスクベースの `dbo.OrdersStageBig` を作り、次の値を持つ 10万行を生成する。

| 列 | 値 |
|---|---|
| `OrderId` | 1〜100000 の連番 |
| `CustomerId` | 連番 % 12 + 1 |
| `EmployeeId` | 連番 % 13 + 1 |
| `OrderDate` | `'2015-01-01'` から `連番 % 3650` 日後 |
| `Amount` | `連番 % 90000 + 1000` |

生成後、`dbo.OrderQueue` に投入し、行数が 100,020 件(Q4 の 20 件 + 10万件)に
なっていることを確認しなさい。

> ヒント: 連番は `VALUES` 句のタリー + `ROW_NUMBER()` のクロス結合で作れます。
> `OrderId` が Q4 のデータ(1001〜1020)と衝突するので、
> Q4 のデータは投入前に削除するか、`OrderId` をずらす工夫をしてください。

---

## 応用

**Q6.** `sys.dm_db_xtp_hash_index_stats` を使って、`dbo.OrderQueue` の
ハッシュインデックスの **総バケット数 / 空バケット数 / 空バケット率 / 平均チェーン長 /
最大チェーン長** を表示しなさい。
そのうえで、この結果が **健全かどうか**を判断し、判断基準をコメントで書きなさい。

---

**Q7.** **バケット数が不足しているとどうなるか**を実測しなさい。

1. `dbo.OrderQueue` と同じ構造で `BUCKET_COUNT = 1024` にしただけのテーブル
   `dbo.OrderQueueBad` を作る。
2. `dbo.OrderQueue` の全行(10万行)をコピーする。
3. `sys.dm_db_xtp_hash_index_stats` で **2つのテーブルの平均チェーン長を並べて比較**する。
4. 両方のテーブルに対して同じ等値検索(`WHERE OrderId = 50000`)を
   `SET STATISTICS TIME ON` で実行し、CPU 時間を比較する。

> ヒント: 差は環境により大きく前後します。**絶対値ではなく倍率**で見てください。

---

**Q8.** **ハッシュインデックスは範囲検索に使えない**ことを、実行プランで確認しなさい。

1. `WHERE OrderId = 50000`(等値)
2. `WHERE OrderId BETWEEN 50000 AND 50100`(範囲)
3. `WHERE OrderDate BETWEEN '2016-01-01' AND '2016-01-31'`(範囲・範囲インデックスあり)

の3つを実行し、それぞれの実行プランの演算子が
**Seek か Scan か / どのインデックスを使っているか**を確認して、結果をコメントで書きなさい。
また、**なぜ 2 だけ Scan になるのか**を説明しなさい。

---

**Q9.** **ネイティブコンパイル ストアドプロシージャ** `dbo.usp_受注登録` を作りなさい。

- 引数: `@OrderId INT`, `@CustomerId INT`, `@EmployeeId INT`, `@Amount DECIMAL(12,0)`
- `dbo.OrderQueue` に1行 `INSERT` する(`OrderDate` は当日の日付)
- `WITH NATIVE_COMPILATION, SCHEMABINDING, EXECUTE AS OWNER` を付け、
  本体は `BEGIN ATOMIC WITH (...)` で書く(分離レベルは `SNAPSHOT`、言語は `Japanese`)

作成後、実際に1行登録し、`sys.dm_os_loaded_modules` を使って
**このプロシージャが本当に DLL としてロードされていること**を確認しなさい。

---

**Q10.** ネイティブコンパイル モジュールの **T-SQL 構文の制限**を、実際にエラーを出して確認しなさい。

1. 本体に **CTE(`WITH ...`)** を書いたネイティブコンパイル プロシージャを作ろうとする。
2. 本体で **ディスクベーステーブル(`dbo.OrdersStage`)を参照する**プロシージャを作ろうとする。

それぞれエラーメッセージを確認し、**「エラーが実行時ではなく作成時に出る」理由**と、
**同じ処理を実現する代替手段**をコメントで説明しなさい。

---

**Q11.** **メモリ最適化テーブル型**を使って、tempdb を使わないテーブル変数を作りなさい。

1. メモリ最適化テーブル型 `dbo.受注明細型`(`OrderId INT` 主キー・ハッシュ・`BUCKET_COUNT = 1024`、
   `CustomerId INT`、`Amount DECIMAL(12,0)`)を作る。
2. その型のテーブル変数を宣言し、`dbo.OrderQueue` から先頭 1000 行を入れる。
3. ローカルの `dbo.Customers` と結合して、顧客別の件数と合計金額を求める。
4. さらに、この型を **TVP(`READONLY` 引数)** として受け取る
   ネイティブコンパイル プロシージャ `dbo.usp_受注一括登録` を作り、3行まとめて登録する。

**通常のテーブル変数と比べて何が違うのか**、利点と注意点をそれぞれ2つ以上コメントで挙げなさい。

---

**Q12.** `sys.dm_db_xtp_table_memory_stats` を使って、
**ユーザーテーブルごとのメモリ使用量(テーブル本体 / インデックス、確保 / 使用)** を
MB 単位で表示しなさい(合計確保MB の降順)。
そのうえで次の2点をコメントで説明しなさい。

- `object_id` が **負の値**の行は何か。除外する方法。
- **「確保(allocated)」と「使用(used)」の差が開き続ける**とき、何を疑うべきか。

---

## チャレンジ

**Q13.** **更新競合(エラー 41302)を 2 つのセッションで再現**しなさい。
[19章](../docs/19_transactions_isolation.md) のブロッキング実験と手順は同じですが、
**結果がまったく違う**ことを確認するのが目的です。

1. 【セッションA】`SNAPSHOT` 分離レベルでトランザクションを開き、
   `OrderId = 50000` の行を `UPDATE` する。**コミットしない**。
2. 【セッションB】同じく `SNAPSHOT` で、同じ行を `UPDATE` する。
3. セッションB で何が起きたかを記録する。
4. 両セッションで `ROLLBACK` して後片付けする。

**ディスクベーステーブルなら何が起きていたか**と対比して、
「楽観的並行制御の代償」をコメントでまとめなさい。

---

**Q14.** Q13 のエラーに対応する **リトライロジック**を実装しなさい。

- 最大試行回数 5 回。
- 再試行するエラー番号は **41302 / 41305 / 41325 / 41301**。それ以外は `THROW` で再送出する。
- 再試行の前に短い待機(`WAITFOR DELAY`)を入れる。
- 最終的に何回目で成功したかを表示する。

そのうえで、**「なぜリトライをネイティブコンパイル プロシージャの ATOMIC ブロックの中に
書けないのか」** と、**「リトライ回数が増え続けているとき、何を疑うべきか」** を
コメントで説明しなさい。

---

**Q15.** **クロスコンテナトランザクション**の分離レベル問題を再現し、解決しなさい。

1. 明示的トランザクションの中で、`dbo.OrdersStage`(ディスク)と
   `dbo.OrderQueue`(メモリ最適化)の両方を `SELECT` して、**エラー 41368** を確認する。
2. **テーブルヒント** で解決する。
3. **データベースオプション** で解決する(設定後、`sys.databases` で状態を確認)。
4. さらに、`SET TRANSACTION ISOLATION LEVEL SNAPSHOT` にした状態で
   ディスクテーブルとメモリ最適化テーブルを同時に触ると **別のエラー(41332)** になることを確認する。

4 の挙動が **既存システムへの導入時に何を意味するか**をコメントで説明しなさい。

---

**Q16.**(記述)次の4つのシナリオについて、
**インメモリOLTP を採用すべきか / すべきでないか**を判断し、理由と
「採用する場合の推奨構成(耐久性・インデックス種別)」または
「採用しない場合の代わりの手段(該当する章番号)」をコメントで書きなさい。

- **(a)** IoT 機器から毎秒 5,000 件の測定値が `INSERT` される。
  待機統計の上位が `PAGELATCH_EX`(クラスタ化インデックスの最終ページ)。
- **(b)** 3億行の売上履歴テーブルに対する、年月別・地域別の集計レポートが遅い。
  待機統計の上位が `CXPACKET` と `PAGEIOLATCH_SH`。
- **(c)** Web アプリのセッション状態を保持するテーブルへの読み書きが頻繁で、
  ログ書き込み(`WRITELOG`)が上位。セッションは消えても再ログインすればよい。
- **(d)** 夜間バッチが `#一時テーブル` を大量に作成し、
  `PAGELATCH_UP` が tempdb のシステムページ(`2:1:103` など)に集中している。

---

**Q17.**(**必ず実行**)後片付けをしなさい。

1. `SalesLearningIM` を **`DROP DATABASE` で丸ごと削除**する
   (接続が残っている場合に備え `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` を先に実行)。
2. 削除されたことを `sys.databases` で確認する。
3. **`SalesLearning` が無傷であること**(`MEMORY_OPTIMIZED_DATA_FILEGROUP` が
   存在しないこと)を `sys.filegroups` で確認する。
4. コンテナのディレクトリが OS 側に残っていないかを確認する(残っていれば手動で削除)。
