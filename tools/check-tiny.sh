#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Run the deck's test overlays on the constrained (TinyGo) runtime.
#
# A deck that lists jennifer-tiny in [engines] claims to work there, and the
# examples alone are thin evidence. jennifer-tiny-dev is jennifer-tiny built
# with the development subcommands: the same runtime, stack and caps, plus
# `test`. When it is there, every suite from deck_test_suites runs through
# `jennifer-tiny-dev test`, exactly as the main job runs `jennifer test`. The
# interpreter images carry it from jennifer 0.26 on; `JENNIFER_TINY_DEV` names
# another binary.
#
# Without it (an older image, or a local jennifer-tiny alone), the fallback
# builds, per suite, one runner script in a scratch copy of src/: the module
# with `export` removed (a script may not export), the overlay spliced after
# it with `include`, then a call to every `test*` function inside try / catch.
# The runner counts passes and failures and exits non-zero on any failure.
# It differs from `jennifer test`: tests run in one script in file order,
# every function named `test*` in the suite and its includes is a test, and
# setUp / tearDown are not called. `JENNIFER` names the interpreter there
# (default jennifer-tiny). The scratch copy sits inside the deck, so a CI shim
# that mounts only the workspace sees it, and the deck's vendor/ is found
# above it.
#
# Either way the constrained build's own limits apply (a smaller call-depth
# limit, no network stack) - which is the point.
#
# Usage: tools/check-tiny.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/deck-lib.sh
deck_load

dev="${JENNIFER_TINY_DEV:-}"
if [[ -z "$dev" ]] && command -v jennifer-tiny-dev >/dev/null 2>&1; then
    dev=jennifer-tiny-dev
fi

status=0
if [[ -n "$dev" ]]; then
    while IFS= read -r suite; do
        [[ -n "$suite" ]] || continue
        echo "--- $suite on $dev"
        "$dev" test "$suite" || status=1
    done < <(deck_test_suites)
    if (( status != 0 )); then
        echo "the deck's tests fail on $dev"
        exit 1
    fi
    echo "the deck's tests pass on $dev"
    exit 0
fi

JENNIFER="${JENNIFER:-jennifer-tiny}"
echo "no jennifer-tiny-dev; running the overlays through runner scripts on $JENNIFER"
work="$(mktemp -d "$PWD/.check-tiny-XXXXXX")"
trap 'rm -rf "$work"' EXIT

while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    module="${suite%_test.j}.j"
    copy="$work/$(basename "${suite%_test.j}")"
    mkdir -p "$copy"
    cp -r src/. "$copy/"
    # A script may not export, so the module under test (and, for a topics
    # deck, the topics it splices in) loses its `export` keywords; the overlay
    # sees the names either way. Other modules it imports keep theirs.
    sed -i 's/^export //' "$copy/$(basename "$module")"
    if [[ "$DECK_SHAPE" == topics && -d "$copy/topics" ]]; then
        find "$copy/topics" -name '*.j' -exec sed -i 's/^export //' {} +
    fi
    runner="$copy/tiny_runner.j"
    {
        echo 'use io;'
        echo "include \"$(basename "$module")\";"
        echo "include \"$(basename "$suite")\";"
        echo 'def tinyPassed as int init 0;'
        echo 'def tinyFailed as int init 0;'
        # Every test function the suite reaches: its own file and the files it
        # includes (a topics deck splices topics/*_test.j).
        if [[ "$DECK_SHAPE" == topics ]]; then
            grep -rho '^func test[A-Za-z0-9]*' --include='*_test.j' "$copy"
        else
            grep -ho '^func test[A-Za-z0-9]*' "$copy/$(basename "$suite")"
        fi | sed 's/^func //' | sort -u | while IFS= read -r t; do
            printf 'try { %s(); $tinyPassed = $tinyPassed + 1; } catch (e) { $tinyFailed = $tinyFailed + 1; io.printf("FAIL %s: %%s\\n", $e.message); }\n' "$t" "$t"
        done
        echo 'io.printf("%d passed, %d failed\n", $tinyPassed, $tinyFailed);'
        echo 'if ($tinyFailed > 0) { exit(1); }'
    } > "$runner"
    echo "--- $suite on $JENNIFER"
    # A path relative to the deck root: a CI shim runs in the mounted
    # workspace, whatever the current directory here.
    if ! "$JENNIFER" run "${runner#"$PWD"/}"; then
        status=1
    fi
done < <(deck_test_suites)

if (( status != 0 )); then
    echo "the deck's tests fail on $JENNIFER"
    exit 1
fi
echo "the deck's tests pass on $JENNIFER"
