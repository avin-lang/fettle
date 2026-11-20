# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end exists: the lexer, the parser, the
checker, the evaluator into the resource graph, templates and the formatter, the facts of this
machine through a local transport, and the SSH transport with `become`, which gathers a remote
host's facts. Nothing is changed on a host yet.

```
fettle check [<vault options>] [dir]
fettle fmt [--check] [files…]
fettle graph --facts <fixture.json> --host <name> [<vault options>] [dir]
fettle facts --local [--json]
fettle facts <host> [--json] [--dir d] [--ssh-config f] [--known-hosts f] [--accept-new]
fettle trust <host> [--yes] [--dir d] [--ssh-config f] [--known-hosts f]
fettle vault create|edit|view|encrypt|decrypt|rekey [<vault options>] <file>
```

- `check` parses and checks every `.fettle` file and `.tmpl` template of the project in `dir`, and
  renders each diagnostic with its source excerpt.
- `fmt` writes each file in its canonical form; `--check` only names the files that are not in it.
- `graph` evaluates the program for one host against a fact fixture and prints the resource graph.
- `facts --local` runs the facts script on this machine and prints its facts; `--json` prints them
  in the form of a fact fixture, so its output can be passed to `graph --facts`.
- `facts <host>` gathers a host's facts over SSH, as its login user. `<host>` is a host of the
  inventory in `--dir` (the current directory by default), reached as its `connect` settings say
  (`user`, `port`, `key`, `password`, `hostKey`), or else `[user@]host[:port]`, where `host` may be an
  alias of `~/.ssh/config` (or of `--ssh-config`).
- `trust <host>` shows the fingerprint of a host key the known-hosts file does not list and, once
  confirmed (`--yes` confirms at once), records it. A key that changed is refused; remove the old
  line with `ssh-keygen -R` first.

## Reaching a host

The SSH transport is [avin-lang/ssh](https://github.com/avin-lang/ssh) (libssh2), linked statically
with its OpenSSL, so running `fettle` needs neither; building needs them (`brew install libssh2`).

- **One session per host**, every script an exec on it of `exec /bin/sh -c '<script>'`, never the
  login shell; a file reaches the host as bytes on the script's standard input.
- **Host keys are strict** against `~/.ssh/known_hosts` (or the configuration's `UserKnownHostsFile`,
  or `--known-hosts`). An inventory `hostKey = "SHA256:…"` pins the key and reads no file;
  `--accept-new`, or `StrictHostKeyChecking accept-new` in the configuration, records a new host's
  key and still refuses a changed one.
- **Logging in**: the SSH agent first (unless `IdentitiesOnly yes`), then the inventory's `key`, then
  the configuration's `IdentityFile`s (else `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa`), a key under a
  passphrase tried again with `FETTLE_SSH_PASSPHRASE` or one typed at the terminal, then `password`.
- **`~/.ssh/config`** fills in what the inventory leaves out: `HostName`, `Port`, `User`,
  `IdentityFile`, `ProxyJump`, `ConnectTimeout` (else ten seconds), `ServerAliveInterval` (else 30 s).
  Through a `ProxyJump` the login is the configuration's own: the agent, then key files without a
  passphrase.
- **`become`**: `Sudo` runs `sudo -n`, `SudoPassword(secret)` runs `sudo -k -S -p ''` with the password
  as the first line of standard input and the script's own input after it, byte for byte (the
  password is checked once first, alone), `Doas` runs `doas -n`, `NoBecome` runs as the login user. A
  sudo or doas that refuses, wants a password, refuses the password or wants a terminal
  (`requiretty`) is an error saying which, never a failed script. A connection's secrets are read
  from `secret.env` and `secret.file`; `secret.vault` is not read for a connection yet.

Failures are `TransportError`s of a kind: `Unreachable` (DNS, refused, timed out, not SSH),
`HostKeyRefused`, `LoginRefused`, `BecomeRefused` and `Broken` (the session failed mid-run).

The modules under the front end:

- `shell`: `Command` (a program and its argument words, or `sh"…"` shell text), exact POSIX
  quoting (context-aware for `sh"…"` interpolations), and the probe script that runs many commands in one round trip with its output parser.
- `facts`: the read-only facts script (`uname`, `id`, `/etc/os-release`), its parser into `Facts`,
  and the JSON form fixtures use.
- `transport`: the `Transport` trait (run a script with bytes on its standard input, close),
  `LocalTransport`, which runs `/bin/sh` here, `SshTransport`, and `BecomeTransport`, which runs every
  script of the transport under it as another user.
- `hosts`: how a host named on the command line is reached, from the inventory or ad hoc.

## Secrets in a vault

A vault (`*.vault`) holds named secrets sealed under a passphrase, and is committed beside the
program. Its plaintext is one secret a line, in Fettle's own string syntax:

```
dbPassword = "hunter2"
tlsKey = """
  -----BEGIN PRIVATE KEY-----
  …
  -----END PRIVATE KEY-----
  """
```

A program reads one with `secret.vault("secrets.vault", "dbPassword")`, the file relative to the
file that names it. The value is a `secret`: never printed, compared or interpolated.

```
fettle vault create|edit|view|encrypt|decrypt|rekey [<vault options>] <file>
```

- `create` and `edit` open the plaintext in `$VISUAL` or `$EDITOR` (else `vi`) inside a fresh `0700`
  directory, seal it again with a new salt and nonce, and remove the plaintext. Text that does not
  read is offered for editing again, never saved.
- `view` prints the plaintext; `encrypt` and `decrypt` seal or open a file in place; `rekey` seals it
  under a new passphrase, from `--new-vault-password-file` or typed twice.
- The passphrase comes from `--vault-password-file <file>`, then `--vault-password-command <command>`,
  then `FETTLE_VAULT_PASSWORD`, else it is asked at the terminal without echo.
- `fettle check` checks the names a program reads when a passphrase is at hand without asking;
  `fettle graph` always does, asking if it must.

The file is text, so git diffs it as text: a header line
`$FETTLE_VAULT;1;XCHACHA20-POLY1305;ARGON2ID;<ops>;<mem>`, then base64 lines of 76 characters. The key
is derived with Argon2id and the text sealed with XChaCha20-Poly1305, the header bound to it, both
from [libsodium](https://libsodium.org), which is linked into `fettle` statically: building needs
libsodium (`brew install libsodium`; Debian's `libsodium-dev`), running does not.

## Tests and examples

`tests/examples/site` holds the design's examples 2.1, 2.2, 2.3 and 2.5 as one project, and
`tests/golden` the graphs they evaluate to on Debian and Alpine.

```
avin test .
avin run . -- check tests/examples/site
avin run . -- graph --facts tests/fixtures/debian12.json --host web1 tests/examples/site
avin run . -- facts --local
```

The SSH tests run against containers (`tests/integration/README.md`). Without them they say they are
skipped and pass; with them, one command brings them up and runs only those tests, failing where a
target does not answer:

```
tests/integration/run.zsh
```

fettle depends on [avin-lang/parsing](https://github.com/avin-lang/parsing) 0.6.0 for its parsing
of token streams.
