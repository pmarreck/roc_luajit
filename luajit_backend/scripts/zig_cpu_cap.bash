# Sourced by ./build and ./test-all.
# Zig 0.16.0 segfaults while compiling `roc` when it sees more than 32 CPUs:
# its InternPool gives each thread 2^(30 - ceil(log2 threads)) item slots, and
# element-wise interning of roc's 27 MB embedded builtins array overflows them
# (ARCHITECTURE.md §8). Every Zig invocation runs under an explicit CPU
# affinity until the fix lands upstream.

readonly ROC_LUAJIT_DEFAULT_ZIG_CPUS=32

# Print the taskset CPU list ("0-N") for the configured cap, clamped to the
# host's CPU count. ROC_LUAJIT_HOST_CPUS overrides host detection for tests.
zig_cpu_list() {
	local cap="${ROC_LUAJIT_ZIG_CPUS-$ROC_LUAJIT_DEFAULT_ZIG_CPUS}"
	case "$cap" in
		'' | *[!0-9]* | 0)
			echo "error: ROC_LUAJIT_ZIG_CPUS must be a positive integer, got '$cap'" >&2
			return 2
			;;
	esac
	local host="${ROC_LUAJIT_HOST_CPUS:-$(nproc --all)}"
	if [ "$cap" -gt "$host" ]; then cap="$host"; fi
	echo "0-$((cap - 1))"
}

# Run (or, with dry_run=1, print) a command line.
run_or_print() {
	if [ "${dry_run:-0}" -eq 1 ]; then
		printf '%s\n' "$*"
	else
		eval "$*"
	fi
}

# The k-th (0-based) disjoint CPU window of the cap's width, so concurrent Zig
# invocations each see at most the cap; window 0 when the host has too few.
zig_cpu_window() {
	local k="$1" list
	list="$(zig_cpu_list)" || return 2
	local width=$((${list#0-} + 1))
	local host="${ROC_LUAJIT_HOST_CPUS:-$(nproc --all)}"
	if [ $(((k + 1) * width)) -le "$host" ]; then
		echo "$((k * width))-$(((k + 1) * width - 1))"
	else
		echo "$list"
	fi
}
