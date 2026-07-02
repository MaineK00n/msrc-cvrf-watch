#!/usr/bin/env bash
# MSRC CVRF fetch 監視コレクタ（生データ収集のみ）
#
# api.msrc.microsoft.com の CVRF を毎時スナップショットして生データを溜める。
# 目的: 「月が /updates index から消える」「index にはあるが /cvrf/<month> が
# HTTP 200 で返るのに中身が空」といった一過性欠落を、後から生データで検証できるようにする。
#
# 保存形式（毎回フルの生データを timestamp 配下に保存。XMLはzstd圧縮）:
#   data/<ts>/index.json        /updates 生JSON（~47KB・可読のため非圧縮）
#   data/<ts>/<month>.xml.zst   各監視月の /cvrf/<month> 生XML（zstd圧縮, 例 7.9MB→~0.1MB）
#
# 使い方: DATA=./data ./scripts/collect.sh
set -euo pipefail

BASE="https://api.msrc.microsoft.com/cvrf/v3.0"
DATA="${DATA:-./data}"
RECENT_MONTHS="${RECENT_MONTHS:-6}"   # 監視する最新月数（0=全月）
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

command -v zstd >/dev/null || { echo "zstd required" >&2; exit 1; }
tsdir="$DATA/$TS"
mkdir -p "$tsdir"

# --- index 取得 ---
if ! curl -sS --retry 3 --retry-delay 5 -H "Accept: application/json" \
        -o "$tsdir/index.json" "$BASE/updates"; then
  echo "::warning::index fetch failed at $TS"
  exit 0
fi
if ! jq -e '.value' "$tsdir/index.json" >/dev/null 2>&1; then
  echo "::warning::index not valid json at $TS (raw kept: $tsdir/index.json)"
  exit 0
fi

# カレンダー月(InitialReleaseDate)の新しい順。RECENT_MONTHS=0 で全月。
# 注: CurrentReleaseDate(最終改訂)で選ぶと、古い月の再改訂が混ざり直近月が漏れるため使わない。
mapfile -t MONTHS < <(jq -r '.value | sort_by(.InitialReleaseDate) | reverse | .[].ID' "$tsdir/index.json")
[ "$RECENT_MONTHS" -gt 0 ] && MONTHS=("${MONTHS[@]:0:$RECENT_MONTHS}")

# --- 各月ドキュメントを取得して圧縮保存 ---
for m in "${MONTHS[@]}"; do
  doc="$(mktemp)"
  hcode=$(curl -sS --retry 3 --retry-delay 5 -o "$doc" -w "%{http_code}" "$BASE/cvrf/$m" || echo "000")
  if [ "$hcode" = "200" ]; then
    zstd -q -${ZSTD_LEVEL} -o "$tsdir/$m.xml.zst" "$doc"
  else
    # 非200も証拠として残す（本文があれば圧縮保存）
    echo "::warning::month=$m http=$hcode at $TS"
    [ -s "$doc" ] && zstd -q -${ZSTD_LEVEL} -o "$tsdir/$m.http${hcode}.xml.zst" "$doc"
  fi
  rm -f "$doc"
done

echo "collected ${#MONTHS[@]} months at $TS -> $tsdir"
