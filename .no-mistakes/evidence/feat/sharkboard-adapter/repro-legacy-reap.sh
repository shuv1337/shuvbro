#!/usr/bin/env bash
# Repro: an ownerless (legacy, pre-2d9f63b mkdir-style) lock.reap directory is silently
# taken over instead of requiring manual reconciliation.
ROOT=$1 W=$2
export FM_HOME=$W/home FM_SHARKBOARD_CONFIG=$W/token.json FAKE_SHARK_STATE=$W/server.json FAKE_SHARK_FAIL=$W/fail PATH=$W/fakebin:$PATH
L=$FM_HOME/state/sharkboard; rm -rf $L/lock $L/lock.reap
sh -c 'exit 0' & d=$!; wait $d
mkdir $L/lock $L/lock.reap; printf '{"pid":%s,"start":"1"}' $d > $L/lock/owner
echo "before: lock/owner=$(cat $L/lock/owner); lock.reap contents=[$(ls -A $L/lock.reap)] (ownerless legacy mutex)"
$ROOT/bin/fm-sharkboard.sh publish; echo "publish exit=$?"
ls -d $L/lock.reap 2>/dev/null && echo "lock.reap preserved (expected)" || echo "lock.reap GONE: ownerless legacy recovery mutex was overwritten via rename(2) onto an empty dir and then deleted"
