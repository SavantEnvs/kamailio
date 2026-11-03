#!/usr/bin/env bash
#
# mayhem/build.sh — build kamailio's core, the libFuzzer harnesses in misc/fuzz/, and the functional
# selftest. Runs in the commit image as `mayhem` in /mayhem (base ENV provides CC/SANITIZER_FLAGS/...).
# Re-runnable and offline: only the in-tree make system and apt-installed -dev packages are used.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TESTDIR="$SRC/build-test"
FUZZDIR="$SRC/build-fuzz"
LIBS="-ldl -lresolv -lm -lssl -lcrypto -lpthread"
mkdir -p "$TESTDIR" "$FUZZDIR"

# MEMPKG=sys makes pkg_malloc() use libc malloc, so ASan sees core pkg-memory bugs.
# Only the core (src/kamailio target) is built: the harnesses exercise core code, not modules.
kam_make() {
  make -C src Q=verbose MEMPKG=sys -j"$MAYHEM_JOBS" "$@"
}

# Archive every core/lib object (main.o with `main` renamed, so a harness's own main wins) into $1.
# The object set is the same for the test and fuzz builds.
make_archive() {
  local out="$1" mainobj="$2"
  rm -f "$out"
  objcopy --redefine-sym main=main_kamailio src/main.o "$mainobj"
  # shellcheck disable=SC2046
  ar rcs "$out" $(find src/core src/lib -name '*.o' | LC_ALL=C sort) "$mainobj"
}

# Preprocessor defines the project build uses (configuration macros the headers switch on); string
# valued defines are not needed by the harnesses and are dropped.
cdefs() {
  make -s -C src MEMPKG=sys printcdefs | tr ' ' '\n' \
    | grep -E '^-D[A-Za-z_0-9]+(=[0-9]+)?$' | tr '\n' ' '
}

# 1) Functional-test build: project's NORMAL flags (no sanitizers), plus the kamailio binary itself.
# kamailio freezes CFLAGS/LDFLAGS into src/config.mak at `make cfg` time and then skips Makefile.defs, so
# CC_EXTRA_OPTS/LD_EXTRA_OPTS given only to the build step are ignored: re-run `make cfg` with them.
make -C src Q=verbose clean >/dev/null
CC_EXTRA_OPTS="$COVERAGE_FLAGS" LD_EXTRA_OPTS="$COVERAGE_FLAGS" make Q=verbose MEMPKG=sys cfg >/dev/null
CC_EXTRA_OPTS="$COVERAGE_FLAGS" LD_EXTRA_OPTS="$COVERAGE_FLAGS" kam_make kamailio
cp src/kamailio "$TESTDIR/kamailio"
make_archive "$TESTDIR/libkamailio.a" "$TESTDIR/main_kamailio.o"
DEFS="$(cdefs)"
# shellcheck disable=SC2086
$CC -O1 $COVERAGE_FLAGS $DEFS -I src -I src/core "$SRC/mayhem/selftest.c" \
  "$TESTDIR/libkamailio.a" $LIBS -o "$TESTDIR/selftest"

# 2) Sanitized project build (ASan+UBSan, DWARF<=3) for the fuzzers.
make -C src Q=verbose clean >/dev/null
# -fsanitize=fuzzer-no-link: SanCov-instrument the library too ($LIB_FUZZING_ENGINE only covers the harness TU).
# `make cfg` must see the flags (see above), otherwise the core is built with the step-1 flags.
FUZZ_CC="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
FUZZ_LD="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
CC_EXTRA_OPTS="$FUZZ_CC" LD_EXTRA_OPTS="$FUZZ_LD" make Q=verbose MEMPKG=sys cfg >/dev/null
CC_EXTRA_OPTS="$FUZZ_CC" LD_EXTRA_OPTS="$FUZZ_LD" kam_make kamailio
make_archive "$FUZZDIR/libkamailio.a" "$FUZZDIR/main_kamailio.o"

# 3) LeakSanitizer off for every fuzz and standalone binary (ASan/UBSan stay active).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZDIR/lsan_off.o"

# 4) Harnesses, each linked twice: libFuzzer engine and the run-once standalone driver. The harnesses
#    call a few core functions that no header declares; clang >=16 rejects implicit declarations.
HFLAGS="$DEFS -Wno-implicit-function-declaration -I src -I src/core -I src/core/parser"
HARNESSES="fuzz_basex fuzz_check_boundaries fuzz_dns_rdata fuzz_msg_translator fuzz_parse_body \
fuzz_parse_digest fuzz_parse_msg fuzz_pv_parse fuzz_srjson fuzz_strutils fuzz_uri"
for h in $HARNESSES; do
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $HFLAGS $LIB_FUZZING_ENGINE \
      "misc/fuzz/$h.c" "$FUZZDIR/lsan_off.o" "$FUZZDIR/libkamailio.a" $LIBS -o "$SRC/$h"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $HFLAGS "$STANDALONE_FUZZ_MAIN" \
      "misc/fuzz/$h.c" "$FUZZDIR/lsan_off.o" "$FUZZDIR/libkamailio.a" $LIBS -o "$SRC/$h-standalone"
done
