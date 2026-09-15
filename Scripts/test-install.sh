#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo with spaces/Scripts" "$tmp/bin" "$tmp/elsewhere"
cp "$root/Scripts/install.sh" "$tmp/repo with spaces/Scripts/install.sh"
installer="$tmp/repo with spaces/Scripts/install.sh"
cat > "$tmp/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$TEST_PLATFORM"
SH
for script in install-macos.sh package-linux.sh; do
  cat > "$tmp/repo with spaces/Scripts/$script" <<'SH'
#!/bin/sh
printf '%s\n' "$(basename "$0")" "$#" "$*" "${PREFIX:-}" "${SCRIBE_INSTALL_PATH:-}" > "$TEST_TRACE"
printf 'child stdout progress\n'
printf 'child stderr diagnostic\n' >&2
exit "${TEST_EXIT:-0}"
SH
done
chmod +x "$tmp/bin/uname" "$tmp/repo with spaces/Scripts/"*.sh
PATH="$tmp/bin:$PATH"
TEST_TRACE="$tmp/trace"
PREFIX="$tmp/linux prefix"
SCRIBE_INSTALL_PATH="$tmp/Mac Apps/Scribe.app"
export PATH TEST_TRACE PREFIX SCRIBE_INSTALL_PATH
cd "$tmp/elsewhere"

TEST_PLATFORM=Darwin "$installer" > "$tmp/stdout" 2> "$tmp/stderr"
grep -q '^child stdout progress$' "$tmp/stdout"
grep -q '^child stderr diagnostic$' "$tmp/stderr"
printf '%s\n' install-macos.sh 0 '' "$PREFIX" "$SCRIBE_INSTALL_PATH" > "$tmp/expected"
cmp "$tmp/expected" "$TEST_TRACE"
TEST_PLATFORM=Linux "$installer" > "$tmp/stdout" 2> "$tmp/stderr"
grep -q '^child stdout progress$' "$tmp/stdout"
grep -q '^child stderr diagnostic$' "$tmp/stderr"
printf '%s\n' package-linux.sh 1 --install "$PREFIX" "$SCRIBE_INSTALL_PATH" > "$tmp/expected"
cmp "$tmp/expected" "$TEST_TRACE"

rm "$TEST_TRACE"
TEST_PLATFORM=Unknown "$installer" --help > "$tmp/help"
grep -q 'Usage:' "$tmp/help"
TEST_PLATFORM=Unknown "$installer" -h > /dev/null
test ! -e "$TEST_TRACE"

expect_failure() {
  expected=$1
  shift
  status=0
  "$@" > "$tmp/output" 2>&1 || status=$?
  test "$status" = "$expected"
}
export TEST_PLATFORM=Unknown
expect_failure 1 "$installer"
grep -q 'unsupported platform: Unknown' "$tmp/output"
expect_failure 2 "$installer" --invalid
expect_failure 2 "$installer" --help extra
test ! -e "$TEST_TRACE"

export TEST_PLATFORM=Linux TEST_EXIT=17
expect_failure 17 "$installer"
printf 'PASS: platform routing, environment, paths with spaces, help, errors, and exit propagation\n'
