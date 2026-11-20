#!/usr/bin/env zsh
# Integration targets for fettle: containers reached over SSH, run in the colima profile "fettle".
#
#   targets.zsh up [names...]     build and start targets (all when none named); idempotent
#   targets.zsh down              remove every target container
#   targets.zsh status            one line per target: state, mapped port
#   targets.zsh ssh-config        print a ~/.ssh/config block for the running targets
#   targets.zsh reset <name>      recreate a target fresh
#
# Environment: FETTLE_COLIMA_PROFILE (default fettle), FETTLE_DOCKER_CONTEXT (default
# colima-$FETTLE_COLIMA_PROFILE). The `default` docker context is never used.

setopt err_exit no_unset pipe_fail

here=${0:A:h}
stdir=$here/.state
profile=${FETTLE_COLIMA_PROFILE:-fettle}
ctx=${FETTLE_DOCKER_CONTEXT:-colima-$profile}
all_targets=(debian12 ubuntu2404 alpine3)
prefix=fettle-target-

dk() { docker --context $ctx "$@" }

die() { print -u2 -- "targets: $*"; exit 1 }

valid_name() {
  [[ ${all_targets[(Ie)$1]} -gt 0 ]] || die "unknown target '$1' (known: ${all_targets[*]})"
}

ensure_colima() {
  if ! colima status -p $profile >/dev/null 2>&1; then
    print -u2 "starting colima profile $profile"
    colima start $profile --cpu 2 --memory 4 --disk 30 --runtime docker >&2
  fi
  dk info >/dev/null 2>&1 || die "docker context $ctx does not answer"
}

ensure_key() {
  mkdir -p $stdir
  if [[ ! -f $stdir/id_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N "" -C fettle-integration -f $stdir/id_ed25519
  fi
  touch $stdir/known_hosts
}

# The container's mapped port on 127.0.0.1, or nothing.
port_of() {
  dk port $prefix$1 22/tcp 2>/dev/null | head -n 1 | sed 's/.*://' || true
}

is_running() {
  [[ "$(dk inspect -f '{{.State.Running}}' $prefix$1 2>/dev/null || true)" == true ]]
}

run_args() {
  case $1 in
    alpine3) print -- "--privileged" ;;
    *) print -- "--privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock --tmpfs /tmp" ;;
  esac
}

write_config() {
  ssh_config_block > $stdir/ssh_config
}

ssh_config_block() {
  local n p
  for n in $all_targets; do
    is_running $n || continue
    p=$(port_of $n)
    [[ -n $p ]] || continue
    print -- "Host fettle-$n"
    print -- "  HostName 127.0.0.1"
    print -- "  Port $p"
    print -- "  User fettle"
    print -- "  IdentityFile $stdir/id_ed25519"
    print -- "  IdentitiesOnly yes"
    print -- "  PasswordAuthentication no"
    print -- "  StrictHostKeyChecking accept-new"
    print -- "  UserKnownHostsFile $stdir/known_hosts"
    print -- "  LogLevel ERROR"
    print -- "  ConnectTimeout 5"
    print -- ""
    print -- "Host fettle-$n-pw"
    print -- "  HostName 127.0.0.1"
    print -- "  Port $p"
    print -- "  User fettlepw"
    print -- "  IdentityFile $stdir/id_ed25519"
    print -- "  IdentitiesOnly yes"
    print -- "  PasswordAuthentication no"
    print -- "  StrictHostKeyChecking accept-new"
    print -- "  UserKnownHostsFile $stdir/known_hosts"
    print -- "  LogLevel ERROR"
    print -- "  ConnectTimeout 5"
    print -- ""
  done
}

start_one() {
  local n=$1 p i
  if is_running $n; then
    print "$n: already running"
    return 0
  fi
  dk rm -f $prefix$n >/dev/null 2>&1 || true
  print "$n: building image"
  dk build -q -t fettle-target-img-$n --build-arg "PUBKEY=$(<$stdir/id_ed25519.pub)" \
    $here/images/$n >/dev/null
  print "$n: starting"
  dk run -d --name $prefix$n --hostname $n --label fettle.target=$n \
    ${=$(run_args $n)} -p 127.0.0.1::22 fettle-target-img-$n >/dev/null
  p=$(port_of $n)
  [[ -n $p ]] || die "$n: no mapped port"
  ssh-keygen -q -R "[127.0.0.1]:$p" -f $stdir/known_hosts >/dev/null 2>&1 || true
  write_config
  for i in {1..60}; do
    if ssh -F $stdir/ssh_config fettle-$n true >/dev/null 2>&1; then
      print "$n: ssh ready on 127.0.0.1:$p"
      return 0
    fi
    sleep 1
  done
  dk logs --tail 30 $prefix$n >&2 || true
  die "$n: ssh not ready after 60 s"
}

cmd_up() {
  local names=("$@") n
  (( $#names )) || names=($all_targets)
  for n in $names; do valid_name $n; done
  ensure_colima
  ensure_key
  for n in $names; do start_one $n; done
  write_config
}

cmd_down() {
  local ids
  colima status -p $profile >/dev/null 2>&1 || { print "colima profile $profile is not running; nothing to remove"; return 0 }
  ids=$(dk ps -aq --filter label=fettle.target)
  [[ -z $ids ]] || dk rm -f ${=ids} >/dev/null
  rm -f $stdir/ssh_config
  print "targets removed"
}

cmd_status() {
  local n p st
  if ! colima status -p $profile >/dev/null 2>&1; then
    print "colima profile $profile: stopped"
    return 0
  fi
  for n in $all_targets; do
    if is_running $n; then
      p=$(port_of $n)
      print "$n: running 127.0.0.1:$p"
    else
      print "$n: down"
    fi
  done
}

cmd_ssh_config() {
  colima status -p $profile >/dev/null 2>&1 || return 0
  ssh_config_block
}

cmd_reset() {
  [[ $# -eq 1 ]] || die "usage: targets.zsh reset <name>"
  valid_name $1
  ensure_colima
  ensure_key
  dk rm -f $prefix$1 >/dev/null 2>&1 || true
  start_one $1
  write_config
}

cmd=${1:-}
(( $# )) && shift
case $cmd in
  up) cmd_up "$@" ;;
  down) cmd_down ;;
  status) cmd_status ;;
  ssh-config) cmd_ssh_config ;;
  reset) cmd_reset "$@" ;;
  *) print -u2 "usage: targets.zsh up [names...] | down | status | ssh-config | reset <name>"; exit 2 ;;
esac
