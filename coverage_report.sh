#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$ROOT/Sources/Konishi"
OUTPUT="$ROOT/.build/coverage/index.html"

if ! command -v jq >/dev/null 2>&1; then
    echo "coverage_report.sh requires jq (brew install jq)." >&2
    exit 1
fi

cd "$ROOT"
swift test --enable-code-coverage
coverage_json="$(swift test --show-codecov-path)"
if [[ ! -f "$coverage_json" ]]; then
    echo "SwiftPM coverage report not found: $coverage_json" >&2
    exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/konishi-coverage.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
rows="$tmp_dir/rows.html"
details="$tmp_dir/details.html"
: > "$rows"
: > "$details"

totals="$(jq -r --arg prefix "$SOURCE_ROOT/" '
    [.data[].files[] | select(.filename | startswith($prefix))] |
    [(map(.summary.lines.covered) | add // 0), (map(.summary.lines.count) | add // 0)] |
    @tsv
' "$coverage_json")"
IFS=$'\t' read -r covered_lines total_lines <<< "$totals"
if [[ "$total_lines" -eq 0 ]]; then
    echo "No Konishi source coverage found in $coverage_json" >&2
    exit 1
fi
percent="$(awk -v covered="$covered_lines" -v total="$total_lines" 'BEGIN { printf "%.1f", covered * 100 / total }')"

escape_html() {
    jq -Rn --arg value "$1" '$value | @html'
}

index=0
while IFS=$'\t' read -r source covered count file_percent; do
    [[ -f "$source" ]] || continue
    relative="${source#"$SOURCE_ROOT"/}"
    safe_name="$(escape_html "$relative")"
    anchor="source-$index"
    index=$((index + 1))

    printf '<tr><td><a href="#%s">%s</a></td><td>%.1f%%</td><td>%s / %s</td></tr>\n' \
        "$anchor" "$safe_name" "$file_percent" "$covered" "$count" >> "$rows"

    segments="$tmp_dir/segments.tsv"
    jq -r --arg filename "$source" '
        .data[].files[] | select(.filename == $filename) | .segments[] |
        select(.[3] == true and .[5] != true) | "\(.[0])\t\(.[2])"
    ' "$coverage_json" > "$segments"
    printf '\n' >> "$segments"

    {
        printf '<details id="%s"><summary>%s <span>%.1f%%</span></summary><pre>\n' \
            "$anchor" "$safe_name" "$file_percent"
        awk -F '\t' '
            NR == FNR {
                line = $1 + 0
                count = $2 + 0
                if (!(line in hits) || count > hits[line]) hits[line] = count
                next
            }
            {
                line = FNR
                text = $0
                gsub(/&/, "\\&amp;", text)
                gsub(/</, "\\&lt;", text)
                gsub(/>/, "\\&gt;", text)
                if (line in hits) {
                    if (hits[line] > 0) class = "covered"
                    else class = "missed"
                    marker = hits[line]
                } else {
                    class = "non-code"
                    marker = ""
                }
                printf "<span class=\"line %s\"><span class=\"count\">%s</span><span class=\"number\">%d</span><span class=\"text\">%s</span></span>\n", class, marker, line, text
            }
        ' "$segments" "$source"
        printf '</pre></details>\n'
    } >> "$details"
done < <(jq -r --arg prefix "$SOURCE_ROOT/" '
    [.data[].files[] | select(.filename | startswith($prefix))] |
    sort_by(.summary.lines.percent)[] |
    [.filename, (.summary.lines.covered | tostring), (.summary.lines.count | tostring), (.summary.lines.percent | tostring)] |
    @tsv
' "$coverage_json")

mkdir -p "$(dirname "$OUTPUT")"
{
    cat <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Konishi Coverage</title>
<style>
:root { color-scheme: light; font: 14px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #202a33; background: #f4f6f5; }
body { max-width: 1100px; margin: 32px auto; padding: 0 20px; }
h1 { margin-bottom: 4px; font-size: 24px; }
.summary { color: #52616b; margin: 0 0 24px; }
table { width: 100%; border-collapse: collapse; background: white; }
th, td { padding: 9px 12px; border-bottom: 1px solid #e2e7e5; text-align: left; }
th { color: #52616b; font-size: 12px; text-transform: uppercase; }
td:nth-child(2), td:nth-child(3) { text-align: right; font-variant-numeric: tabular-nums; }
a { color: #176b57; text-decoration: none; } a:hover { text-decoration: underline; }
h2 { margin-top: 32px; font-size: 18px; }
details { margin: 6px 0; background: white; border: 1px solid #e2e7e5; }
summary { padding: 10px 12px; cursor: pointer; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
summary span { float: right; color: #52616b; }
pre { overflow: auto; margin: 0; padding: 8px 0; background: #fbfcfb; font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
.line { display: block; min-height: 1.55em; white-space: pre; }
.covered { background: #e5f4ed; } .missed { background: #fae9e6; }
.count { display: inline-block; width: 48px; padding-right: 8px; color: #697780; text-align: right; user-select: none; }
.number { display: inline-block; width: 52px; padding-right: 12px; color: #87939a; text-align: right; user-select: none; }
.text { color: #202a33; }
</style>
<body>
<h1>Konishi source coverage</h1>
HTML
    printf '<p class="summary">%s of %s executable lines covered (%s%%) across %s source files.</p>\n' \
        "$covered_lines" "$total_lines" "$percent" "$index"
    printf '<table><thead><tr><th>Source file</th><th>Coverage</th><th>Lines</th></tr></thead><tbody>\n'
    cat "$rows"
    printf '</tbody></table><h2>Source details</h2>\n'
    cat "$details"
    printf '</body></html>\n'
} > "$OUTPUT"

printf 'Coverage report: %s\n' "${OUTPUT#"$ROOT"/}"