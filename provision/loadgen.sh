#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_var IMAPTEST_URL IMAPTEST_SHA256
bin=$BENCH_ROOT/bin
install -d -m 0755 "$bin"
apt_install ca-certificates curl jq dnsutils swaks

if [[ ! -x $bin/mailbench ]]; then
	if [[ -n ${MAILBENCH_BINARY:-} && -x ${MAILBENCH_BINARY} ]]; then
		install -m 0755 "$MAILBENCH_BINARY" "$bin/mailbench"
	elif [[ -f $BENCH_ROOT/loadgen/Cargo.toml ]]; then
		apt_install build-essential pkg-config cmake
		if [[ ! -x /root/.cargo/bin/cargo ]]; then
			curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable >&2
		fi
		(
			cd "$BENCH_ROOT/loadgen" || exit 1
			RUSTFLAGS="-C target-cpu=native" /root/.cargo/bin/cargo build --release --locked
		) >&2
		install -m 0755 "$BENCH_ROOT/loadgen/target/release/mailbench" "$bin/mailbench"
	else
		die "no mailbench binary ($bin/mailbench or MAILBENCH_BINARY) and no $BENCH_ROOT/loadgen to build"
	fi
fi

fetch "$IMAPTEST_URL" "$bin/imaptest" "$IMAPTEST_SHA256"
chmod 0755 "$bin/imaptest"
install -d -m 0755 "$BENCH_ROOT/out"
register_services
log "load host ready: $("$bin/mailbench" --version 2>/dev/null || echo mailbench), imaptest installed"
