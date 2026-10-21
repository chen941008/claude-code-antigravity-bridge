#!/usr/bin/env bash
# Offline unit tests for extras/claude-hook/grok_guard.py, scripts/grok-worker.py,
# setup-grok.sh (trusted_folders.toml handling), and Git worktree permission provisioning.
# (No Claude, no real grok model calls, no credits.)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd -P)"
HOOK=extras/claude-hook/grok_guard.py
WORKER=scripts/grok-worker.py
fail=0

# expect <exit code> <description> <command> [extra tool_input JSON, default "timeout":600000]
expect() {
    local want=$1 desc=$2 cmd=$3 extra=${4:-'"timeout":600000'} event got
    event=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[3],"tool_input":{**json.loads("{"+sys.argv[2]+"}"),"command":sys.argv[1]}}))' "$cmd" "$extra" "$REPO_ROOT")
    printf '%s' "$event" | python3 "$HOOK" 2>/dev/null
    got=$?
    if [ "$got" = "$want" ]; then echo "ok   $desc"; else echo "FAIL $desc (want $want, got $got)"; fail=1; fi
}
# raw <exit code> <description> <raw stdin>
raw() {
    local want=$1 desc=$2 got
    printf '%s' "$3" | python3 "$HOOK" 2>/dev/null
    got=$?
    if [ "$got" = "$want" ]; then echo "ok   $desc"; else echo "FAIL $desc (want $want, got $got)"; fail=1; fi
}

W='python3 .grok/grok-worker.py'

# 1. Basic pass-through & zero-cost local discovery commands
raw    0 "non-Bash tool passes"           '{"tool_name":"Read","tool_input":{"file_path":"x"}}'
raw    0 "garbage input passes"           'not json'
expect 0 "unrelated bash passes"          'ls -la'
expect 0 "grok models passes"             'grok models'
expect 0 "grok inspect passes"            'grok inspect'
expect 0 "grok --version passes"          'grok --version'
expect 0 "grok --help passes"             'grok --help'
expect 0 "grok-ish word not caught"       'echo legrok -p' '"timeout":1'

# 2. Valid .grok/grok-worker.py invocations
expect 0 "worker read-only passes"                "$W --mode read-only --tier 1 -p \"review code\""
expect 0 "worker read-only explicit sandbox passes" "$W --mode read-only --sandbox read-only -p \"review code\""
expect 0 "worker write + worktree passes"         "$W --mode write --tier 2 --worktree feat -p \"implement\""
expect 0 "worker write + strict sandbox passes"   "$W --mode write --sandbox strict -p \"implement\""
expect 0 "worker write + workspace sandbox passes" "$W --mode write --sandbox workspace -p \"implement\""
expect 0 "worker write + read-only sandbox passes" "$W --mode write --sandbox read-only -p \"implement\""
expect 0 "worker --prompt-file passes"            "$W --mode write --prompt-file TASK.md"
expect 0 "worker =-style flags pass"              "$W --mode=read-only --tier=1 --max-turns=20 -p=\"hi\""
expect 0 "worker quoted values pass"              "$W --mode 'read-only' --max-turns '15' -p \"hi\""
expect 0 "worker background passes without timeout" "$W --mode read-only -p \"hi\"" '"run_in_background":true'
expect 0 "direct ./.grok/grok-worker.py passes"   "./.grok/grok-worker.py --mode read-only -p \"hi\""
expect 0 "Inside quotations ; | && are not split" "$W --mode read-only -p \"Fix A; then B | C && D\""
expect 0 "prompt merely mentioning /usage passes" "$W --mode read-only -p \"explain the /usage page\""
expect 0 "flag words inside prompt are ignored"   "$W --mode read-only -p \"never use --yolo or --sandbox off\""

# 3. P0: Shell comment (#), newline comment, bash -c, eval, $(...), backticks
expect 2 "P0: # comment hiding --mode caught"     "$W -p fix # --mode read-only"
expect 2 "P0: # comment after newline caught"     $'python3 .grok/grok-worker.py -p fix \\\n# --mode read-only'
expect 2 "P0: word#bar does not hide trailing bad flag" "$W --mode read-only -p foo#bar --sandbox workspace"
expect 2 "P0: bash -c unguarded grok caught"      'bash -c "grok -p fix"'
expect 2 "P0: sh -lc unguarded worker caught"     'sh -lc "python3 .grok/grok-worker.py -p fix"'
expect 0 "P0: bash -c with valid project worker passes" "bash -c '$W --mode read-only -p fix'"
expect 2 "P0: eval around worker caught"          "eval \"$W --mode read-only -p fix\""
expect 2 "P0: command substitution in worker call caught" "$W --mode read-only -p \"\$(cat p.txt)\""
expect 2 "P0: backtick substitution in worker call caught" "$W --mode read-only -p \`cat p.txt\`"

# 4. P1: Block direct headless `grok`, external `grok-worker.py` paths, and `python3 -c` / `node -e` bypasses
expect 2 "P1: direct grok -p without flags caught" 'grok -p "fix bugs"'
expect 2 "P1: direct grok -p EVEN WITH full flags caught (must use wrapper)" \
    'grok -p "fix bugs" --output-format json --permission-mode dontAsk --max-turns 30 --disallowed-tools run_terminal_cmd --sandbox strict'
expect 2 "P1: direct grok --prompt-file caught"   'grok --prompt-file TASK.md --output-format json --permission-mode dontAsk --max-turns 30 --disallowed-tools run_terminal_cmd'
# shellcheck disable=SC2088  # the command string itself must contain a literal ~
expect 2 "P1: full path ~/.grok/bin/grok -p caught" '~/.grok/bin/grok -p hi'
expect 2 "P1: untrusted /tmp/grok-worker.py caught" 'python3 /tmp/grok-worker.py --mode read-only -p "hi"'
expect 2 "P1: untrusted ../grok-worker.py caught" 'python3 ../grok-worker.py --mode read-only -p "hi"'
expect 2 "P1: direct /tmp/grok-worker.py executable caught" '/tmp/grok-worker.py --mode read-only -p "hi"'
expect 2 "P1: cd /tmp && python3 .grok/grok-worker.py caught" 'cd /tmp && python3 .grok/grok-worker.py --mode read-only -p "hi"'
expect 2 "P1: python3 -c indirect grok subprocess caught" "python3 -c 'import subprocess; subprocess.run([\"grok\",\"-p\",\"hi\"])'"
expect 2 "P1: node -e indirect grok caught"       "node -e 'require(\"child_process\").execSync(\"grok -p hi\")'"
expect 2 "P1: perl -e indirect grok caught"       "perl -e 'system(\"grok -p hi\")'"

# 4b. P1: Runners, shell keywords, variables, and directory changes around grok or the worker
expect 2 "P1: exec grok caught"                   'exec grok -p hi'
expect 2 "P1: timeout grok caught"                'timeout 600 grok -p hi'
expect 2 "P1: env -S split string caught"         "env -S 'grok -p hi'"
expect 2 "P1: grok after then caught"             'if true; then grok -p hi; fi'
expect 2 "P1: grok in brace group caught"         '{ grok -p hi; }'
expect 2 "P1: negated grok caught"                '! grok -p hi'
# shellcheck disable=SC2016  # $G must reach the hook unexpanded
expect 2 "P1: grok stored in a variable caught"   'G=grok; $G -p hi'
expect 2 "P1: find -exec grok caught"             'find . -exec grok -p hi \;'
expect 2 "P1: sudo grok caught"                   'sudo grok -p hi'
expect 2 "P1: caffeinate grok caught"             'caffeinate -i grok -p hi'
expect 2 "P1: quoted grok command for watch caught" "watch -n 5 'grok -p hi'"
expect 2 "P1: pushd before worker caught"         "pushd /tmp && $W --mode read-only -p hi"
expect 2 "P1: cd -- before worker caught"         "cd -- /tmp && $W --mode read-only -p hi"
expect 2 "P1: cd - before worker caught"          "cd /tmp && cd - && $W --mode read-only -p hi"
expect 2 "P1: env -C before worker caught"        "env -C /tmp $W --mode read-only -p hi"
expect 2 "P1: cd before bash -c worker caught"    "cd /tmp && bash -c '$W --mode read-only -p hi'"
expect 2 "P1: worker run from a subdirectory caught" "cd scripts && python3 ../.grok/grok-worker.py --mode read-only -p hi"
expect 2 "P1: worker --cwd elsewhere caught"      "$W --mode write --cwd /tmp -p hi"
expect 0 "worker --cwd . passes"                  "$W --mode read-only --cwd . -p hi"
expect 0 "worker after cd . passes"               "cd . && $W --mode read-only -p hi"
expect 0 "worker inside if/then passes"           "if [ -f TASK.md ]; then $W --mode read-only -p hi; fi"
expect 0 "worker via env -S passes"               "env -S '$W --mode read-only -p hi'"
expect 0 "which grok passes"                      'which grok'
expect 0 "command -v grok passes"                 'command -v grok'
expect 0 "grep for grok passes"                   'grep -rn grok scripts'
expect 0 "commit message mentioning grok passes"  'git commit -m "fix grok guard"'
expect 0 "PR title mentioning grok passes"        'gh pr create --title "Fix grok guard bypass"'

# 5. P1: Read-only mode sandbox downgrade & invalid sandbox checks
expect 2 "P1: read-only mode + --sandbox workspace caught" "$W --mode read-only --sandbox workspace -p \"Review this project\""
expect 2 "P1: read-only mode + --sandbox strict caught"    "$W --mode read-only --sandbox strict -p \"Review this project\""
expect 2 "P1: read-only mode + GROK_SANDBOX=workspace caught" "GROK_SANDBOX=workspace $W --mode read-only -p \"Review\""
expect 2 "P1: read-only mode + --allow-shell caught"       "$W --mode read-only --allow-shell -p \"Review\""
expect 2 "P1: read-only mode + --worktree caught"          "$W --mode read-only --worktree feat -p \"Review\""
expect 2 "P1: write mode + --sandbox off caught"           "$W --mode write --sandbox off -p \"fix\""
expect 2 "P1: write mode + --sandbox devbox caught"        "$W --mode write --sandbox devbox -p \"fix\""
expect 2 "P1: write mode + unverified custom sandbox caught" "$W --mode write --sandbox custom-unverified -p \"fix\""
expect 2 "P1: GROK_SANDBOX=off env caught"                 "GROK_SANDBOX=off $W --mode write -p \"fix\""

# 6. P2: --max-turns, --wall-timeout, Bash timeout, and /usage checks
expect 2 "P2: worker missing --mode caught"       "$W -p \"review code\""
expect 2 "P2: worker --max-turns 99999999 caught" "$W --mode write --max-turns 99999999 -p \"fix\""
expect 2 "P2: worker --max-turns 0 caught"        "$W --mode write --max-turns 0 -p \"fix\""
expect 2 "P2: worker --wall-timeout 99999 caught" "$W --mode write --wall-timeout 99999 -p \"fix\""
expect 2 "P2: missing Bash timeout caught"        "$W --mode read-only -p \"hi\"" '"timeout":0'
expect 2 "P2: short Bash timeout caught"          "$W --mode read-only -p \"hi\"" '"timeout":120000'
expect 2 "P2: /usage is a paid prompt"            "$W --mode read-only -p \"/usage\""
expect 2 "P2: /cost is a paid prompt"             "$W --mode read-only -p /cost"
expect 2 "real ; after valid worker + direct grok caught" "$W --mode read-only -p \"x; y\"; grok -p hi"

# 7. P2: Concurrency lock check & persistent worker.lock inode (no os.unlink race)
TMP_ROOT="$(mktemp -d /tmp/grok-suite.XXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_PROJ="$TMP_ROOT/proj"
export GROK_HOME="$TMP_ROOT/grokhome"
mkdir -p "$TMP_PROJ/.grok" "$GROK_HOME"

# Start an unrelated background process whose argv literally contains "grok -p"
python3 -c 'import time; time.sleep(2)' "grok -p fake_unrelated_arg" &
FAKE_PID=$!
event=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"timeout":600000,"command":"python3 .grok/grok-worker.py --mode read-only -p hi"}}))' "$TMP_PROJ")
if printf '%s' "$event" | python3 "$HOOK" 2>/dev/null; then
    echo "ok   P2: unrelated process with 'grok -p' in argv does not trigger false positive"
else
    echo "FAIL P2: unrelated process with 'grok -p' triggered false positive"; fail=1
fi
kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true

# Hold an actual flock on $TMP_PROJ/.grok/worker.lock and verify grok_guard.py blocks
python3 - "$TMP_PROJ/.grok/worker.lock" << 'PY' &
import fcntl, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.write(fd, json.dumps({"active": True, "pid": os.getpid(), "mode": "write"}).encode())
time.sleep(3)
PY
LOCK_PID=$!
sleep 0.2
printf '%s' "$event" | python3 "$HOOK" 2>/dev/null
if [ "$?" = "2" ]; then
    echo "ok   P2: active .grok/worker.lock blocks grok_guard.py"
else
    echo "FAIL P2: active .grok/worker.lock did not block grok_guard.py"; fail=1
fi
kill "$LOCK_PID" 2>/dev/null || true
wait "$LOCK_PID" 2>/dev/null || true
rm -f "$TMP_PROJ/.grok/worker.lock"

# 8. Direct unit tests of scripts/grok-worker.py
if python3 "$WORKER" --mode read-only --tier 1 -p "review" --cwd "$TMP_PROJ" --dry-run | grep -q '"--sandbox", "read-only"'; then
    echo "ok   worker --mode read-only sets --sandbox read-only and read-only tools"
else
    echo "FAIL worker --mode read-only dry-run output unexpected"; fail=1
fi

if python3 "$WORKER" --mode read-only --sandbox workspace -p "review" --cwd "$TMP_PROJ" --dry-run >/dev/null 2>&1; then
    echo "FAIL P1: worker --mode read-only --sandbox workspace should be rejected"; fail=1
else
    echo "ok   P1: worker --mode read-only --sandbox workspace rejected"
fi

if python3 "$WORKER" --mode write --tier 2 -p "edit" --cwd "$TMP_PROJ" --dry-run | grep -q '"--sandbox", "strict"'; then
    echo "ok   worker --mode write sets --sandbox strict"
else
    echo "FAIL worker --mode write dry-run output unexpected"; fail=1
fi

if python3 "$WORKER" --mode write --allow-shell -p "test" --cwd "$TMP_PROJ" --dry-run 2>/dev/null; then
    echo "FAIL worker --allow-shell should fail when .grok/config.toml has no Bash rule"; fail=1
else
    echo "ok   worker --allow-shell blocked without Bash(...) allow rule in .grok/config.toml"
fi

# 9. Test wall-clock timeout killing entire process group (exit code 124) AND persistent worker.lock inode
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/grok" << 'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --version|version|-v) echo "grok 1.0.62 (fake) [stable]" ;;
  models) printf 'Available models:\n  * grok-4.7-build-fast (default)\n' ;;
  inspect)
    cfg="$PWD/.grok/config.toml"
    n=0
    [ -f "$cfg" ] && n=$(grep -cE '^\s*"(Write|Edit|Read|Bash)\(' "$cfg" || true)
    printf '  Permissions\n  └ Source: %s (config)\n  └ %d loaded, 0 skipped\n' "$cfg" "$n"
    ;;
  worktree)
    shift
    if [ "${1:-}" = "create" ]; then
      name="${2:-auto}"
      wt_dir="$GROK_HOME/worktrees/$name"
      git worktree add --detach "$wt_dir" HEAD >/dev/null 2>&1
      cd "$wt_dir" && pwd -P
      exit 0
    fi
    ;;
  *)
    if [[ "$*" == *"hang"* ]]; then
      sleep 30
    else
      printf '{"text":"ok","stopReason":"end_turn","sessionId":"s1"}\n'
    fi
    ;;
esac
FAKE
chmod +x "$TMP_ROOT/fakebin/grok"

PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WORKER" --mode read-only -p "hang" --cwd "$TMP_PROJ" --wall-timeout 1 >/dev/null 2>&1
rc=$?
if [ "$rc" = "124" ]; then
    echo "ok   P2: worker wall-clock timeout kills child process group and exits 124"
else
    echo "FAIL P2: worker wall-clock timeout (want 124, got $rc)"; fail=1
fi

# Read-only leaves project metadata alone; write workers retain their diagnostic lock inode.
if [ ! -e "$TMP_PROJ/.grok/worker.lock" ]; then
    echo "ok   P2: read-only worker does not create a persistent worker.lock"
else
    echo "FAIL P2: read-only worker created a persistent worker.lock"; fail=1
fi
PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WORKER" --mode write -p "quick" --cwd "$TMP_PROJ" >/dev/null 2>&1
if [ -f "$TMP_PROJ/.grok/worker.lock" ]; then
    ino1=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TMP_PROJ/.grok/worker.lock")
    PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WORKER" --mode write -p "quick" --cwd "$TMP_PROJ" >/dev/null 2>&1
    ino2=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TMP_PROJ/.grok/worker.lock")
    active=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("active"))' "$TMP_PROJ/.grok/worker.lock")
    if [ "$ino1" = "$ino2" ] && [ "$active" = "False" ]; then
        echo "ok   P2: worker.lock persists without unlink (inode preserved across runs, active=False on idle)"
    else
        echo "FAIL P2: worker.lock inode or state mismatch (ino1=$ino1, ino2=$ino2, active=$active)"; fail=1
    fi
    # Also verify grok_guard.py does not block when worker.lock is idle (active=False)
    if printf '%s' "$event" | python3 "$HOOK" 2>/dev/null; then
        echo "ok   P2: idle worker.lock (active=False) allows next grok_guard.py call"
    else
        echo "FAIL P2: idle worker.lock blocked grok_guard.py"; fail=1
    fi
else
    echo "FAIL P2: worker.lock was unlinked after run"; fail=1
fi

# 10. P2: Test `trusted = false` in trusted_folders.toml is preserved and rejected by setup-grok.sh & grok-worker.py
UNTRUSTED_PROJ="$TMP_ROOT/untrusted_proj"
mkdir -p "$UNTRUSTED_PROJ"
git -C "$UNTRUSTED_PROJ" init -q
UNTRUSTED_REAL="$(cd "$UNTRUSTED_PROJ" && pwd -P)"
cat > "$GROK_HOME/trusted_folders.toml" << EOF
[folders."$UNTRUSTED_REAL"]
trusted = false
decided_at = 123
EOF
if (cd "$UNTRUSTED_REAL" && PATH="$TMP_ROOT/fakebin:$PATH" bash "$REPO_ROOT/setup-grok.sh" >/dev/null 2>&1); then
    echo "FAIL P2: setup-grok.sh succeeded despite trusted = false in trusted_folders.toml"; fail=1
else
    if grep -q "trusted = false" "$GROK_HOME/trusted_folders.toml"; then
        echo "ok   P2: setup-grok.sh rejects folder with trusted = false and preserves user decision"
    else
        echo "FAIL P2: setup-grok.sh modified trusted = false"; fail=1
    fi
fi
if python3 "$WORKER" --mode read-only -p "hi" --cwd "$UNTRUSTED_REAL" --dry-run >/dev/null 2>&1; then
    echo "FAIL P2: grok-worker.py accepted folder with trusted = false"; fail=1
else
    echo "ok   P2: grok-worker.py rejects folder with trusted = false"
fi

# 10b. setup-grok.sh moves a legacy grok-bridge block out of global config.toml and keeps user settings;
#      verify-grok.sh warns about Write/Edit grants left in global config by anything else.
MIG_PROJ="$TMP_ROOT/mig_proj"
mkdir -p "$MIG_PROJ"
git -C "$MIG_PROJ" init -q
cat > "$GROK_HOME/config.toml" << 'EOF'
[ui]
permission_mode = "always-approve"

# >>> grok-bridge: managed by setup-grok.sh, re-run it to update >>>
[permission]
allow = [
  "Write(/tmp/old-project/**)",
  "Edit(/tmp/old-project/**)",
]
# <<< grok-bridge <<<
EOF
if (cd "$MIG_PROJ" && PATH="$TMP_ROOT/fakebin:$PATH" bash "$REPO_ROOT/setup-grok.sh" >/dev/null 2>&1) \
   && ! grep -q "old-project" "$GROK_HOME/config.toml" \
   && grep -q 'permission_mode = "always-approve"' "$GROK_HOME/config.toml"; then
    echo "ok   P2: setup-grok.sh migrates the legacy global grok-bridge block and keeps user settings"
else
    echo "FAIL P2: setup-grok.sh did not migrate the legacy global grok-bridge block"; fail=1
fi
printf '[permission]\nallow = ["Write(/tmp/elsewhere/**)"]\n' > "$GROK_HOME/config.toml"
verify_out="$(cd "$MIG_PROJ" && PATH="$TMP_ROOT/fakebin:$PATH" bash "$REPO_ROOT/scripts/verify-grok.sh" 2>&1)"
case "$verify_out" in
    *"WARN  global config.toml grants Write/Edit in every project"*)
        echo "ok   P2: verify-grok.sh warns about Write/Edit grants in global config.toml" ;;
    *)
        echo "FAIL P2: verify-grok.sh missed Write/Edit grants in global config.toml"; fail=1 ;;
esac
rm -f "$GROK_HOME/config.toml"

# 11. P1: Test Git worktree permission provisioning (both `grok-worker.py --worktree` and `git worktree add`)
WT_REPO="$TMP_ROOT/wt_repo"
mkdir -p "$WT_REPO"
(
    cd "$WT_REPO" || exit 1
    git init -q
    git config user.email "t@e.com"
    git config user.name "t"
    echo "hi" > README.md
    git add README.md && git commit -qm "init"
    PATH="$TMP_ROOT/fakebin:$PATH" bash "$REPO_ROOT/setup-grok.sh" >/dev/null
)
WT_REPO_REAL="$(cd "$WT_REPO" && pwd -P)"

# 11a. A dry-run from a linked cwd must not provision; a real invocation must provision.
MANUAL_WT="$TMP_ROOT/manual_wt"
git -C "$WT_REPO_REAL" worktree add --detach "$MANUAL_WT" HEAD >/dev/null 2>&1
MANUAL_WT_REAL="$(cd "$MANUAL_WT" && pwd -P)"
if PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WT_REPO_REAL/.grok/grok-worker.py" --mode write -p "edit" --cwd "$MANUAL_WT_REAL" --dry-run >/dev/null 2>&1 \
   && [ ! -e "$MANUAL_WT_REAL/.grok" ]; then
    echo "ok   P2: linked cwd dry-run does not provision .grok/config.toml"
else
    echo "FAIL P2: linked cwd dry-run failed or provisioned files"; fail=1
fi
if PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WT_REPO_REAL/.grok/grok-worker.py" --mode write -p "edit" --cwd "$MANUAL_WT_REAL" >/dev/null 2>&1 \
   && [ -f "$MANUAL_WT_REAL/.grok/config.toml" ] \
   && grep -q "Write($MANUAL_WT_REAL/\*\*)" "$MANUAL_WT_REAL/.grok/config.toml" \
   && grep -q "Edit($MANUAL_WT_REAL/\*\*)" "$MANUAL_WT_REAL/.grok/config.toml"; then
    echo "ok   P1: linked git worktree auto-provisions .grok/config.toml with worktree Write/Edit rules"
else
    echo "FAIL P1: linked git worktree did not get provisioned .grok/config.toml"; fail=1
fi

# 11b. Running `grok-worker.py --mode write --worktree feature-a` creates & provisions the worktree
if PATH="$TMP_ROOT/fakebin:$PATH" python3 "$WT_REPO_REAL/.grok/grok-worker.py" --mode write --worktree feature-a -p "edit" --cwd "$WT_REPO_REAL" >/dev/null 2>&1; then
    CREATED_WT="$(cd "$GROK_HOME/worktrees/feature-a" && pwd -P)"
    if [ -f "$CREATED_WT/.grok/config.toml" ] \
       && grep -q "Write($CREATED_WT/\*\*)" "$CREATED_WT/.grok/config.toml" \
       && grep -q "Edit($CREATED_WT/\*\*)" "$CREATED_WT/.grok/config.toml"; then
        echo "ok   P1: grok-worker.py --worktree feature-a provisions worktree .grok/config.toml and trust"
    else
        echo "FAIL P1: grok-worker.py --worktree feature-a missing worktree rules in $CREATED_WT/.grok/config.toml"; fail=1
    fi
else
    echo "FAIL P1: grok-worker.py --mode write --worktree feature-a execution failed"; fail=1
fi

# 12. Repository membership, side-effect-free planning, prompt isolation, and fallback semantics.
if ! python3 scripts/test-grok-worker.py; then
    fail=1
fi

exit $fail
