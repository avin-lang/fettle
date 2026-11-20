# Integration targets

Containers that fettle's integration tests connect to over SSH, run in their own colima profile
(`fettle`) so they never touch Docker Desktop or another colima profile. The targets:

| Name | Image | Init | `sshd` service |
|---|---|---|---|
| `debian12` | `debian:12` | systemd | `ssh` |
| `ubuntu2404` | `ubuntu:24.04` | systemd | `ssh` |
| `alpine3` | `alpine:3.20` | OpenRC | `sshd` |

Each has two users, both with key-only SSH login (password login is off):

- `fettle`: passwordless `sudo`.
- `fettlepw`: `sudo` needs the password `fettlepw`.

## Bringing them up

Needs `colima` and the `docker` CLI. From this directory:

    ./targets.zsh up                  all targets
    ./targets.zsh up debian12 alpine3 some of them
    ./targets.zsh status
    ./targets.zsh ssh-config
    ./targets.zsh reset debian12      recreate one fresh
    ./smoke.zsh                       check every running target

`up` starts the colima profile if it is stopped (2 CPUs, 4 GiB, 30 GiB disk, docker runtime),
generates a test keypair, builds the images, starts the containers, and waits until SSH answers. It
is idempotent: a running target is left alone. Everything is addressed with
`docker --context colima-fettle`; set `FETTLE_COLIMA_PROFILE` or `FETTLE_DOCKER_CONTEXT` to change
that. The `default` docker context is never used.

The systemd targets run `--privileged` with the host cgroup namespace (cgroup v2), so they are
throw-away machines; never publish their ports beyond `127.0.0.1`. Each maps its port 22 to a
dynamic port on `127.0.0.1`, which `status` and `ssh-config` report.

## How tests use them

`ssh-config` prints a `~/.ssh/config`-style block per running target, and `up` also writes it to
`.state/ssh_config`:

    Host fettle-debian12            user fettle, passwordless sudo
    Host fettle-debian12-pw         user fettlepw, sudo with a password

(and likewise `fettle-ubuntu2404`, `fettle-alpine3`). Each block names the mapped port, the test
private key, `StrictHostKeyChecking accept-new`, and a known_hosts file in `.state/`. A test run
reads the file, or runs `ssh -F .state/ssh_config fettle-debian12 ...`, and uses `reset <name>` to
get a pristine machine. A recreated container has a new host key; `up` and `reset` drop the old
known_hosts entry for the port.

`.state/` (keypair, known_hosts, generated config) is git-ignored; no private key is committed.

fettle's own SSH tests (`tests/ssh_integration_tests.avin`, every test named `ssh target: …`) read
`.state/ssh_config`. Without it, or with a target that does not answer, each says it is skipped and
passes. To run them for real, from the repository root:

    tests/integration/run.zsh             up, then `avin test . "ssh target"`, a skip failing
    tests/integration/run.zsh "become"    only the tests whose names hold "become"

Some tests change their target: they add users (`fettletty`, `fettlettypw`, with `requiretty`), a
key to `fettle`'s `authorized_keys`, and doas on alpine3. `reset <name>` gives a fresh one.

## Tearing down

    ./targets.zsh down            remove the containers
    colima stop fettle            stop the VM, keeping images and disk
    colima delete fettle          remove the VM and all its images
