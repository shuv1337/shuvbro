#!/usr/bin/env bash
# Live demo: drive bin/fm-procevent.sh (register, _start, retire) against real
# processes. Usage: zombie-retire-demo.sh <repo-root>
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/zdemo.XXXXXX"); export FM_PROCEVENT_CLAIM_ROOT=$T/claims
BLOCKER=$T/blocker.sh
printf '#!/usr/bin/env bash\nwhile [ ! -e "$1" ]; do [ $SECONDS -lt 60 ] || exit 75; sleep 0.05; done\n' >$BLOCKER; chmod +x $BLOCKER
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
start_unreaped() { FM_HOME="$1" perl - "$3" "$ROOT/bin/fm-procevent.sh" _start "$2" >"$1/start.log" 2>&1 <<'PL' &
my $release = shift @ARGV; defined(my $pid = fork) or exit 125;
if ($pid == 0) { setpgrp(0,0) or exit 125; $ENV{FM_PROCEVENT_RUNNER_GROUP}=$$; exec @ARGV; exit 125; }
my $d = time + 60; while (!-e $release && time < $d) { select undef,undef,undef,0.05; } waitpid($pid,0);
PL
  echo $!; }
groupchild() { ps -A -o pid= -o pgid= -o stat= -o args= | awk -v g="$1" -v n="$BLOCKER" '$2==g && $1!=g && $3!~/^[ZX]/ && index($0,n){print $1; exit}'; }
waitz() { for _ in $(seq 1 400); do case "$(ps -o stat= -p $1 | tr -d ' ')" in Z*) return 0;; esac; sleep 0.05; done; return 1; }
scenario() { # <id> <mode: group|leader>
  local id=$1 mode=$2 H=$T/$1; mkdir -p $H/state
  echo "=== scenario $id ($mode kill) ==="
  pe $H register lavish $id -- $BLOCKER $T/$id.trigger >/dev/null
  P=$(start_unreaped $H $id $H/reap)
  for _ in $(seq 1 400); do [ -e $FM_PROCEVENT_CLAIM_ROOT/$id.claim ] && break; sleep 0.05; done
  R=$(sed -n 2p $FM_PROCEVENT_CLAIM_ROOT/$id.claim)
  for _ in $(seq 1 400); do [ -n "$(groupchild $R)" ] && break; sleep 0.05; done
  C=$(groupchild $R)
  if [ $mode = group ]; then kill -KILL -$R; else kill -KILL $R; fi
  waitz $R; sleep 0.3
  echo "runner $R stat=$(ps -o stat= -p $R | tr -d ' ') ; group members:"; ps -A -o pid=,pgid=,stat=,args= | awk -v g=$R '$2==g' | sed 's/^/   /'
  echo "\$ fm-procevent.sh retire $id"
  out=$(pe $H retire $id 2>&1); st=$?
  echo "$out" | sed 's/^/   /'; echo "   exit=$st"
  echo "   registration: $([ -e $H/state/procevent/$id.source ] && echo present || echo removed)"
  echo "   claim:        $([ -e $FM_PROCEVENT_CLAIM_ROOT/$id.claim ] && echo present || echo released)"
  [ -n "$C" ] && echo "   child $C: $(kill -0 $C 2>/dev/null && echo still-running '(not signalled)' || echo gone)"
  kill -KILL -$R 2>/dev/null; touch $H/reap; wait $P 2>/dev/null
  pe $H retire $id >/dev/null 2>&1
}
scenario zombie-only group
scenario zombie-live-child leader
rm -rf $T
