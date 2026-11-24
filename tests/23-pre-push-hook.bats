#!/usr/bin/env bats
# Unit tests for hooks/pre-push's own logic: the VSTORM_SKIP_REVIEW short-circuit,
# the code-change gate, ref/base resolution (new-branch fallback chain), and the
# force-review path when a diff cannot be computed. A stubbed `claude` on PATH
# records whether reviews WOULD run, so no real /code-review or /security-review
# is ever launched and the tests never touch the network.
#
# The hook operates on the current working directory's git repo and reads pushed
# refs from stdin ("<local_ref> <local_sha> <remote_ref> <remote_sha>"), so each
# test runs it inside a throwaway repo with that line piped in.

HOOK="${BATS_TEST_DIRNAME}/../hooks/pre-push"
ZERO="0000000000000000000000000000000000000000"

setup() {
	_PP_DIR=$(mktemp -d)
	_PP_STUB=$(mktemp -d)
	export CLAUDE_CALL_LOG="$_PP_DIR/claude-calls.log"
	: > "$CLAUDE_CALL_LOG"
	# Stub claude: record the invocation (so a test can assert a review would
	# run) and exit 0 instead of launching a real review.
	cat > "$_PP_STUB/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CLAUDE_CALL_LOG"
exit 0
EOF
	chmod +x "$_PP_STUB/claude"

	_REPO="$_PP_DIR/repo"
	git init -q -b main "$_REPO"
	git -C "$_REPO" config user.email t@e.st
	git -C "$_REPO" config user.name test
	cd "$_REPO"
}

teardown() {
	[[ -n "${_PP_DIR:-}" ]] && rm -rf "$_PP_DIR"
	[[ -n "${_PP_STUB:-}" ]] && rm -rf "$_PP_STUB"
}

# Commit <path> with <content> and echo the resulting commit sha.
_commit() {
	local path=$1 content=$2
	mkdir -p "$_REPO/$(dirname "$path")"
	printf '%s\n' "$content" > "$_REPO/$path"
	git -C "$_REPO" add -A
	git -C "$_REPO" commit -q -m "touch $path"
	git -C "$_REPO" rev-parse HEAD
}

# ===================================================================
# PP: VSTORM_SKIP_REVIEW short-circuit
# ===================================================================

# hooks/pre-push with VSTORM_SKIP_REVIEW=1
@test "PP: VSTORM_SKIP_REVIEW=1 short-circuits before any review" {
	local head
	head=$(_commit vstorm "echo hi")
	run env VSTORM_SKIP_REVIEW=1 PATH="$_PP_STUB:$PATH" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $ZERO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"VSTORM_SKIP_REVIEW=1 -- skipping AI reviews"* ]]
	# claude must never be invoked.
	[[ ! -s "$CLAUDE_CALL_LOG" ]]
}

# ===================================================================
# PP: code-change gate
# ===================================================================

# hooks/pre-push gate: docs-only push
@test "PP: a docs-only push skips reviews (gate stays closed)" {
	local base head
	base=$(_commit README.md "v1")
	head=$(_commit README.md "v2")
	run env PATH="$_PP_STUB:$PATH" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $base"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no code changes in push -- skipping AI reviews"* ]]
	[[ ! -s "$CLAUDE_CALL_LOG" ]]
}

# hooks/pre-push gate: a watched code file opens the gate
@test "PP: a code change runs both advisory reviews" {
	local base head
	base=$(_commit README.md "v1")
	head=$(_commit helpers/foo.sh "echo hi")
	run env PATH="$_PP_STUB:$PATH" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $base"
	[ "$status" -eq 0 ]
	[[ "$output" == *"advisory reviews done"* ]]
	grep -q -- "/code-review" "$CLAUDE_CALL_LOG"
	grep -q -- "/security-review" "$CLAUDE_CALL_LOG"
}

# ===================================================================
# PP: ref/base resolution
# ===================================================================

# hooks/pre-push base resolution: new branch (remote_sha = 000…0)
@test "PP: a new branch with no remote resolves base to the root commit" {
	local root head
	root=$(_commit README.md "v1")
	head=$(_commit vstorm "echo hi")
	# remote_sha ZERO => new branch; no origin/HEAD or origin/main exist here, so
	# base falls through merge-base attempts to the root commit, and the vstorm
	# change between root and head opens the gate.
	run env PATH="$_PP_STUB:$PATH" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/feature $head refs/heads/feature $ZERO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"advisory reviews done"* ]]
	grep -q -- "/code-review" "$CLAUDE_CALL_LOG"
}

# ===================================================================
# PP: force-review fallback
# ===================================================================

# hooks/pre-push force_review: diff against an unknown base fails
@test "PP: an uncomputable diff forces a review instead of silently skipping" {
	local head
	head=$(_commit README.md "v1")
	# A plausible but absent object (not ZERO): git diff against it fails, which
	# must not be mistaken for "no changes".
	local bogus="1111111111111111111111111111111111111111"
	run env PATH="$_PP_STUB:$PATH" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $bogus"
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not diff"* ]]
	grep -q -- "/code-review" "$CLAUDE_CALL_LOG"
}

# ===================================================================
# PP: timeout-cap fallback
# ===================================================================

# hooks/pre-push: a requested cap (CLAUDE_REVIEW_TIMEOUT>0) with no `timeout`
# utility must skip the review, not run claude unbounded.
@test "PP: a requested cap with no 'timeout' utility skips the review" {
	local base head
	base=$(_commit README.md "v1")
	head=$(_commit helpers/foo.sh "echo hi")
	# A PATH with only the commands the gate path needs -- deliberately no
	# `timeout` -- so the hook sees a cap requested but no way to enforce it.
	local cleanbin="$_PP_DIR/cleanbin"
	mkdir -p "$cleanbin"
	ln -s "$(command -v bash)" "$cleanbin/bash"
	ln -s "$(command -v git)" "$cleanbin/git"
	cp "$_PP_STUB/claude" "$cleanbin/claude"
	run env PATH="$cleanbin" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $base"
	[ "$status" -eq 0 ]
	[[ "$output" == *"'timeout' not found"* ]]
	# The review must NOT have run unbounded.
	[[ ! -s "$CLAUDE_CALL_LOG" ]]
}

# hooks/pre-push: CLAUDE_REVIEW_TIMEOUT=0 opts into an unbounded review even when
# `timeout` is unavailable.
@test "PP: CLAUDE_REVIEW_TIMEOUT=0 runs the review uncapped without timeout" {
	local base head
	base=$(_commit README.md "v1")
	head=$(_commit helpers/foo.sh "echo hi")
	local cleanbin="$_PP_DIR/cleanbin"
	mkdir -p "$cleanbin"
	ln -s "$(command -v bash)" "$cleanbin/bash"
	ln -s "$(command -v git)" "$cleanbin/git"
	cp "$_PP_STUB/claude" "$cleanbin/claude"
	run env CLAUDE_REVIEW_TIMEOUT=0 PATH="$cleanbin" \
		bash "$HOOK" origin "file://$_REPO" <<< "refs/heads/main $head refs/heads/main $base"
	[ "$status" -eq 0 ]
	[[ "$output" == *"advisory reviews done"* ]]
	grep -q -- "/code-review" "$CLAUDE_CALL_LOG"
}
