#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lattice-check-clean.XXXXXX")

cleanup() {
	case "$tmp" in
		"${TMPDIR:-/tmp}"/lattice-check-clean.*) rm -rf -- "$tmp" ;;
		*) printf 'refusing to remove unexpected test path: %s\n' "$tmp" >&2 ;;
	esac
}
trap cleanup EXIT HUP INT TERM

clean="$tmp/clean"
dirty="$tmp/dirty"
not_repo="$tmp/not-repo"
missing="$tmp/missing"

git init -q "$clean"
git init -q "$dirty"
mkdir -p "$not_repo"
printf 'dirty\n' >"$dirty/untracked.txt"

expect_pass() {
	name=$1
	repo=$2
	if ! output=$(make -s -C "$root" check-clean "WORKSPACE_REPOS=$repo" 2>&1); then
		printf 'not ok - %s unexpectedly failed\n%s\n' "$name" "$output" >&2
		exit 1
	fi
	printf 'ok - %s\n' "$name"
}

expect_fail() {
	name=$1
	repo=$2
	message=$3
	if output=$(make -s -C "$root" check-clean "WORKSPACE_REPOS=$repo" 2>&1); then
		printf 'not ok - %s unexpectedly passed\n' "$name" >&2
		exit 1
	fi
	case "$output" in
		*"$message"*) ;;
		*) printf 'not ok - %s failed without %s\n%s\n' "$name" "$message" "$output" >&2; exit 1 ;;
	esac
	printf 'ok - %s\n' "$name"
}

expect_pass clean "$clean"
expect_fail dirty "$dirty" 'workspace checkout is dirty:'
expect_fail missing "$missing" 'workspace checkout cannot be inspected:'
expect_fail non-repository "$not_repo" 'workspace checkout cannot be inspected:'

aggregate_repos="$clean $dirty $missing $not_repo"
if aggregate_output=$(make -s -C "$root" check-clean "WORKSPACE_REPOS=$aggregate_repos" 2>&1); then
	printf 'not ok - aggregate failures unexpectedly passed\n' >&2
	exit 1
fi
for expected in \
	"workspace checkout is dirty: $dirty" \
	"workspace checkout cannot be inspected: $missing" \
	"workspace checkout cannot be inspected: $not_repo"
do
	case "$aggregate_output" in
		*"$expected"*) ;;
		*) printf 'not ok - aggregate output omitted %s\n%s\n' "$expected" "$aggregate_output" >&2; exit 1 ;;
	esac
done
printf 'ok - aggregate reports every failure\n'

printf 'check-clean regression: 5/5 passed\n'
