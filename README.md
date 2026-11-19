# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end exists: the lexer, the parser, the
checker, the evaluator into the resource graph, templates and the formatter. No host is contacted
yet.

```
fettle check [dir]
fettle fmt [--check] [files…]
fettle graph --facts <fixture.json> --host <name> [dir]
```

- `check` parses and checks every `.fettle` file and `.tmpl` template of the project in `dir`, and
  renders each diagnostic with its source excerpt.
- `fmt` writes each file in its canonical form; `--check` only names the files that are not in it.
- `graph` evaluates the program for one host against a fact fixture and prints the resource graph.

`tests/examples/site` holds the design's examples 2.1, 2.2, 2.3 and 2.5 as one project, and
`tests/golden` the graphs they evaluate to on Debian and Alpine.

```
avin test .
avin run . -- check tests/examples/site
avin run . -- graph --facts tests/fixtures/debian12.json --host web1 tests/examples/site
```

fettle depends on [avin-lang/parsing](https://github.com/avin-lang/parsing) by path
(`../parsing`), for its parsing of token streams; the dependency becomes a git and version one when
parsing 0.6.0 is released.
