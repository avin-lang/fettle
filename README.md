# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end exists: the lexer, the parser, the
checker, the evaluator into the resource graph, templates and the formatter, and the facts of this
machine through a local transport. No remote host is contacted yet.

```
fettle check [dir]
fettle fmt [--check] [files…]
fettle graph --facts <fixture.json> --host <name> [dir]
fettle facts --local [--json]
```

- `check` parses and checks every `.fettle` file and `.tmpl` template of the project in `dir`, and
  renders each diagnostic with its source excerpt.
- `fmt` writes each file in its canonical form; `--check` only names the files that are not in it.
- `graph` evaluates the program for one host against a fact fixture and prints the resource graph.
- `facts --local` runs the facts script on this machine and prints its facts; `--json` prints them
  in the form of a fact fixture, so its output can be passed to `graph --facts`.

The modules under the front end:

- `shell`: `Command` (a program and its argument words, or `sh"…"` shell text), exact POSIX
  quoting, and the probe script that runs many commands in one round trip with its output parser.
- `facts`: the read-only facts script (`uname`, `id`, `/etc/os-release`), its parser into `Facts`,
  and the JSON form fixtures use.
- `transport`: the `Transport` trait (run a script with bytes on its standard input, close) and
  `LocalTransport`, which runs `/bin/sh` here; the SSH transport is built against the same trait.

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
