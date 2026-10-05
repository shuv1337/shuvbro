#!/usr/bin/env bash
# Runs the verbatim shell-resolution + jq guard extracted from the changed test
# against synthetic Herdr configs and pane process-info payloads (no Herdr).
set -u
E=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pi() { printf '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"%s"}]}}}\n' "$1" > "$W/after-exit.json"; }
run_new() { # $1=label $2=config-content-or-NONE $3=SHELL $4=fg-name $5=expect(0/1)
  rm -f "$W/config.toml"; [ "$2" = NONE ] || printf '%b' "$2" > "$W/config.toml"
  pi "$4"
  if [ -n "$3" ]; then shenv=(SHELL="$3"); pre=; else shenv=(); pre="unset SHELL;"; fi
  out=$(env -i PATH="$PATH" HERDR_SHELL_CONFIG="$W/config.toml" LAB="$W" "${shenv[@]}" bash -c "set -eu; $pre $(cat "$E/extracted-shell-guard.sh")
echo ok" 2>&1); rc=$?
  [ "$rc" = 0 ] || rc=1
  verdict=PASS; [ "$rc" = "$5" ] || verdict=FAIL
  printf '%-4s new  %-58s SHELL=%-14s fg=%-5s exit=%s expected=%s\n' "$verdict" "$1" "${3:-<unset>}" "$4" "$rc" "$5"
  [ "$rc" = 0 ] || printf '      stderr: %s\n' "$(echo "$out" | head -1)"
}
run_old() { pi "$2"; jq -e '.result.process_info | .foreground_process_group_id != .shell_pid and (.foreground_processes | length) == 1 and .foreground_processes[0].name == "zsh"' "$W/after-exit.json" >/dev/null; rc=$?
  printf 'BASE old  %-58s fg=%-5s exit=%s\n' "$1" "$2" "$rc"; }
echo "== base commit (4dbf0f5) hardcoded-zsh assertion =="
run_old "bash-login host, no default_shell (papercut repro)" bash
run_old "zsh host" zsh
echo "== changed fixture (828568966) =="
run_new "bash-login host, no herdr config (papercut)"   NONE /bin/bash bash 0
run_new "zsh login host, no config"                    NONE /usr/bin/zsh zsh 0
run_new "config without [terminal]"                    '[ui]\nfoo = 1\n' /bin/bash bash 0
run_new "default_shell=zsh overrides SHELL=bash"       '[terminal]\ndefault_shell = "zsh"\n' /bin/bash zsh 0
run_new "default_shell abs path /usr/bin/fish"          '[terminal]\ndefault_shell = "/usr/bin/fish"\n' /bin/bash fish 0
run_new "single-quoted default_shell"                  "[terminal]\ndefault_shell = 'bash'\n" /usr/bin/zsh bash 0
run_new "inline comment on value"                      '[terminal]\ndefault_shell = "zsh" # login\n' /bin/bash zsh 0
run_new "commented section header"                     '[terminal] # pane\ndefault_shell = "zsh"\n' /bin/bash zsh 0
run_new "commented-out default_shell ignored"          '[terminal]\n# default_shell = "zsh"\n' /bin/bash bash 0
run_new "empty default_shell falls back to SHELL"      '[terminal]\ndefault_shell = ""\n' /bin/bash bash 0
run_new "default_shell under other section ignored"     '[ui]\ndefault_shell = "zsh"\n[terminal]\n' /bin/bash bash 0
run_new "SHELL unset, no config -> /bin/sh"            NONE "" sh 0
run_new "non-allowlisted shell (nu) accepted"          NONE /usr/bin/nu nu 0
echo "== adversarial: mismatch must still fail =="
run_new "SHELL=bash but fg=zsh (wrong shell)"          NONE /bin/bash zsh 1
run_new "default_shell=zsh but fg=bash"                '[terminal]\ndefault_shell = "zsh"\n' /bin/bash bash 1
run_new "harness still in fg (fg=node)"                NONE /bin/bash node 1
