# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end exists: the lexer, the parser, the
checker, the evaluator into the resource graph, templates and the formatter. No host is contacted
yet.

```
fettle check [<vault options>] [dir]
fettle fmt [--check] [files…]
fettle graph --facts <fixture.json> --host <name> [<vault options>] [dir]
fettle vault create|edit|view|encrypt|decrypt|rekey [<vault options>] <file>
```

- `check` parses and checks every `.fettle` file and `.tmpl` template of the project in `dir`, and
  renders each diagnostic with its source excerpt.
- `fmt` writes each file in its canonical form; `--check` only names the files that are not in it.
- `graph` evaluates the program for one host against a fact fixture and prints the resource graph.

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
```

fettle depends on [avin-lang/parsing](https://github.com/avin-lang/parsing) 0.6.0 for its parsing
of token streams.
