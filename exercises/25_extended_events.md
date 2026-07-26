# 演習 25 — 拡張イベント (Extended Events)

対象解説: [docs/25_extended_events.md](../docs/25_extended_events.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)
負荷生成: [sample-db/05_workload.sql](../sample-db/05_workload.sql)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/25_extended_events.sql](solutions/25_extended_events.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

> ⚠️ **この演習の進め方 — 必ず読むこと**
>
> **1. サーバーレベルのオブジェクトを作ります。**
> `CREATE EVENT SESSION ... ON SERVER` は **インスタンス全体**に作られます。
> 必要な権限は **`ALTER ANY EVENT SESSION`** と **`VIEW SERVER STATE`** です。
> **共有サーバーでは実施しないでください。** 手元の開発インスタンスで行うこと。
>
> **2. この演習で作るセッション名は `xe_ex25_` で始めます。**
> `xe_ex25_slow` / `xe_ex25_deadlock` / `xe_ex25_blocked` / `xe_ex25_error` /
> `xe_ex25_file` / `xe_ex25_count`。
> 各問の最後で個別に `DROP EVENT SESSION` し、**Q16(後片付けと棚卸し)で残っていないことを必ず確認します。
> 最後まで実行してください。**
>
> **3. クエリウィンドウを2つ以上用意する。**
> Q8 以降は **2つのセッション**がないと再現できません。SSMS で「新しいクエリ」(`Ctrl` + `N`)を
> もう1つ開き、両方で `USE SalesLearning;` と `SELECT @@SPID;` を実行して、
> どちらが **セッションA** / **セッションB** か決めてから始めます。
> 問題文の `【セッションA】` `【セッションB】` と **手順番号の順序どおり**に実行してください。
>
> **4. トランザクションを放置しない。**
> 各問の最後、そしてウィンドウを閉じる前に、**すべてのセッションで**次を実行して `0` を確認すること。
> ```sql
> IF @@TRANCOUNT > 0 ROLLBACK;
> SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 であること
> ```
>
> **5. サーバー設定を変える問(Q11)は、必ず「戻す」までがワンセットです。**
> `blocked process threshold (s)` は **変更前の値を控えてから**変更し、Q11 の最後で戻します。
>
> **6. `event_file` を使う問(Q13)は、事前にフォルダーを作っておくこと。**
> Windows なら **`C:\XE\`** を作り、SQL Server サービスアカウントに書き込み権限を与えます。
> Linux / コンテナーなら **`/var/opt/mssql/log/`** をそのまま使えます。
> **`.xel` ファイルは `DROP EVENT SESSION` しても残ります。** Q13 で OS 側から削除します。
>
> **7. 結果が空でも慌てないこと。**
> `MAX_DISPATCH_LATENCY` の既定は **30 秒**です。この演習では全問 `5 SECONDS` を指定し、
> 読み出す前に `WAITFOR DELAY '00:00:06';` を入れます。

---

## 基礎

**Q1.** **既定で動いているセッションを調べる。**
`sys.dm_xe_sessions` から、**いま実行中の**拡張イベントセッションの名前を一覧しなさい。
続けて `sys.server_event_sessions`(定義)と `sys.dm_xe_sessions`(実行中)を **外部結合**して、
「セッション名 / 起動時に自動開始するか(`startup_state`)/ いま実行中か停止中か」を
1つの表にするクエリを書きなさい。

そのうえで、次を1〜2行ずつで答えなさい。
- `sys.server_event_sessions` と `sys.dm_xe_sessions` は何が違うのか。
- `system_health` が持っている **ターゲットは何個で、それぞれ何か**
  (`sys.dm_xe_session_targets` の `target_name` を見る)。

**Q2.** **イベントを検索する。**
`sys.dm_xe_objects` と `sys.dm_xe_packages` を結合して、次を調べなさい。
- (a) イベント名に `deadlock` を含むものの一覧(パッケージ名・イベント名・説明)
- (b) イベント名に `blocked` を含むものの一覧
- (c) 使用できる **ターゲット**(`object_type = 'target'`)の一覧

いずれも **内部専用(private)オブジェクトを除外**すること
(ヒント: `capabilities & 1 = 0 OR capabilities IS NULL`)。

**Q3.** **`duration` の単位を自分の目で確かめる。**
`sys.dm_xe_object_columns` を使って、次の3つのイベントの列一覧(列名・型・種別・説明)を出しなさい。
- `sql_statement_completed`
- `blocked_process_report`
- `wait_info`

そのうえで **`duration` の単位がイベントによって違う**ことを確認し、
「1秒以上」を条件にしたいとき、それぞれ述語に書くべき数値を答えなさい。

**Q4.** **遅いクエリ捕捉セッションを作る。**
次の仕様で `xe_ex25_slow` という EVENT SESSION を `CREATE` しなさい(まだ開始しない)。

- イベント: `sqlserver.sql_statement_completed` と `sqlserver.rpc_completed` の**2つ**
- アクション(両方に): `session_id` / `database_name` / `client_app_name` / `username` / `sql_text`
- 述語(両方に): **実行時間 100 ミリ秒超** かつ **データベースが `SalesLearning`** かつ
  **`is_system = 0`**。安い条件を左に書くこと
- ターゲット: `package0.ring_buffer`(`max_memory = 4096`, `max_events_limit = 1000`)
- `WITH`: `MAX_MEMORY = 8 MB` / `EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS` /
  `MAX_DISPATCH_LATENCY = 5 SECONDS` / `TRACK_CAUSALITY = OFF` / `STARTUP_STATE = OFF`
- 何度でも実行できるよう、**先頭に「同名があれば `DROP`」** を付けること

作成後、`sys.server_event_session_events` から
**登録されたイベント名と述語文字列**を確認しなさい。

**Q5.** **開始して、捕まえて、XML を表にする。**
Q4 のセッションを開始し、`dbo.OrdersBig`(100万行・非クラスタ化インデックス無し)に対して
わざと遅いクエリを2本流しなさい。

- (a) `Status = N'保留'` の `Amount` 合計
- (b) `YEAR(OrderDate) = 2020` の `Amount` 合計(**わざと SARGable でない書き方**)

6秒待ってから、`ring_buffer` の `target_data` を **XML にキャストして `nodes()` で展開**し、
次の列を持つ表を **実行時間の降順**で出力しなさい。

| イベント種別 | 発生時刻JST | 実行時間ms | CPU時間ms | 論理読み取り | 行数 | セッションID | アプリ名 | 実行された文 |

ヒント:
- `nodes('/RingBufferTarget/event')` で1イベント=1行に展開する。
- イベントの標準列は `data`、追加した情報は `action`。
- `value('(data[@name="duration"]/value)[1]', 'bigint')` の **`[1]` を忘れない**。
- `@timestamp` は **UTC**。`AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'`(2016+)で JST に。

**Q6.** **文ごとに集計する。**
Q5 と同じ `ring_buffer` から、**実行された文ごと**(先頭120文字でグループ化)に
「実行回数 / 合計ms / 平均ms / 最大ms / 合計論理読み取り」を集計し、**合計ms の降順**で出しなさい。

そのうえで、「平均は速いが合計が大きい文」と「1回が極端に遅い文」のどちらを
先にチューニングすべきか、理由とともに1〜2行で答えなさい。

**Q7.** **イベントが落ちていないかを計測する。**
`sys.dm_xe_sessions` から、実行中の全セッションについて
「セッション名 / 落ちたイベント数 / 落ちたバッファ数 / 落ちた最大イベントサイズ /
発火がブロックされた時間」を出しなさい。
`xe_ex25_slow` の `dropped_event_count` が `0` であることを確認し、
**もし 0 でなかったら何を最初に疑うか**を1行で答えなさい。

確認できたら `xe_ex25_slow` を **停止して削除**しなさい。
停止した直後に Q5 の読み出しクエリをもう一度実行し、**結果が0行になる**ことも確認すること
(なぜそうなるかも答えなさい)。

---

## 応用

**Q8.** **デッドロックを起こして捕捉する。**(2セッション)

(1) `xe_ex25_deadlock` という EVENT SESSION を作りなさい。
- イベント: `sqlserver.xml_deadlock_report`(**アクションも述語も付けない**)
- ターゲット: `package0.ring_buffer`(`max_events_limit = 100`)
- `WITH`: `MAX_DISPATCH_LATENCY = 5 SECONDS` / `STARTUP_STATE = OFF`

**なぜこのイベントにはアクションも述語も要らないのか**を1〜2行で説明しなさい。

(2) セッションを開始してから、次の手順でデッドロックを **意図的に発生**させなさい。
本物のテーブルを使いますが、**値を変えない `UPDATE`**(`SET Salary = Salary`)にし、
最後は必ず `ROLLBACK` します。

```
【セッションA】手順1: BEGIN TRAN して dbo.Employees の EmployeeId = 3 を UPDATE
【セッションB】手順2: BEGIN TRAN して dbo.Products  の ProductId  = 2 を UPDATE  (Aと逆順)
【セッションA】手順3: 続けて dbo.Products  の ProductId  = 2 を UPDATE   → 待たされる
【セッションB】手順4: 続けて dbo.Employees の EmployeeId = 3 を UPDATE   → デッドロック成立
【セッションA】【セッションB】手順5: 両方で IF @@TRANCOUNT > 0 ROLLBACK; と @@TRANCOUNT の確認
```

どちらか一方に **エラー 1205** が出ることを確認し、
**そのメッセージに出ている「プロセス ID」** を控えておきなさい。

(3) 6秒待ってから、`xe_ex25_deadlock` の `ring_buffer` から
**デッドロックグラフの XML** を発生時刻(JST)とともに取り出しなさい。

ヒント: データ列の名前は **`xml_deadlock_report`**(イベント名と同じ)。
`x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]')` で `<deadlock>` 要素が取れます。
うまく取れないときは `x.query('.')` で `<event>` を丸ごと表示し、実際の `data name=` を目で確認すること。

**Q9.** **デッドロックグラフを読み解く。**
Q8 で取得した XML を変数 `@dl XML` に入れ、次の2つの表を出すクエリを書きなさい。

(a) **関与したプロセス一覧**

| 判定(★犠牲者/生存) | SPID | 要求ロック | 分離レベル | 待機リソース | アプリ | 実行していたSQL |

- 「犠牲者かどうか」は `/deadlock/victim-list/victimProcess/@id` と
  各 `process` の `@id` を突き合わせて判定すること。
- 「実行していたSQL」は `<inputbuf>` の中身。

(b) **衝突したリソース一覧**

| リソース種別 | オブジェクト | インデックス | 保持しているプロセス | 保持モード | 待っているプロセス | 要求モード |

- `nodes('/deadlock/resource-list/*')` で子要素(`keylock` など)を全部拾い、
  種別は `value('local-name(.)', ...)` で取る。

そのうえで、次に答えなさい。
- 犠牲者の SPID は、Q8(2) のエラーメッセージのプロセス ID と一致したか。
- **今回のデッドロックの根本原因**は何か。19章の対策表のうち、**どれが最も効くか**。

**Q10.** **既定の `system_health` からも同じデッドロックを取り出す。**
自分で作ったセッションを使わず、**`system_health` の `ring_buffer`** から
直近のデッドロックグラフを取り出すクエリを書きなさい。
Q8 で起こしたデッドロックが記録されていることを確認しなさい。

そのうえで、**「`system_health` があるのに、わざわざ自前のセッションを作る理由」** を
3つ挙げなさい。

確認できたら `xe_ex25_deadlock` を停止・削除しなさい。

**Q11.** **ブロッキングを捕捉する。**(2セッション + サーバー設定の変更)

(1) **変更前の値を控える。**
`sys.configurations` から `blocked process threshold (s)` の
`value` と `value_in_use` を出して控えなさい(既定は `0`)。

(2) `sp_configure` で **`blocked process threshold (s)` を 5 秒**に設定し、`RECONFIGURE` しなさい
(`show advanced options` を先に `1` にする必要があります)。

(3) `xe_ex25_blocked` という EVENT SESSION を作って開始しなさい。
- イベント: `sqlserver.blocked_process_report`
- アクション: `database_name` / `client_app_name`
- 述語: データベースが `SalesLearning`
- ターゲット: `package0.ring_buffer`(`max_events_limit = 200`)
- `WITH`: `MAX_DISPATCH_LATENCY = 5 SECONDS`

(4) `sample-db/05_workload.sql` の **準備セクション**を実行して `dbo.WorkloadTest` を用意し、
**セクションC(ブロッカー)** と **セクションD(ブロックされる側)** を
別々のウィンドウで実行してブロッキングを発生させなさい。

```
【セッションA】手順1: セクションC — BEGIN TRAN → WorkloadTest の Id 1〜10 を UPDATE
                        → WAITFOR DELAY '00:00:30' → ROLLBACK
【セッションB】手順2: セクションD — 同じ Id 1〜10 を SELECT   → 待たされる
【セッションC】手順3: セクションE の観測クエリで、誰が誰をブロックしているかを確認
```

**セクションD が返ってくるまでに何秒かかったか**、そして
**なぜ `blocked process threshold` に達しないとイベントが出ないのか**を答えなさい。

(5) `xe_ex25_blocked` の `ring_buffer` から、次の列を持つ表を出しなさい。

| 発生時刻JST | ブロック秒数 | データベース | ロックモード | 待機SPID | 待機側SQL | 待機リソース | ブロック元SPID | ブロック元の状態 | ブロック元SQL |

ヒント: `blocked_process` データ列の中身は `<blocked-process-report>` という XML です。
`x.query('(data[@name="blocked_process"]/value/blocked-process-report)[1]')` で取り出し、
`/blocked-process-report/blocked-process/process/...` と
`/blocked-process-report/blocking-process/process/...` から値を拾います。

そのうえで、**ブロック元の `status`** が `running` / `suspended` / `sleeping` の
それぞれだった場合に「何を疑うべきか」を1行ずつで答えなさい。

(6) **★必ず実行**: `blocked process threshold (s)` を (1) で控えた値(既定 `0`)に戻し、
`RECONFIGURE` して `value_in_use` が戻ったことを確認しなさい。
`show advanced options` も `0` に戻すこと。
`xe_ex25_blocked` も停止・削除すること。

**Q12.** **エラーを捕捉して、生ログと集計の両方で見る。**

(1) `xe_ex25_error` という EVENT SESSION を作って開始しなさい。
- イベント: `sqlserver.error_reported`
- アクション: `session_id` / `database_name` / `client_app_name` / `username` / `sql_text`
- 述語: **`severity >= 11`** かつ データベースが `SalesLearning` かつ `is_system = 0`
- ターゲットは **2つ**:
  - `package0.ring_buffer`(`max_events_limit = 500`)
  - `package0.histogram`(`filtering_event_name = N'sqlserver.error_reported'`,
    `source = N'error_number'`, **`source_type = 0`**)

**`source_type` を `0` にする理由**を1行で答えなさい(既定値は何か)。

(2) わざと次の4種類のエラーを起こしなさい(いずれも `SalesLearning` のデータは変わりません)。
- 存在しないテーブルへの `SELECT`
- ゼロ除算
- `RAISERROR` で重大度 16 のメッセージ
- `dbo.Departments` に `DepartmentId = 1` を `INSERT`(主キー違反)

(3) 6秒待ってから、`ring_buffer` から
「発生時刻JST / エラー番号 / 重大度 / 状態 / メッセージ / セッションID / アプリ / 実行SQL」を、
`histogram` から「エラー番号 / 件数」を、それぞれ取り出しなさい。

(4) 4種類それぞれの **エラー番号**を答えなさい。
また、`error_reported` を **本番で使うときに必ず入れるべき述語**を2つ挙げなさい。

確認できたら `xe_ex25_error` を停止・削除しなさい。

---

## チャレンジ

**Q13.** **`event_file` で永続化して、停止後にも読む。**

(1) `xe_ex25_file` という EVENT SESSION を作りなさい。
- イベント: `sqlserver.sql_statement_completed`
  (述語: `duration > 50000` かつ `database_name = N'SalesLearning'` かつ `is_system = 0`)
- アクション: `session_id` / `sql_text`
- ターゲット: `package0.event_file`
  - `filename = N'C:\XE\xe_ex25_file.xel'`(Linux なら `/var/opt/mssql/log/xe_ex25_file.xel`)
  - `max_file_size = 10`(MB)、`max_rollover_files = 3`
- `WITH`: `MAX_DISPATCH_LATENCY = 5 SECONDS`

**このセッションが消費しうるディスクの上限は何 MB か**を暗算して答えなさい。

(2) 開始して `dbo.OrdersBig` に対する重いクエリを何本か流し、6秒待ってから
**セッションを停止(`STATE = STOP`)** しなさい。

(3) **停止したまま**、`sys.fn_xe_file_target_read_file` でファイルを読み、
「発生時刻JST / 実行時間ms / 論理読み取り / セッションID / 実行された文」の表を出しなさい。

ヒント・注意:
- 実ファイル名には **自動でサフィックスが付く**ので、**`xe_ex25_file*.xel`** とワイルドカードで指定する。
- 第2引数(メタデータファイル)は **SQL Server 2012 以降 `NULL` でよい**。
- **`event_file` の1行は `<event>` が根**なので、`nodes()` のパスは
  `ring_buffer` の `/RingBufferTarget/event` ではなく **`/event`** になる。

(4) **`ring_buffer` なら停止後に読めなかったのはなぜか**、
`event_file` との違いを1〜2行で説明しなさい。

(5) `xe_ex25_file` を削除し、そのうえで **`.xel` ファイルがまだ残っている**ことを確認して
OS 側から削除しなさい(削除コマンド/操作も書くこと)。

**Q14.** **`event_counter` と `histogram` で「まず量を測る」。**

本番に `sqlserver.sql_statement_completed` を **述語なしで**仕掛けるのが危険なことを、
実測して示しなさい。

(1) `xe_ex25_count` という EVENT SESSION を作りなさい。
- イベント: `sqlserver.sql_statement_completed`
  (述語は **`database_name = N'SalesLearning'` だけ**。`duration` のしきい値は付けない)
- ターゲットは2つ: `package0.event_counter` と、
  `package0.histogram`(`filtering_event_name = N'sqlserver.sql_statement_completed'`,
  `source = N'sqlserver.session_id'`, `source_type = 1`)
- `WITH`: `MAX_DISPATCH_LATENCY = 5 SECONDS`

(2) 開始して、`sample-db/05_workload.sql` の **セクションA(読み取り負荷60秒)** を
別ウィンドウで1〜2本流しなさい。20秒ほど経ったら `event_counter` を読み、
**「20秒でおよそ何件のイベントが発火したか」** を答えなさい。
さらに `histogram` から **セッションIDごとの件数**を出しなさい。

(3) その件数を「1時間あたり」に換算し、
**もし `ring_buffer`(1000件上限)で採っていたら何が起きるか**、
**もし `event_file` で採っていたら1時間で何 MB 程度になりそうか**(1イベント約 500 バイトと仮定)を
見積もりとして答えなさい。

(4) **`event_counter` / `histogram` が `ring_buffer` より軽い理由**を1〜2行で説明しなさい。

(5) `xe_ex25_count` を停止・削除しなさい。セクションA は60秒で自動終了します。

**Q15.** **`TRACK_CAUSALITY` で因果関係を追う。**

(1) Q4 と同じ内容で `xe_ex25_slow` を作り直しなさい。ただし今度は
**`TRACK_CAUSALITY = ON`** とし、述語のしきい値を `duration > 1000`(1ミリ秒)に下げること。

(2) 開始して、次のような「1バッチの中で複数の文を実行する」処理を流しなさい。

```sql
DECLARE @s DECIMAL(38,2);
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'完了';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE Status = N'保留';
SELECT @s = SUM(Amount) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;
```

(3) `ring_buffer` を展開する際、`action[@name="attach_activity_id"]` の値も取り出しなさい。
この値は **`GUID-シーケンス番号`** の形式です。GUID 部分とシーケンス番号を
`LEFT` / `RIGHT` や `CHARINDEX` で分けて表示し、
**同じ GUID を持つイベントが、1つのバッチに属していること**を確認しなさい。

(4) `TRACK_CAUSALITY = ON` の **コスト**は何か。本番で常時 `ON` にすべきでない理由を答えなさい。

(5) `xe_ex25_slow` を停止・削除しなさい。

**Q16.** **後片付けと棚卸し(必ず実行)。**

(1) この演習で作った EVENT SESSION が **1つも残っていない**ことを確認しなさい。
`sys.server_event_sessions` から、**既定のセッション
(`system_health` / `AlwaysOn_health` / `telemetry_xevents` など)を除いた**一覧を出し、
`xe_ex25_` で始まるものが 0 件であることを確認すること。
残っていたら停止して削除しなさい。

(2) `blocked process threshold (s)` が **元の値(既定 `0`)** に戻っていることを
`sys.configurations` で確認しなさい。`show advanced options` も `0` に戻っていること。

(3) すべてのクエリウィンドウで `@@TRANCOUNT` が `0` であることを確認しなさい。

(4) 実験に使った本物のテーブルが元のままであることを確認しなさい。
- `dbo.Products` の `ProductId = 2` の `UnitPrice` が `2800`
- `dbo.Employees` の `EmployeeId = 3` の `Salary` が `480000`
- `dbo.Departments` の行数が `5`

(5) `sample-db/05_workload.sql` の **後片付けセクション**を実行して
`dbo.WorkloadTest` を削除しなさい。

(6) `C:\XE\`(または `/var/opt/mssql/log/`)に `xe_ex25_*.xel` が残っていないことを確認しなさい。
