#!/usr/bin/env zsh
# Checks every running integration target through the generated ssh config; exits non-zero on any
# failure. Bring targets up first with targets.zsh up.

setopt no_unset

here=${0:A:h}
stdir=$here/.state
failures=0
checked=0

declare -A expected_id expected_init
expected_id=(debian12 debian ubuntu2404 ubuntu alpine3 alpine)
expected_init=(debian12 systemd ubuntu2404 systemd alpine3 openrc)

fail() { print "  FAIL: $*"; failures=$(( failures + 1 )) }
ok() { print "  ok: $*" }

mkdir -p $stdir
$here/targets.zsh ssh-config > $stdir/ssh_config.smoke
cfg=$stdir/ssh_config.smoke

on() {
  local host=$1; shift
  ssh -F $cfg $host "$@"
}

for n in debian12 ubuntu2404 alpine3; do
  grep -q "^Host fettle-$n\$" $cfg || continue
  checked=$(( checked + 1 ))
  print "== $n"

  if on fettle-$n 'sudo -n true' >/dev/null 2>&1; then ok "fettle: sudo -n true"; else fail "fettle: sudo -n true"; fi

  osr=$(on fettle-$n 'cat /etc/os-release' 2>&1) || osr=""
  osid=$(print -r -- $osr | grep '^ID=' | head -n 1)
  pretty=$(print -r -- $osr | grep '^PRETTY_NAME=' | head -n 1)
  if [[ $osid == "ID=${expected_id[$n]}" ]]; then ok "os-release $pretty"; else fail "os-release ID is '$osid', want ${expected_id[$n]}"; fi

  who=$(on fettle-$n 'id' 2>&1) || who=""
  if [[ $who == uid=*"(fettle)"* ]]; then ok "id: $who"; else fail "id: '$who'"; fi

  if on fettle-$n-pw 'sudo -n true' >/dev/null 2>&1; then fail "fettlepw: sudo -n true succeeded, it must need a password"; else ok "fettlepw: sudo -n true refused"; fi
  if on fettle-$n-pw "echo fettlepw | sudo -S -p '' true" >/dev/null 2>&1; then ok "fettlepw: sudo with password"; else fail "fettlepw: sudo with password"; fi

  if ssh -F $cfg -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes fettle-$n true >/dev/null 2>&1; then fail "password login was accepted"; else ok "password login refused"; fi

  init=${expected_init[$n]}
  case $init in
    systemd)
      state=$(on fettle-$n 'systemctl is-system-running' 2>&1) || true
      if [[ $state == running || $state == degraded ]]; then ok "systemd is-system-running: $state"; else fail "systemd is-system-running: '$state'"; fi
      if on fettle-$n 'sudo systemctl restart ssh && systemctl is-active ssh' >/dev/null 2>&1; then ok "systemctl restart ssh"; else fail "systemctl restart ssh"; fi
      ;;
    openrc)
      comm=$(on fettle-$n 'cat /proc/1/comm' 2>&1) || comm=""
      if on fettle-$n 'rc-status -r' 2>&1 | grep -q default; then ok "openrc runlevel default (pid 1: $comm)"; else fail "openrc runlevel is not default"; fi
      if on fettle-$n 'sudo rc-service sshd restart >/dev/null 2>&1; rc-service sshd status' 2>&1 | grep -q started; then ok "rc-service sshd restart"; else fail "rc-service sshd restart"; fi
      ;;
  esac
done

rm -f $cfg
if (( checked == 0 )); then print "no running targets; run targets.zsh up"; exit 1; fi
if (( failures > 0 )); then print "smoke: $failures failure(s) in $checked target(s)"; exit 1; fi
print "smoke: all checks passed on $checked target(s)"
