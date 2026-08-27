# Voron 2.4R2 — 作業ノート

設定レビュー（2026-08-27）で出た判断待ち項目・実機手順・保留リストの置き場。
個々の設定の理由は各 .cfg のコメント側に書いてあるので、ここには
**「.cfg に書けないこと」＝手順・ハード側の判断・未決事項**だけを残す。

## 目次

- [1. 決定待ち](#1-決定待ち)
- [2. 実機での作業手順](#2-実機での作業手順)
- [3. 保留リスト](#3-保留リスト) — クリティカルパスもここ
- [4. 既知の落とし穴](#4-既知の落とし穴)
- [5. 追加セクション](#5-追加セクション)
- [6. `.gitignore`](#6-gitignore実装済み)
- [7. FilaMatrix カット動作の危険分析](#7-filamatrix-カット動作の危険分析blobifier-実装後に着手)

---

## 1. 決定待ち

### 1.1 Orbiter Smart Sensor を EBB36 のどのピンに繋ぐか

**適当な空きパッドに刺してはいけない。** 壊れるピンと動かないピンがある。

| 区分 | ピン | 理由 |
|---|---|---|
| 絶対NG | `PA0` / `PA1` | ファンの MOSFET 出力（24V） |
| 絶対NG | `PB13` | ホットエンドヒーター出力（24V） |
| 絶対NG | `PA3` | サーミスタの ADC パッド |
| 使用中 | `PB8` | X エンドストップ |
| 使用中 | `PB12` `PB10` `PB11` `PB2` | ADXL345 SPI |
| 使用中 | `PD3` | Stealthburner NeoPixel |
| 使用中 | `PD0` `PD1` `PD2` `PA15` | エクストルーダー + TMC UART |

**推奨: `^stealthburner:PB3`**
BTT 自身の EBB36/EBB42 v1.2 サンプル設定が PB3（motion）/ PB4（switch）を
フィラメントセンサー用として明記しており、この構成ではどちらも空いている。
`^`（内部プルアップ）が必須。

配線は 5V / GND / SIG の3本。空いているエンドストップまたは FS ヘッダから
電源を取る。SIG が 5V プッシュプル出力の可能性がある場合、EBB36 の GPIO は
3.3V なので接続前にテスターで確認する。

**繋いだ後の検証**（→ 詳細は `config/hardware/toolhead/filament_sensor.cfg`）

```
QUERY_FILAMENT_SENSOR SENSOR=orbiter_smart_sensor
```

1. フィラメント装填して 20mm 押し出す → `detected: True`
2. フィラメント抜いて 20mm 押し出す → `detected: False`
3. **押し出さずに手で抜く → 状態が変わらない**

3 が重要。Orbiter Smart Sensor は「有無」ではなく「動き」を見る
モーションセンサーなので、静止状態の抜去は検出できない。つまり
「センサーが抜去を報告するまでポーリングして待つ」という UNLOAD の
設計は成立しない。3 が期待通りなら、抜去完了の判定は
`RESPOND TYPE=command MSG="action:prompt_..."` によるユーザー確認に
置き換える必要がある。

### 1.2 排気ファンの印刷中極低速運転

やりたいこと: わずかな負圧をかけて、隙間からの流れを内向きにし
未浄化空気の漏出を防ぐ。**発想としては正しい。**

**現状そのままでは動かない。** `config/hardware/fan.cfg` の
`[fan_generic exhaust_fan] off_below: 0.1` により、SPEED 0.1 未満は
強制的に 0 になる。極低速をやるなら `off_below: 0.03` 程度に下げ、
そのうえで実際に回り続ける最低速度を手動で探る必要がある
（`kick_start_time: 1.0` は既に入っているので起動自体は問題ない）。

**温度への影響は 1.3 のチャンバーセンサーが入るまで判断できない。**
HEPA で流路が絞られているので 10% 程度なら換気量は小さく、ベッドで
補償できる範囲だと推測しているが、これは推測にすぎない。判断手順:

1. チャンバーセンサーを設置（1.3）
2. 同じモデルを排気 0% / 10% / 20% で回す
3. 定常チャンバー温度を比較して決める

運用形態: Nevermore と同じくスライサーのフィラメント別 Start G-code から
`SET_FAN_SPEED FAN=exhaust_fan SPEED=0.1` を出す。素材ごとに変えられる。
PRINT_END / CANCEL_PRINT で 100% × 300秒 → 0 に上書きされるので後始末は自動。

### 1.3 チャンバー温度センサー（BME280）の設置位置

**Nevermore 内はダメ。** 理由:

1. 筐体内はファンが吸った空気の通り道なので、読み値が「チャンバー温度」
   ではなく「ファンのデューティ比の関数」になる
2. ファンモーター自身の発熱とカーボンベッドの流路抵抗が加わる
3. 活性炭は吸湿するので内部の湿度値は無意味

**推奨位置**: ベッドから 150〜200mm（ガントリ高さ付近）の側面または
背面パネル。パネルから 10〜20mm 浮かせたブラケット上に置き、
パネルからの熱伝導を避ける。

**避ける場所**

| 場所 | 理由 |
|---|---|
| ベッド直上 | 輻射熱で高く出る |
| 天板 | 熱の成層化で高く出る |
| Nevermore の吹き出し | 循環風の温度を読んでしまう |
| 排気ファンの吸い込み | 外気を引き込む |
| ホットエンド近傍 | 局所的な熱源 |

**配線**: BME280 は Nevermore の RP2040 から I2C で引く。I2C は差動では
ないので、ケーブルは 50cm 程度まで、ステッパ／ヒーター配線から離す。
長いと `i2c timeout` が出る。

**より確実な代替案**: `temperature_fan` 等の制御には温度だけあれば足りる。
Octopus の空いているサーミスタポート（標準ピンアウトでは T0〜T3 =
PF4〜PF7。ベッドが PF3 使用中。**シルク印刷で要確認**）に汎用 NTC を
1本引くほうが配線が単純でノイズにも強い。湿度・気圧も欲しいなら
BME280 を短距離で併設する二段構えが実用的。

---

## 2. 実機での作業手順

### 2.1 この変更セットを実機に反映する

**削除した4ファイルは Pi 側でも実際に削除する。** 残っていると override が
復活して、RESUME 時のノズル温度復帰などが再び壊れる。

```
config/macro/override/pause.cfg
config/macro/override/resume.cfg
config/macro/override/cancel_print.cfg
config/macro/helper/toolhead_peak_pause_cancel.cfg
```

同期後 `FIRMWARE_RESTART` → 確認:

- [ ] `PAUSE` → X50 Y5 / 現在Z+10mm にパークする
- [ ] **そのパーク座標が FilaMatrix（X10 Y29）と Blobifier に干渉しない**
      （干渉するなら `config/macro/client_variable.cfg` の
      `custom_park_x` / `custom_park_y` を変更）
- [ ] `RESUME` でノズル温度が復帰する（30分以上ポーズしても再開できる）
- [ ] `BEEP R=3` で音が鳴る（mini12864 にピエゾ未実装なら無音。EXP1_1 は
      他に使っていないので害はない）
- [ ] `_PLAY_SAMPLE` で音声が鳴り、かつ印刷が止まらない
- [ ] `PRINT_END` を手動実行してエラーが出ない

エクストルーダーの `rotation_distance` は 13.753296 + gear_ratio 50:17 から
4.676121（gear_ratio なし）に書き換えたが、**step_distance は完全に同一**
なので押出量の再キャリブレーションは不要。

### 2.2 Input Shaper を動かす（#15）

コンフィグ側（`[resonance_tester]`）は投入済み。実機作業:

1. `FIRMWARE_RESTART` 後 **`ACCELEROMETER_QUERY`**
   停止状態で重力 ≒ 9800 mm/s² が **z 成分**に出て、x/y がほぼ 0 か確認。
   ズレていたら `config/hardware/toolhead/adxl345.cfg` の `axes_map` を修正
   （候補は同ファイルのコメント参照）。
   **ここが違うと X/Y の測定結果が入れ替わる。**
2. **`MEASURE_AXES_NOISE`**
   各軸のノイズが概ね 100 未満（できれば 50 未満）。大きい場合は EBB36 の
   固定または配線の取り回しの問題。
3. ホスト側の依存パッケージ（`SHAPER_CALIBRATE` のグラフ生成に numpy が必要）

   ```bash
   sudo apt install -y python3-numpy python3-matplotlib
   ~/klippy-env/bin/pip install -v numpy
   ```

4. `G28` → **`SHAPER_CALIBRATE`** → `SAVE_CONFIG`
5. CAN が 500kbps だと共振テスト中のサンプル転送で `Timer too close` や
   通信ロストが出ることがある。出たら 1Mbps への変更を検討。

現在 printer.cfg の SAVE_CONFIG ブロックにある値（X: mzv 62.4Hz /
Y: mzv 37.2Hz）は、無効化済みの Pico + ADXL で測ったもの。再測定推奨。

### 2.3 gcode_shell_command を update_manager に登録する（#7）

まず実態確認:

```bash
ls ~/klipper/klippy/extras/gcode_shell_command.py   # 入っているか
ls ~ | grep -i shell                                # リポジトリとして存在するか
grep -i shell ~/printer_data/config/moonraker.conf  # 既に登録済みか
```

KIAUH は通常**ファイルをコピーするだけ**でリポジトリを作らないので、
その場合 update_manager で追跡できるものがない。Klipper 更新のたびに
`kiauh → Advanced → G-Code Shell Command` を再実行する運用になる。

リポジトリが存在した場合の登録例は `config/macro/audio.cfg` の末尾コメント。

**未登録だと何が起きるか**: Klipper を更新すると extra が消え、
`Unknown config object 'gcode_shell_command'` で**起動しなくなる**。

---

## 3. 保留リスト

| # | 項目 | メモ |
|---|---|---|
| #1 | ベッドメッシュ | printer.cfg の破損ブロックは `mesh_max` が 320 だった時代の化石。`e8bde74 fix bed mesh` の 285 で手当て済みと読める。残る潜在リスクは `horizontal_move_z: 5` がモデル範囲 0.1〜5.0 の上限ちょうどという点のみ。次回スキャン後に外れ値がないか一度確認 |
| #9 | パージ線の位置 | Blobifier 導入時に解消。`config/macro/print_start.cfg` の 2 つめの `TODO(Blobifier)` コメントの位置で、手書きパージ線ブロックごと置き換える |
| #12 | UNLOAD のカッター動作 | **Blobifier 実装後に着手**。危険分析と実装案は完了済み → セクション 7 |
| — | 追加セクションの採否 | `[firmware_retraction]` と `[force_move]` のみ未決 → セクション 5 |
| — | その他の改善提案 | NeoPixel のレベルシフタ、Moonraker の `trusted_clients` |
| — | フィラメントフロー統合 | Blobifier 実装 → 1.1（EBB ピン）確定 → Orbiter Smart Sensor + Blobifier + FilaMatrix の統合 LOAD/UNLOAD 設計 |

**QGL の `retries: 3→5` は見送り**（2026-08-27 判断）。実際に収束失敗が出たら調整する。

### クリティカルパス

```
Blobifier 実装
  ├─→ #9  PRINT_START のパージ線置き換え（TODO コメント 2 箇所）
  └─→ #12 カット動作（パージ/ワイプの場所が決まらないと設計できない）
チャンバーセンサー設置（1.3）
  └─→ 1.2 排気ファン極低速の温度影響を測定できる
EBB ピン確定（1.1）
  └─→ フィラメントフロー統合
```

**PRINT_START の細部は対応済み**: `SET_GCODE_OFFSET Z=0` 追加、`CARTOGRARPHER` typo 修正、
冗長な `M104` 削除、M109/M190 override の S 未指定クラッシュ修正、Blobifier ワイプ
挿入位置のコメント 2 箇所。ノズル加熱タイミングは**意図的に変更していない**（下記 5.0 参照）。

---

## 4. 既知の落とし穴

### 4.1 Klipper の設定パーサは重複を黙って許す

Klipper は `RawConfigParser(strict=False)` で設定を読むので、
**同名セクションが複数のファイルにあってもエラーにならず、後に読まれた
ものが勝つ**。これが override 問題（自作 PAUSE が mainsail.cfg 版を
無効化していた）が長く見えなかった理由。

同様に **ワイルドカード `[include]` が 0 件マッチでもエラーにならない**。
`[include ./toolheadd/*.cfg]` の typo が黙って無視されていた。

`[include a/**/*.cfg]` の `**` は**再帰しない**（`*` と同じ挙動）。
1 階層しか下りないので、`macro/x/y/*.cfg` は読まれない。

### 4.2 mainsail.cfg は編集しない

`moonraker.conf` の `[update_manager mainsail-config]` が管理している
ベンダーファイルなので、更新時に上書きされる。カスタマイズは
`config/macro/client_variable.cfg` の変数か、別ファイルでの追記で行う。

### 4.3 UNLOAD_FILAMENT の `G1 E-125` は必ずエラーになる

`config/hardware/toolhead/extruder.cfg` の
`max_extrude_only_distance: 101` を超えるため
`Extrude only move too long` になる。フロー再設計時に 50mm×3回に
分割するか、`max_extrude_only_distance` を引き上げるか決める。

### 4.4 チャンバー LED が反応しなくなったら

`RESET_CHAMBER_LED` を実行する。QGL の収束失敗や緊急停止で
`_OVERRIDE_CHAMBER_LED_END` が実行されないと、`override_count` が
0 に戻らず `TOGGLE_CHAMBER_LED` が「would take effect later」しか
言わなくなる（再起動でも解消する）。

### 4.5 optional/ 配下は自動 include されない

`config/hardware/optional/` は意図的に glob 対象外。特に `probe.cfg` は
Cartographer と同じ `probe` オブジェクトを提供するので、有効化すると
競合する。`nevermore.cfg` を有効化する際は同ファイル冒頭の
既知バグ（serial パス、`restart_methoda`、`gas_level`）を先に直す。

---

## 5. 追加セクション

**導入済み**: `[gcode_arcs]` / `[save_variables]` / `[exclude_object]`
（`config/software/` に1機能1ファイルで配置。5.1 / 5.2 / 5.4 参照）
**未導入**: `[firmware_retraction]` / `[force_move]`（5.3 / 5.5）

### 置き場所の方針

これらは `config/software/` に置く。理由:

- `config/software/` は既に「ハードではない機能」（`bed_mesh` / `safe_z_home` /
  `quad_gantry_level`）の置き場になっており、今回の3つも同じ性質
- `printer.cfg` は `[mcu]` 群・ホスト温度センサー・include・`[printer]` だけの
  薄い入口として保っておきたい。加えて printer.cfg 末尾は SAVE_CONFIG が
  書き換えるので、手書き設定を増やすほど差分が読みにくくなる
- `config/hardware/optional/` は使わない。あのディレクトリは「常に存在するとは
  限らないハードウェア」用で、自動 include されない前提。今回の3つは純粋な
  ソフト機能で常に有効なので、意味が食い違う

ファイル名 = 機能名にしておけば「どこで設定しているか」がファイル一覧で分かる。
glob include なのでファイル単位で無効化はできない（無効化したいときは
`optional/` に移動するか、セクション名をコメントアウトする）。

### 5.0 ノズル加熱タイミングについて（変更しなかった理由）

`M104 S150` はベッド加熱（`M190`）より前に置いたままにしてある。ベッドが
100℃ に達するまでノズルが 150℃ で垂れ続けるのは事実だが、その間にツール
ヘッド全体が熱的に落ち着くことは Cartographer の測定精度には有利に働く。
垂れの対策は Blobifier のブラシワイプ（`print_start.cfg` の 1 つめの
`TODO(Blobifier)`）で行う方針にしたので、加熱順序は触っていない。

### 5.1 `[exclude_object]` — 印刷中に個別オブジェクトをキャンセル【導入済み】

350mm ベッドで多数部品を並べる運用では効果が大きい。1 個だけ剥がれた
ときにプレート全体を中止しなくて済む。

```ini
[exclude_object]
```

加えて `moonraker.conf` の `[file_manager]` を
`enable_object_processing: True` に変更する必要がある。

**仕組み**: Moonraker がアップロードされた gcode を前処理して
`EXCLUDE_OBJECT_DEFINE` / `EXCLUDE_OBJECT_START` / `EXCLUDE_OBJECT_END`
を挿入する。スライサー側が Klipper 形式のオブジェクトラベルを出力できる
場合（OrcaSlicer / PrusaSlicer の「オブジェクトにラベルを付ける」）は
そちらでもよい。

**唯一のコスト**: `enable_object_processing: True` にすると Moonraker が
アップロードごとに gcode 全体をスキャンする。Pi 4 で大きいファイルだと
数秒〜十数秒アップロードが遅くなる。それ以外の副作用はない。

### 5.2 `[gcode_arcs]` — G2/G3 円弧移動【導入済み】

```ini
[gcode_arcs]
resolution: 0.1
```

**無いと何が起きるか**: G2/G3 は `Unknown command` になる。これは致命的
エラーではないので印刷は続くが、**その円弧移動が丸ごと実行されない**。
次の G1 まで直線で飛ぶので形状が崩れ、押出量もずれる。ログを見ていないと
気づきにくい壊れ方をする。

現在スライサーの arc fitting を使っていないなら実害はないが、
OrcaSlicer / PrusaSlicer には arc fitting 設定があり、うっかり有効にすると
上記が起きる。デメリットが無いので保険として入れておく価値がある。
`resolution` は円弧を分割する弦の長さ（デフォルト 1.0mm、小さいほど滑らか）。

### 5.3 `[firmware_retraction]` — G10/G11【未導入】

```ini
[firmware_retraction]
retract_length: 0.5
retract_speed: 35
unretract_extra_length: 0
unretract_speed: 35
```

Orbiter のダイレクトドライブなら `retract_length` は 0.4〜0.8mm 程度。

**主な用途はスライサーではなく 2 つ**:

1. `_CLIENT_VARIABLE` の `variable_use_fw_retract: True` が使えるようになり、
   PAUSE / RESUME のリトラクトが印刷中の設定と一致する
2. `SET_RETRACTION` で再スライスせずにリトラクト量を試せる

**注意**: スライサー側のファームウェアリトラクトを有効にすることは
推奨しない。wipe-while-retract やオブジェクト単位の設定が使えなくなり、
スライサーのリトラクト制御より機能が劣る。

### 5.4 `[save_variables]` — 再起動をまたぐ状態保存【導入済み】

```ini
[save_variables]
filename: ~/printer_data/config/variables.cfg
```

`SET_GCODE_VARIABLE` の値は再起動で消えるが、これは消えない。

```
SAVE_VARIABLE VARIABLE=filament_loaded VALUE=True
{printer.save_variables.variables.filament_loaded}
```

**フィラメントフロー統合（Orbiter + Blobifier + FilaMatrix）でこれが要る。**
「今フィラメントが装填されているか」「装填されている素材」「カッター刃の
使用回数」といった状態は、Klipper 再起動や電源断をまたいで保持されないと
意味がない。特に Orbiter Smart Sensor がモーションセンサーで静的な有無を
answer できない（→ 1.1）ため、装填状態はソフト側で覚えておく必要がある。

**注意点**: 呼ぶたびにファイル全体を書き直すので、ループ内で連打しない。
`variables.cfg` は config ディレクトリに出来るので `.gitignore` 対象
（→ セクション 6）。

### 5.5 `[force_move]` — 未ホーミングでのステッパ操作【未導入】

```ini
[force_move]
enable_force_move: True
```

`FORCE_MOVE` と `SET_KINEMATIC_POSITION` が使えるようになる。ガントリが
上端で引っかかって Z がホーミングできない、QGL が中断して Z モーターが
ずれた、といった復旧作業で有用。ハードを頻繁にいじっている今の状況では
入れておく価値がある。

**ただし足を撃つ道具**: これらのコマンドはリミットチェックを一切通らない。
`SET_KINEMATIC_POSITION` は「実際とは違う位置にいる」と Klipper に
思い込ませるので、その後の通常移動でツールヘッドをぶつけられる。
理解して使うこと。

---

## 6. `.gitignore`【実装済み】

除外の理由：

| パターン | 対象 | 除外すべき理由 |
|---|---|---|
| `*.mru` | `config/hardware/moonraker.upload-2135.mru` など | Moonraker がファイルアップロード中に作る一時ファイル。中断すると 0 バイトの残骸が残る。番号は毎回変わるので追跡する意味が全くない。**既に 2 個コミットされている** |
| `printer-[0-9]*.cfg` | `printer-20250906_135603.cfg` など | Klipper の SAVE_CONFIG バックアップ。`SAVE_CONFIG` するたびに旧 printer.cfg がこの名前にリネームされて増え続ける。中身は printer.cfg 全体＋メッシュなので大きい。**git で履歴管理している以上、これは完全な重複**（`git log -p printer.cfg` で同じものが取れる）。`printer-*.cfg` ではなく数字始まりに限定すると、`printer-test.cfg` のような意図的な名前を誤って無視しない |
| `variables.cfg` | 5.4 を導入した場合 | `[save_variables]` の保存先。実行時の状態（装填中の素材など）が印刷ごとに書き換わるので、コミットすると差分ノイズになる。設定ではなくランタイムデータ |
| `*.bak` | — | エディタ・各種ツールのバックアップ |
| `Thumbs.db` / `desktop.ini` | — | Windows 側で作業しているので念のため |

**除外しないもの**: printer.cfg 末尾の `#*# SAVE_CONFIG` ブロック。PID 値・
input shaper 値・Cartographer モデルは printer.cfg 本体に書かれるので分離
できないし、これらの変化履歴はむしろ残したい。

既にコミットされていた4ファイル（`.mru` × 2、`printer-20250906_*.cfg` × 2）は
`git rm --cached` で追跡解除済み。`--cached` なのでディスク上のファイルは残って
いる。今後同名のものが増えても `.gitignore` が拾う。

---

## 7. FilaMatrix カット動作の危険分析（Blobifier 実装後に着手）

Blobifier のパージ/ワイプ位置が決まらないと UNLOAD 全体の動線が決められない
ため保留。分析と実装案は済んでいるので、着手時はここから再開する。

対象は `config/macro/unload_filament.cfg` の現在の内容（コミット `74738f7` 時点）。
実機の制約値: X `position_min: 0` / `position_endstop: 350` /
`homing_positive_dir: true`、`max_extrude_only_distance: 101`、
`min_extrude_temp: 170`、`safe_z_home z_hop: 10`、`_CLIENT_VARIABLE
custom_park_dz: 10` / `idle_timeout: 43200`。

### 7.1 危険度1 — ポーズ中の `G28`（14行目）

CHANGE_FILAMENT → PAUSE → UNLOAD_FILAMENT が主経路なのに、その経路が一番危険。

Klipper の `safe_z_home` は **Z が homed かつ `z_hop` より低い場合のみ**リフトする
（`elif pos[2] < self.z_hop`）。**造形高さ 150mm でポーズ中は Z10 より高いので
リフトが一切起きない。** その状態で:

1. X ホーミング → `homing_positive_dir: true` なので X=350 方向へ、その高さのまま
   盤面を横断。ノズルが最上層をなでる
2. Y ホーミング → 同様に Y=350 方向へ横断
3. Z ホーミング → X175 Y175 へ移動し、Cartographer touch で**造形物の真上から
   ノズルを降ろす**
4. Z 原点が再設定される → RESUME 後の Z 基準がずれる

### 7.2 危険度2 — XY 移動の Z クリアランス無保証（15行目）

`G1 X10 Y29` は現在の Z のまま水平移動する。ポーズ経由なら造形物上面 +10mm、
PRINT_END 後なら +3mm、手動実行なら Z0.2 のこともある。

**正しい定式化は絶対値の safe_z ではなく `現在Z + クリアランス`。** ノズルは
造形済み部分の最上面にいるので `現在Z + 10mm` なら全てを越えられる。「安全のため
Z30 へ」のような固定値は 200mm 高の造形物には無意味。

### 7.3 危険度3 — `G1 E-125` が確実にエラー（21行目）

`max_extrude_only_distance: 101` 超過で `Extrude only move too long`。
マクロがそこで中断するので `RESTORE_GCODE_STATE` が実行されず、**ノズルが 250℃
のまま放置される**。しかも `_CLIENT_VARIABLE idle_timeout: 43200` を入れたため、
**ポーズ中はこの放置が 12 時間続く**（従来は 30 分で TURN_OFF_HEATERS）。
明示的な安全網（ウォッチドッグ）が必要。

### 7.4 危険度4 — E の押出モード未定義（21行目）

`SAVE_GCODE_STATE` の後に `M83` も `G91` もない。スライサーが `M82`（絶対押出）
だと `G1 E-125` は**絶対座標 E=-125 への移動**になる。現在 E が 3000mm なら
-3125mm の押し出し要求。結果は 7.3 のエラーで止まるが意図と全く違う。
以前の詳細版には `M83` があったので簡略化の際に落ちた。

### 7.5 危険度5 — カット時の脱調と座標喪失（16行目）

**カットの力を X 軸モーターが出している。** FilaMatrix はガントリの推力でレバーを
押す設計なので、`position_min: 0` の機械的ストッパまで押し込むと TMC2209 が脱調
する。CoreXY なので **A/B モーターの片方だけ脱調すると X と Y の両方がずれる。**
加えて X0 はソフトリミットちょうどでマージンゼロ。

対策の定石はカット後の X 再ホーミング。`G28 X` は Z を触らないのでポーズ中でも
Z 基準は保たれる（ただし X=350 方向へ横断するので 7.2 の Z 退避が前提）。

### 7.6 危険度6〜8

- **6: 送り速度未指定**（15, 18行目）— `F` が無く直前の値を継承。この文脈では
  `G28` 内部の最後の速度が残るので予測不能
- **7: テンション抜きの実装欠落**（17行目）— `; slowly retract a bit` のコメント
  だけ残り実装がない。以前の詳細版には `G1 X0 E-{cut_e_retract} F{cut_feed}` が
  あった。押し出し圧が残ったままカットすると刃が入りにくく切断面も荒れる
- **8: 温度 250℃ 固定**（9-10行目）— PLA を 250℃ で長時間保持すると熱劣化して
  ノズル内で炭化する。素材別に（PLA 200-220 / PETG 230-240 / ABS・ASA 240-250）

### 7.7 実装案

```ini
[gcode_macro UNLOAD_FILAMENT]
# ---- 幾何（実機で調整）----
variable_cut_y:            29.0   ; カッターの Y
variable_cut_x_approach:   10.0   ; カット前後の待機 X
variable_cut_x_press:       0.5   ; 刃を押し込む X <- 要検証（現状 0）
variable_cut_feed:          500   ; mm/min 押し込みストローク
variable_cut_return_feed:  3000   ; mm/min 戻り
variable_travel_feed:      9000   ; mm/min XY 移動
# ---- Z 退避 ----
variable_z_clearance:      10.0   ; XY 移動前に「現在Z + この値」まで上げる
variable_z_floor:          30.0   ; ただし絶対 Z がこれ未満にはしない
# ---- フィラメント ----
variable_temp:              250   ; TEMP= で上書き可
variable_tension_relief:    1.0   ; カット前のリトラクト
variable_cut_e_retract:     5.0   ; 押し込みストローク中に同時に引く量
variable_unload_length:   125.0   ; カット後の合計リトラクト
variable_unload_chunk:     50.0   ; max_extrude_only_distance(101) 以下必須
variable_unload_feed:      1200
# ---- 安全 ----
variable_rehome_x:            1   ; カット後に G28 X
variable_standby_temp:        0   ; 0=OFF、>0=待機温度
variable_watchdog_timeout:  600   ; 秒。超えたらヒーター強制OFF
```

処理順:

```
1.  ガード: 印刷中かつ未ポーズなら拒否
2.  ウォッチドッグを最初に予約 (UPDATE_DELAYED_GCODE ID=_UNLOAD_WATCHDOG)
      -> 途中でエラー中断してもヒーターが必ず落ちる          (7.3)
3.  SAVE_GCODE_STATE / G90 / M83 を明示                       (7.4)
4.  未ホーミングなら G28 せずに action_raise_error で中断
      「ベッド上に造形物が無いことを目視確認してから G28 して」
      -> Cartographer touch は造形物の上でも降りるので人間が確認 (7.1)
5.  G1 Z{ [現在Z + z_clearance, z_floor]|max } で退避         (7.2)
6.  G1 X{cut_x_approach} Y{cut_y} F{travel_feed}              (7.6-6)
7.  M109 S{temp}（退避後に加熱 = 造形物の上で垂れない）        (7.6-8)
8.  G1 E-{tension_relief} でテンション抜き                    (7.6-7)
9.  G1 X{cut_x_press} E-{cut_e_retract} F{cut_feed} -> 戻り
10. {% if rehome_x %} G28 X {% endif %}                       (7.5)
11. unload_length を unload_chunk 単位に分割してリトラクト     (7.3)
12. M104 S{standby_temp} / RESTORE_GCODE_STATE
13. ウォッチドッグを解除 (DURATION=0)
```

`max_extrude_only_distance` は引き上げず**分割**する方針。この値は暴走押出を
止める安全網なので弱めたくないし、`load_filament.cfg` が既に `E50` × 3 回で
同じことをやっているので一貫する。

### 7.8 着手時に決める必要があること

1. **`X0` でカットが完了しているか（実機確認）** — FilaMatrix によっては X0 では
   刃が届き切らず `position_min: -2` のような負の値が必要。逆に手前で切れているなら
   `cut_x_press` を 1.0 にしてソフトリミットのマージンを取れる。一度カットして
   切断面を確認する
2. **アンロード方針** — 以前の詳細版は `user_pull_retract: 20.0` で「センサーが
   OFF になるほど引かない」半自動設計。現在の版は `E-125` の全自動。Orbiter Smart
   Sensor が静的な有無を答えられない（1.1）ので**全自動のほうが今のハード構成と
   相性が良い**（推奨）
3. **カット後の `G28 X`** — 推奨は「入れる」。脱調していなければ数秒の無駄、
   していれば座標を復旧できる。Z を触らないのでポーズ復帰も安全
