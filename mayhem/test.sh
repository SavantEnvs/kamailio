#!/usr/bin/env bash
#
# mayhem/test.sh — RUN kamailio's functional checks built by mayhem/build.sh (normal flags):
#   * mayhem/selftest: known-answer checks over the URI/SIP parser, basex and strutils core code
#   * the kamailio binary: config syntax check on a good and a bad config, and its version banner
# exit 0 = pass; emits a CTRF report.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTDIR="$SRC/build-test"
for f in selftest kamailio; do
  [ -x "$TESTDIR/$f" ] || { echo "missing $TESTDIR/$f — mayhem/build.sh did not build it" >&2; emit_ctrf kamailio-selftest 0 1; exit 1; }
done

passed=0; failed=0
work="$(mktemp -d "${TMPDIR:-/tmp}/kamtest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1) selftest: count PASS/FAIL lines; require its final summary line so a silent no-op is a failure.
"$TESTDIR/selftest" > "$work/selftest.out" 2>&1
st=$?
cat "$work/selftest.out"
p=$(grep -c '^PASS ' "$work/selftest.out" || true)
f=$(grep -c '^FAIL ' "$work/selftest.out" || true)
passed=$(( passed + p )); failed=$(( failed + f ))
if ! grep -q "^SELFTEST passed=$p failed=$f\$" "$work/selftest.out" || [ "$p" -lt 35 ] || [ "$st" -ne 0 ]; then
  echo "selftest did not complete cleanly (exit $st, $p passes)" >&2
  failed=$(( failed + 1 ))
fi

# 2) kamailio binary: config check
check() {  # name, condition-exit-status
  if [ "$2" -eq 0 ]; then passed=$(( passed + 1 )); echo "PASS $1"; else failed=$(( failed + 1 )); echo "FAIL $1"; fi
}
cat > "$work/unresolved.cfg" <<'CFG'
route {
	if (is_method("OPTIONS")) {
		exit;
	}
}
CFG
cat > "$work/ok.cfg" <<'CFG'
listen=udp:127.0.0.1:5099
children=1
alias="example.org"
route {
	if (method == "OPTIONS") {
		drop;
	}
	forward();
}
CFG
cat > "$work/bad.cfg" <<'CFG'
route {
	if (method == "OPTIONS" {
		drop;
	}
}
CFG

# -Y: runtime dir (default /var/run/kamailio is not writable for the build user)
KAM=("$TESTDIR/kamailio" -c -Y "$work")

out="$("${KAM[@]}" -f "$work/ok.cfg" 2>&1)"; rc=$?
[ "$rc" -eq 0 ]; check "valid config exits 0" $?
echo "$out" | grep -q "config file ok, exiting"; check "valid config reports ok" $?
echo "$out" | grep -q "example.org"; check "valid config alias is listed" $?

out="$("${KAM[@]}" -f "$work/bad.cfg" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check "syntax error config is rejected" $?
echo "$out" | grep -q "syntax error"; check "syntax error reported" $?

out="$("${KAM[@]}" -f "$work/unresolved.cfg" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check "unresolved function is rejected" $?
echo "$out" | grep -q "unknown command, missing loadmodule"; check "unresolved function reported" $?

out="$("$TESTDIR/kamailio" -V 2>&1)"; rc=$?
echo "$out" | head -1
echo "$out" | grep -q '^version: kamailio [0-9]'; check "version banner" $?

emit_ctrf kamailio-selftest "$passed" "$failed"
