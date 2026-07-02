# msrc-cvrf-watch

`api.msrc.microsoft.com` の CVRF フィードを毎時スナップショットし、生データを溜める。
狙いは **月が index から消える / 200 で返るのに `vuln:Vulnerability` が0件** という
一過性欠落を、後から生データで検証できるようにすること。

これらは [`vuls-data-update`](https://github.com/MaineK00n/vuls-data-update) の
`pkg/fetch/microsoft/cvrf` が「その月を全削除」してしまう条件（`RemoveAll` + 0件をerror扱いしない）で、
`vuls-data-raw-microsoft-cvrf` の一括削除コミット → 下流 DB の Windows 検知欠落を引き起こす。

## 仕組み
- `.github/workflows/collect.yml` が **毎時** `scripts/collect.sh` を実行し、`data/` をコミット（約1ヶ月運用の想定）。
- 毎回、監視対象月のフルの生データを `data/<ts>/` に保存（XMLはzstd圧縮）。判定や集計はせず、生データ収集に専念する。

## 保存形式
| パス | 内容 |
|---|---|
| `data/<ts>/index.json` | その時点の `/updates` 生JSON（~47KB, 可読のため非圧縮） |
| `data/<ts>/<month>.xml.zst` | 各監視月の `/cvrf/<month>` 生XML（zstd圧縮, 例: 7.9MB→~0.1MB） |
| `data/<ts>/<month>.http<code>.xml.zst` | 非200時のみ（本文があれば証拠として保存） |

- `<ts>` は UTC の `YYYYMMDDThhmmssZ`。
- 1回あたり ~0.55MB（RECENT_MONTHS=6）。毎時×1ヶ月でも git の blob 重複排除により .git は数十〜150MB程度の見込み。
- 復元: `zstd -d data/<ts>/<month>.xml.zst -o out.xml`

## 導入
1. このリポジトリを新規作成し中身を置く。
2. Settings → Actions → General → Workflow permissions を **Read and write** に。
3. Actions を有効化。`workflow_dispatch` で手動テスト実行 → `data/` にコミットされることを確認。

## 調整
- `RECENT_MONTHS`（既定6）: 監視する最新月数。`0`で全月。
- cron `0 * * * *`（毎時）: 収集間隔。GitHub の schedule は best-effort で遅延あり。
- `ZSTD_LEVEL`（既定19）。

## 後で解析するときの観点
溜めた `data/<ts>/` を時系列で見て、次を確認する:
- `index.json` の `.value[].ID` から **消えた月**がないか（各 `<ts>` の月集合の差分）。
- 各月 XML の `<vuln:Vulnerability` 件数が **0 に落ちた瞬間**がないか。
  - `for f in data/*/2026-Jun.xml.zst; do echo "$f $(zstd -dc "$f" | grep -c '<vuln:Vulnerability')"; done`
- `<month>.http<code>.xml.zst` が出ていれば非200が発生していた証拠。
