# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end exists: the lexer, the parser, the
checker, the evaluator into the resource graph, templates and the formatter, the facts of this
machine through a local transport, and the engine that plans and applies `file`, `directory` and
`symlink` resources on this machine. No remote host is contacted yet.

```
fettle check [<vault options>] [dir]
fettle fmt [--check] [files…]
fettle graph --facts <fixture.json> --host <name> [<vault options>] [dir]
fettle facts --local [--json]
fettle plan --local [--host <name>] [<vault options>] [dir]
fettle apply --local [--host <name>] [--yes] [<vault options>] [dir]
fettle vault create|edit|view|encrypt|decrypt|rekey [<vault options>] <file>
```

- `check` parses and checks every `.fettle` file and `.tmpl` template of the project in `dir`, and
  renders each diagnostic with its source excerpt.
- `fmt` writes each file in its canonical form; `--check` only names the files that are not in it.
- `graph` evaluates the program for one host against a fact fixture and prints the resource graph.
- `facts --local` runs the facts script on this machine and prints its facts; `--json` prints them
  in the form of a fact fixture, so its output can be passed to `graph --facts`.

The modules under the front end:

- `shell`: `Command` (a program and its argument words, or `sh"…"` shell text), exact POSIX
  quoting (context-aware for `sh"…"` interpolations), and the probe script that runs many commands in one round trip with its output parser.
- `facts`: the read-only facts script (`uname`, `id`, `/etc/os-release`), its parser into `Facts`,
  and the JSON form fixtures use.
- `transport`: the `Transport` trait (run a script with bytes on its standard input, close) and
  `LocalTransport`, which runs `/bin/sh` here; the SSH transport is built against the same trait.
- `engine`: the plan, apply and verify loop over any `Transport`, the `Provider` trait each kind
  implements, the `file`, `directory` and `symlink` providers, and the pending-trigger record.

## Plan and apply

`fettle plan --local` evaluates the program for one host of the inventory (`--host`, or the only
one) against this machine's facts, probes every resource in one round trip, and prints what would
change:

```
me (macos 15.1, arm64)
  + directory /srv/site                             mode 0750
  ~ file /srv/site/index.html
      @@ -2 +2 @@
      -<h1>Old</h1>
      +<h1>New</h1>

Plan: 1 host; 1 to create, 1 to change, 0 to remove, 0 actions.
```

Only `file`, `directory` and `symlink` have providers so far; the kinds with actions (`service`,
`command`) come next, and until then a resource of another kind is an `x` line.

`+` creates, `~` changes (a line diff for text under 256 KiB), `-` removes (`present = false`), `>`
runs an action a trigger asked for, `x` is a resource that cannot be planned. A secret is shown as
`(secret)`, never its content. `plan` exits 0 when nothing would change, 2 when something would, 1 on
an error.

`fettle apply --local` prints the plan, asks at a terminal (`--yes` skips the question; away from a
terminal it is required), then applies each resource in order: probed again, changed, and probed once
more to verify it. A resource that fails skips only what depends on it. A file's content travels on
standard input to a temporary file beside the target, is checked by `validate` (`%s` names the staged
file) and moved into place, so a file that does not validate never replaces a working one. Before a
change that triggers an action, the action is written to the host's pending record
(`/var/lib/fettle/pending`, or `~/.local/state/fettle/pending` for a non-root login), and it is
cleared once the action has run, so an action a failed run left behind runs on the next one. `apply`
exits 0 when everything applied and 1 when anything failed.

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

fettle depends on [avin-lang/parsing](https://github.com/avin-lang/parsing) 0.6.0 for its parsing
of token streams.
