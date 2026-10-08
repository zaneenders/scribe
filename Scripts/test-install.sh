#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo with spaces/Scripts" "$tmp/repo with spaces/scribe-desktop" "$tmp/bin" "$tmp/elsewhere"
cp "$root/Scripts/install.sh" "$tmp/repo with spaces/Scripts/install.sh"
cat > "$tmp/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$TEST_PLATFORM"
SH
cat > "$tmp/bin/swift" <<'SH'
#!/bin/sh
printf '%s\n' "$PWD" "$@" > "$TEST_TRACE"
printf 'child stdout progress\n'
printf 'child stderr diagnostic\n' >&2
exit "${TEST_EXIT:-0}"
SH
chmod +x "$tmp/bin/"* "$tmp/repo with spaces/Scripts/install.sh"
export PATH="$tmp/bin:$PATH" TEST_TRACE="$tmp/trace" HOME="$tmp/home with spaces"
installer="$tmp/repo with spaces/Scripts/install.sh"
cd "$tmp/elsewhere"
for platform in Linux Darwin; do
  export TEST_PLATFORM="$platform"
  for option in '' --without-profiling --help --invalid; do
    if [ -n "$option" ]; then
      "$installer" "$option" > "$tmp/stdout" 2> "$tmp/stderr"
    else
      "$installer" > "$tmp/stdout" 2> "$tmp/stderr"
    fi
    {
      printf '%s\n' "$tmp/repo with spaces/scribe-desktop" package
      if [ "$platform" = Darwin ]; then
        printf '%s\n' --allow-writing-to-directory "$HOME/Applications"
      fi
      printf '%s\n' chroma-install
      if [ -n "$option" ]; then printf '%s\n' "$option"; fi
    } > "$tmp/expected"
    cmp "$tmp/expected" "$TEST_TRACE"
    grep -q '^child stdout progress$' "$tmp/stdout"
    grep -q '^child stderr diagnostic$' "$tmp/stderr"
  done
  status=0
  TEST_EXIT=17 "$installer" > /dev/null 2>&1 || status=$?
  test "$status" -eq 17
done
printf 'PASS: package directory, platform write grant, arguments, output, and failure propagation\n'
