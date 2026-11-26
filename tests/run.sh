#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Test suite of the repository. Plain bash + coreutils + git + python3 stdlib,
# plus makepkg for the packaging checks (skipped with a SKIP line when absent).
# Every test prints "ok", "not ok" or "# SKIP" with a number; the exit status is
# non-zero on any failure. Skips are counted in the summary and never fail.
#
# Three properties, each checked against the real tree and then with a mutation
# of a temporary copy, which must turn the same check red:
#   1. tools/gen_table.py reproduces the volume table in gsx1000-volume.patch
#      from captures/sweep-table.csv and captures/08-sweep.pcap.
#   2. packaging/aur/.SRCINFO equals what makepkg derives from the PKGBUILD.
#   3. the package installs exactly the three files under
#      /usr/src/epos-gsx1000-$pkgver/.
#
# Run it with: bash tests/run.sh
set -u

# ---------------------------------------------------------------- output gate
# The suite runs itself as a child with all of its output (stdout and stderr) captured
# in a log, then fails if that log carries any unexpected shell or git diagnostic.
# Output of negative (mutation) runs is captured into files by the tests themselves
# and never reaches the log; the only lines excluded here are the suite's own result
# lines. The child runs under LC_ALL=C so tool messages are untranslated and match.
if [ -z "${EPOS_TESTS_INNER:-}" ]; then
    gate_log=$(mktemp); gate_counts=$(mktemp)
    EPOS_TESTS_INNER=1 EPOS_TESTS_COUNTS=$gate_counts LC_ALL=C bash "$0" "$@" 2>&1 | tee "$gate_log"
    gate_rc=${PIPESTATUS[0]}
    if ! read -r pass fail skip n < "$gate_counts"; then
        pass=0; fail=1; skip=0; n=0
        echo "not ok - the suite did not report its counts (exit $gate_rc)"
    fi
    gate_re='fatal:|error:|Traceback|Is a directory|invalid number|command not found|No such file|unbound variable|syntax error'
    gate_hits=$(grep -nE "$gate_re" "$gate_log" | grep -vE '^[0-9]+:(ok|not ok|# SKIP) [0-9]+ - ')
    n=$((n + 1))
    if [ -z "$gate_hits" ]; then
        pass=$((pass + 1)); echo "ok $n - suite output: no unexpected diagnostics"
    else
        fail=$((fail + 1)); echo "not ok $n - suite output: no unexpected diagnostics"
        printf '%s\n' "$gate_hits" | head -10 | sed 's/^/  # /'
    fi
    rm -f "$gate_log" "$gate_counts"
    echo
    echo "# pass=$pass fail=$fail skip=$skip total=$n"
    [ "$fail" = 0 ] && [ "$gate_rc" = 0 ]
    exit
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
skip=0
n=0

ok() { n=$((n + 1)); pass=$((pass + 1)); echo "ok $n - $1"; return 0; }
ko() { n=$((n + 1)); fail=$((fail + 1)); echo "not ok $n - $1"; if [ -n "${2:-}" ]; then printf '  # %s\n' "$2"; fi; return 0; }
skipped() { n=$((n + 1)); skip=$((skip + 1)); echo "# SKIP $n - $1"; if [ -n "${2:-}" ]; then printf '  # %s\n' "$2"; fi; return 0; }

# runs <description> <cmd...>: run a mutation or fixture command with its output
# captured to $TMP/runs.out. Success is silent; a failure is a test failure.
runs() {
    local what=$1; shift
    "$@" > "$TMP/runs.out" 2>&1; local rc=$?
    [ "$rc" = 0 ] && return 0
    ko "fixture: $what" "exit $rc: $(head -3 "$TMP/runs.out" | tr '\n' '|')"
    return 1
}

# changed <file-before> <file-after> <what>: the mutation must have changed the file.
changed() {
    if cmp -s "$1" "$2"; then ko "$3" "the copy is identical to the original"; else ok "$3"; fi
}

# ---------------------------------------------------------------- 1. volume table
# table_block <patch-file>: print the C array of the volume table as it stands in
# the patch, from the declaration line to the closing brace, byte for byte. The
# patch is a diff, so every line of the block carries the one-character marker of
# an added line; that marker is removed, nothing else is touched.
table_block() {
    python3 - "$1" <<'EOF'
import sys
src = open(sys.argv[1]).read()
start = src.index("+static const s16 snd_gsx1000_vol_table")
end = src.index("\n+};", start) + len("\n+};")
out = []
for line in src[start:end].split("\n"):
    assert line.startswith("+"), f"table line without an added-line marker: {line!r}"
    out.append(line[1:])
sys.stdout.write("\n".join(out) + "\n")
EOF
}
if [ -f tools/gen_table.py ] && [ -f gsx1000-volume.patch ]; then
    if python3 tools/gen_table.py > "$TMP/gen.txt" 2> "$TMP/gen.err"; then
        # Byte comparison of the generated block with the block in the patch: the
        # generator's output IS the block, so the whole output must equal it.
        table_block gsx1000-volume.patch > "$TMP/patch-block.txt"
        if cmp -s "$TMP/gen.txt" "$TMP/patch-block.txt"; then
            ok "gen_table: reproduces the table block in gsx1000-volume.patch byte for byte"
        else
            ko "gen_table: reproduces the table block in gsx1000-volume.patch byte for byte" "$(diff "$TMP/patch-block.txt" "$TMP/gen.txt" | head -4 | tr '\n' '|')"
        fi
        # 101 entries, strictly increasing: the shape of the table itself.
        python3 - "$TMP/gen.txt" <<'EOF' && ok "gen_table: the block holds 101 strictly increasing entries" || ko "gen_table: the block holds 101 strictly increasing entries"
import re, sys
body = open(sys.argv[1]).read()
body = body[body.index("{") + 1:body.rindex("}")]
vals = [int(x) for x in re.findall(r"-?\d+", body)]
assert vals == sorted(vals) and len(vals) == len(set(vals)) == 101, f"{len(vals)} entries"
EOF

        # ---- mutations, each on a temporary copy, each must make the SAME check red.
        # (a) one value changed in a copy of the CSV: the generator cross-checks every
        #     value against the pcap and must fail, so nothing can be regenerated.
        d=$TMP/mut-csv; rm -rf "$d"; mkdir -p "$d/captures"
        # -L: the copies are always regular files inside $TMP, never symlinks back
        # into the tree, so the edit below can only touch the copy.
        cp -rL tools "$d/"
        cp -L captures/sweep-table.csv captures/08-sweep.pcap "$d/captures/"
        python3 - "$d/captures/sweep-table.csv" <<'EOF'
import sys
p = sys.argv[1]; lines = open(p).read().splitlines()
parts = lines[10].split(","); parts[1] = str(int(parts[1]) + 1); parts[2] = parts[1]
lines[10] = ",".join(parts); open(p, "w").write("\n".join(lines) + "\n")
EOF
        changed captures/sweep-table.csv "$d/captures/sweep-table.csv" "gen_table mutation: the CSV copy was really changed"
        if python3 "$d/tools/gen_table.py" > "$d/gen.txt" 2>&1; then
            ko "gen_table mutation: a changed CSV value is red" "the generator accepted the changed CSV"
        else
            ok "gen_table mutation: a changed CSV value is red"
        fi
        # (b) one value changed in a copy of the patch's table: the generator still
        #     produces the right block, which no longer equals the mutated block.
        d=$TMP/mut-patch; rm -rf "$d"; mkdir -p "$d"
        cp gsx1000-volume.patch "$d/gsx1000-volume.patch"
        python3 - "$d/gsx1000-volume.patch" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
start = s.index("+static const s16 snd_gsx1000_vol_table")
end = s.index("\n+};", start)
head, block, tail = s[:start], s[start:end], s[end:]
old = "-13978"                      # the 2 % entry, documented in PROTOCOL.md
assert old in block, "anchor value not found in the table block"
open(p, "w").write(head + block.replace(old, str(int(old) + 1), 1) + tail)
EOF
        changed gsx1000-volume.patch "$d/gsx1000-volume.patch" "gen_table mutation: the patch copy was really changed"
        table_block "$d/gsx1000-volume.patch" > "$TMP/mut-patch-block.txt"
        if cmp -s "$TMP/gen.txt" "$TMP/mut-patch-block.txt"; then
            ko "gen_table mutation: a changed value in the patch table is red" "the generated block equals the mutated block"
        else
            ok "gen_table mutation: a changed value in the patch table is red"
        fi
    else
        ko "gen_table: runs" "$(head -3 "$TMP/gen.err" | tr '\n' '|')"
    fi
else
    ko "tools/gen_table.py and gsx1000-volume.patch exist"
fi

# ---------------------------------------------------------------- 2 and 3. AUR packaging
AUR=packaging/aur
if [ ! -f "$AUR/PKGBUILD" ] || [ ! -f "$AUR/.SRCINFO" ]; then
    ko "packaging/aur/PKGBUILD and .SRCINFO exist"
elif ! command -v makepkg > /dev/null 2>&1; then
    skipped ".SRCINFO matches makepkg --printsrcinfo" "makepkg is not installed"
    skipped ".SRCINFO mutation: an edited field makes the comparison report a mismatch" "makepkg is not installed"
    skipped "AUR: package file list is exactly the three files under /usr/src/epos-gsx1000-\$pkgver/" "makepkg is not installed"
    skipped "AUR mutation: an extra packaged file is detected" "makepkg is not installed"
else
    ver=$(cat VERSION)

    # srcinfo_matches <dir>: 0 the .SRCINFO of <dir> equals what makepkg prints,
    # 1 they differ, 2 makepkg itself failed (never mistaken for a mismatch).
    srcinfo_matches() {
        local d=$1
        if ! (cd "$d" && makepkg --printsrcinfo > "$TMP/si.printed" 2> "$TMP/si.err"); then
            return 2
        fi
        grep -v '^[[:space:]]*$' "$d/.SRCINFO" | sed 's/[[:space:]]*$//' > "$TMP/si.committed"
        sed 's/[[:space:]]*$//' "$TMP/si.printed" | grep -v '^[[:space:]]*$' > "$TMP/si.trimmed"
        diff -u "$TMP/si.committed" "$TMP/si.trimmed" > "$TMP/si.diff"
    }
    srcinfo_matches "$AUR"; rc=$?
    case $rc in
        0) ok ".SRCINFO matches makepkg --printsrcinfo" ;;
        2) ko ".SRCINFO matches makepkg --printsrcinfo" "makepkg --printsrcinfo failed: $(head -2 "$TMP/si.err" | tr '\n' '|')" ;;
        *) ko ".SRCINFO matches makepkg --printsrcinfo" "$(head -6 "$TMP/si.diff" | tr '\n' '|')" ;;
    esac

    # pkglist_matches <pkgbuild-dir> <out-dir>: build the package from a tarball of the
    # working tree with the PKGBUILD of <pkgbuild-dir>, then compare its file list with
    # the expected one. 0 equal, 1 differ, 2 the build failed or no package was produced.
    # The file list is exactly the three files, plus the package metadata makepkg adds.
    cat > "$TMP/pkglist.want" <<EOF
.BUILDINFO
.INSTALL
.MTREE
.PKGINFO
usr
usr/src
usr/src/epos-gsx1000-$ver
usr/src/epos-gsx1000-$ver/dkms-build.sh
usr/src/epos-gsx1000-$ver/dkms.conf
usr/src/epos-gsx1000-$ver/gsx1000-volume.patch
EOF
    LC_ALL=C sort -o "$TMP/pkglist.want" "$TMP/pkglist.want"
    pkglist_matches() {
        local d=$1 out=$2
        if ! "$AUR/test-local.sh" "$d" "$out" > "$out.build.log" 2>&1; then
            return 2
        fi
        local pkg
        pkg=$(ls "$out"/*.pkg.tar.zst 2>/dev/null | head -1)
        [ -n "$pkg" ] || return 2
        bsdtar -tf "$pkg" | sed 's#/$##' | LC_ALL=C sort > "$out.list"
        diff -u "$TMP/pkglist.want" "$out.list" > "$out.list.diff"
    }
    rm -rf "$TMP/pkgbuild"
    pkglist_matches "$AUR" "$TMP/pkgbuild"; rc=$?
    case $rc in
        0) ok "AUR: package file list is exactly the three files under /usr/src/epos-gsx1000-$ver/" ;;
        2) ko "AUR: package file list is exactly the three files under /usr/src/epos-gsx1000-$ver/" "the build failed: $(tail -3 "$TMP/pkgbuild.build.log" | tr '\n' '|')" ;;
        *) ko "AUR: package file list is exactly the three files under /usr/src/epos-gsx1000-$ver/" "$(head -8 "$TMP/pkgbuild.list.diff" | tr '\n' '|')" ;;
    esac

    # ---- mutation of property 2: a temp copy of the PKGBUILD with a changed pkgrel.
    # The unmodified copy must match first (control), the edited copy must not.
    d=$TMP/mut-srcinfo; rm -rf "$d"; mkdir -p "$d"
    cp "$AUR/PKGBUILD" "$AUR/.SRCINFO" "$AUR"/epos-gsx1000-dkms.install "$d/"
    srcinfo_matches "$d"; rc=$?
    [ "$rc" = 0 ] && ok ".SRCINFO mutation: the unmodified copy matches (control)" || ko ".SRCINFO mutation: the unmodified copy matches (control)" "rc=$rc"
    cp "$d/PKGBUILD" "$TMP/pkgbuild.before"
    sed -i -E 's/^(pkgrel=).*/\12/' "$d/PKGBUILD"
    changed "$TMP/pkgbuild.before" "$d/PKGBUILD" ".SRCINFO mutation: the edit really changed the PKGBUILD copy"
    srcinfo_matches "$d"; rc=$?
    [ "$rc" = 1 ] && ok ".SRCINFO mutation: a changed pkgrel in the PKGBUILD makes the comparison report a mismatch" \
        || ko ".SRCINFO mutation: a changed pkgrel in the PKGBUILD makes the comparison report a mismatch" "rc=$rc (0 = not detected, 2 = makepkg failed)"

    # ---- mutation of property 3: an extra install line in a temp copy of the PKGBUILD.
    d=$TMP/mut-pkg; rm -rf "$d"; mkdir -p "$d"; cp "$AUR/PKGBUILD" "$AUR"/epos-gsx1000-dkms.install "$d/"
    python3 - "$d/PKGBUILD" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '    chmod 644 "$dst/dkms.conf"\n'
extra = anchor + '    install -Dm644 "$src/VERSION" "$dst/VERSION"\n'
assert anchor in s, "anchor line not found in PKGBUILD"
open(p, "w").write(s.replace(anchor, extra))
EOF
    changed "$AUR/PKGBUILD" "$d/PKGBUILD" "AUR mutation: the PKGBUILD copy really gained an install line"
    pkglist_matches "$d" "$d/out"; rc=$?
    [ "$rc" = 1 ] && ok "AUR mutation: an extra install line in the PKGBUILD makes the file list differ" \
        || ko "AUR mutation: an extra install line in the PKGBUILD makes the file list differ" "rc=$rc (0 = not detected, 2 = build failed)"
fi

# The counts go to the output gate above, which adds its own test and prints the summary.
printf '%s %s %s %s\n' "$pass" "$fail" "$skip" "$n" > "$EPOS_TESTS_COUNTS"
[ "$fail" = 0 ]
