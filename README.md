# fettle

Agentless configuration management with its own typed, total language, written in
[Avin](https://github.com/avin-lang/avin). A program in `.fettle` files describes the state a set of
machines should be in; `fettle` checks it, connects to each machine over SSH, shows what differs as
a plan, and changes only that.

The design is [`docs/design.md`](docs/design.md). The front end is being built: the lexer, the
resource graph, the kinds' schemas and diagnostic rendering exist; `fettle check [dir]` reports
lexical errors with source excerpts.

```
avin test .
avin run . -- check <dir>
```
