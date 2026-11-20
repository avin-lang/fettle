# Fettle: agentless configuration management

Design, 2026-11-18. "Fettle" is the name of both the tool and its language (section 9); files end in
`.fettle`. The decisions taken on this design are in section 10.

Fettle reads a program that describes the state a set of machines should be in, checks it, connects
to every machine over SSH, works out what differs, shows that as a plan, and changes only what
differs. It is one native executable, written in Avin. The operator's machine needs nothing else;
each target needs only `sshd` and a POSIX shell.

---

## 1. Goals and non-goals

**Goals**

1. **Self-contained.** One executable parses, checks and evaluates the language and drives the
   hosts. No Avin compiler, Python, Ruby or Homebrew on the operator's machine; no agent, daemon,
   interpreter or pre-installed package on a target beyond `sshd` and `/bin/sh`.
2. **Idempotent by construction.** Every resource kind reads the current state before acting, so a
   second `apply` of an unchanged program reports zero changes. The test harness asserts this.
3. **Nothing touches a host until the whole program is valid.** Syntax, types, names, exhaustiveness,
   resource conflicts and ordering cycles are found before the first connection.
4. **A real language, small enough to learn in an afternoon.** Records, enums, lists, maps, functions,
   `if`, `match`, `for`; static types; total evaluation (section 3.4).
5. **Plan, then apply.** `plan` shows exactly what `apply` would do, per host, as diffs.
6. **First-class tooling from the first release:** checker with exact spans, formatter, language
   server, plan/apply, a test command.
7. **Many hosts at once**, with per-host timeouts, live output and a failure summary.
8. **Safe shell.** Commands are built from typed values; the engine quotes. Secrets never reach a
   terminal, a log, a plan or a process's argument list.

**Non-goals (v1)**

- Windows targets, network devices, anything without a POSIX shell.
- Provisioning cloud infrastructure (creating VMs, DNS records, load balancers). That is Terraform's
  job; Fettle configures machines that already exist.
- A state file. The hosts are the state; Fettle reads them every time (section 4.6 on removal).
- A pull mode, a central server, or continuous enforcement (mgmt's reactive model).
- Turing-complete computation in the language (section 3.4).
- A secrets server. Secrets come from the environment, a file, a local command, or a vault file
  encrypted with a passphrase and kept in the repository beside the program (decision 16 in
  section 10).
- A package registry. Modules come from directories now and git later.
- Container orchestration and image building (Kamal's territory), though section 2.7 shows a deploy.

---

## 2. Examples

A project is a directory. `inventory.fettle` names the hosts; other `.fettle` files hold roles, types
and templates, organised in modules by directory as Avin's are. Indentation is two spaces.

### 2.1 A web server: nginx, a TLS certificate, a reload on change

```fettle
// roles/web.fettle
module roles

data Site(domain: string, root: path = "/srv/www", port: int = 443)

role webServer(site: Site, certificate: string, key: secret)
  package "nginx"

  val tls = directory "/etc/nginx/tls"
    mode = 0o750

  val crt = file "${tls.path}/${site.domain}.crt"
    content = certificate
    mode = 0o644

  val k = file "${tls.path}/${site.domain}.key"
    content = key
    mode = 0o600

  val conf = file "/etc/nginx/conf.d/${site.domain}.conf"
    content = render("site.conf.tmpl", site = site, crt = crt.path, key = k.path)

  directory site.root
    owner = "www-data"

  service "nginx"
    running = true
    enabled = true
    on conf, crt, k -> reload
```

```fettle
// roles/site.conf.tmpl
@params(site: Site, crt: path, key: path)
server {
  listen ${site.port} ssl;
  server_name ${site.domain};
  root ${site.root};
  ssl_certificate ${crt};
  ssl_certificate_key ${key};
}
```

What the reader should see:

- `package`, `directory`, `file` and `service` are resource **kinds**; the string after the kind is the
  resource's **title** (its identity on the host).
- Order: `crt` and `k` refer to `tls`, so they come after it; everything else runs in the order
  written. The engine needs no `after` here.
- `key` is a `secret`: the plan prints `content: (secret) changed`, never the bytes, and it travels on
  standard input, never in an argument list.
- `on conf, crt, k -> reload` reloads nginx once, after all three, only if any of them changed.
- The template declares its parameters, so using `site.prot` in it, or passing a `string` for
  `site`, is an error at `fettle check` with the template's line.

### 2.2 Users and their SSH keys across a group

```fettle
// roles/people.fettle
module roles

data Person(name: string, keys: List[string], admin: bool = false)

role people(members: List[Person], departed: List[string])
  group "admins"

  for p in members
    user p.name
      shell = "/bin/bash"
      groups = if p.admin then ["admins"] else []
      authorizedKeys = p.keys

  for name in departed
    user name
      present = false

  file "/etc/sudoers.d/admins"
    content = "%admins ALL=(ALL) NOPASSWD: ALL\n"
    mode = 0o440
    validate = cmd("visudo", "-cf", staged)
```

```fettle
// team.fettle
val team = [
  Person("ana", ["ssh-ed25519 AAAAC3Nz…Qk ana@laptop"], admin = true),
  Person("bo", ["ssh-ed25519 AAAAC3Nz…7f bo@desk", "ssh-ed25519 AAAAC3Nz…a1 bo@phone"]),
]
```

`authorizedKeys` is exclusive: the user's `authorized_keys` holds exactly these lines afterwards. A
user with `groups = ["admins"]` depends on `group "admins"` because the engine knows a user's groups
name group resources (section 4.4). `staged` is the path of the uploaded file before it is moved into
place; it is a value of type `path` that exists only inside `validate`.

### 2.3 A per-distribution difference

```fettle
// roles/time.fettle
module roles

role timeSync(servers: List[string])
  val (unit, config) = match host.distro
    Debian(_) | Ubuntu(_) -> ("chrony", "/etc/chrony/chrony.conf")
    Fedora(_) | Rhel(_) -> ("chronyd", "/etc/chrony.conf")
    Alpine(_) -> ("chronyd", "/etc/chrony/chrony.conf")
    other -> fail "timeSync does not support ${other}"

  package "chrony"

  val conf = file config
    content = lines(for s in servers yield "server ${s} iburst")

  service unit
    running = true
    enabled = true
    on conf -> restart
```

`host.distro` is a typed fact (section 5.1), an enum, so the `match` must be exhaustive: leaving out
the last arm is a checker error naming the variants not covered (`Arch`, `Macos`, `Other(_)`, …). The
package manager (apt, dnf, apk) and the service manager (systemd, openrc) are picked from facts; the
program says `package "chrony"` once. `fail` stops evaluation for that host only, with this
position, and that host is reported as failed before anything is applied to it.

### 2.4 A reusable module

```fettle
// modules/postgres/postgres.fettle
module postgres

data Database(name: string, owner: string)

data Config(version: int = 16, listen: List[string] = ["127.0.0.1"], databases: List[Database] = [])

role server(config: Config)
  package "postgresql-${config.version}"

  val conf = file "/etc/postgresql/${config.version}/main/conf.d/fettle.conf"
    content = render("fettle.conf.tmpl", config = config)

  val svc = service "postgresql"
    running = true
    enabled = true
    on conf -> restart

  as "postgres"
    for db in config.databases
      database(db) after svc

private role database(db: Database)
  pgRole db.owner
  pgDatabase db.name
    owner = db.owner

// psql reads its query on standard input, where `:'v'` quotes the variable set by `-v`,
// so no name is ever spliced into SQL text.
private kind pgRole(name: string)
  probe = cmd("psql", "-tA", "-v", "r=${name}").stdin("SELECT 1 FROM pg_roles WHERE rolname = :'r'")
  ok = probe.stdout.trim() == "1"
  apply = cmd("psql", "-v", "r=${name}").stdin("CREATE ROLE :\"r\" LOGIN")
  show = "role ${name}"

private kind pgDatabase(name: string, owner: string)
  probe = cmd("psql", "-tA", "-v", "d=${name}")
    .stdin("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'d'")
  ok = probe.stdout.trim() == owner
  apply = cmd("createdb", "-O", owner, name)
  show = "database ${name} owned by ${owner}"
```

and its use:

```fettle
import postgres.{Config, Database, server}

apply db -> server(Config(databases = [Database("app", "app")]))
```

A module is a directory; `private` keeps a declaration inside it; `as "postgres"` runs the resources
it contains as that user (a lexical block, never a mode left switched on). A role used inside a role
(`database(db) after svc`) is a group of resources: `after` orders all of them. The module ships its
own kinds (2.6) for what no built-in kind covers. A database that exists with another owner is a
change `createdb` cannot make; its `apply` fails, and the verify step reports that it did not converge
rather than claiming success.

### 2.5 An inventory with per-host variables

```fettle
// inventory.fettle
import roles.{Site, people, timeSync, webServer}

data WebVars(domain: string, workers: int = 4, canary: bool = false)

connect all
  user = "deploy"
  become = Sudo
  key = "~/.ssh/deploy_ed25519"

group web: WebVars
  workers = 8
  host web1 at "10.0.0.11"
    domain = "a.example.com"
  host web2 at "10.0.0.12"
    domain = "b.example.com"
    canary = true
  rollout = Batches(size = 1, maxFailures = 0)

group db
  host db1 at "10.0.0.21"
    hostKey = "SHA256:Xo4kJtq1…"

apply all -> people(team, departed = ["carl"])
apply all -> timeSync(["0.pool.ntp.org", "1.pool.ntp.org"])
apply web as h ->
  webServer(
    Site(h.vars.domain),
    certificate = local("certs/${h.vars.domain}.crt"),
    key = secret.file("~/secrets/${h.vars.domain}.key")
  )
```

- A group declares the type of its hosts' variables; the group gives defaults, each host gives the
  rest. A host missing `domain` is a checker error at the host's line.
- `apply <group> [as h] -> <roles>` binds roles to hosts. Inside, `h: Host[WebVars]`, so
  `h.vars.domain` is typed. A host may be in several groups; each `apply` sees that group's vars.
- `local("…")` reads a file next to the program at check time (it is part of what the program means;
  section 3.3). `secret.file` reads at run time and is never printed.
- `connect` sets connection defaults for a group (`all` is every host); a group or host overrides.

### 2.6 A custom resource kind

```fettle
// kinds/sysctl.fettle
module kinds

kind sysctl(key: string, value: string)
  probe = cmd("sysctl", "-n", key)
  ok = probe.stdout.trim() == value
  apply = cmd("sysctl", "-w", "${key}=${value}")
  show = "${key} = ${probe.stdout.trim()} -> ${value}"

role tuned(settings: Map[string, string])
  for (k, v) in settings
    sysctl k
      value = v
  file "/etc/sysctl.d/90-fettle.conf"
    content = lines(for (k, v) in settings yield "${k} = ${v}")
```

A `kind` is a new primitive whose first parameter is its title: `probe` reads the current state, `ok` is a pure expression over the
probe's result (`stdout`, `stderr`, `exit`), `apply` makes the change, and `show` is the line the plan
prints. The engine runs `apply` only when `ok` is false, then probes again and fails the resource if
`ok` is still false. A kind has no way to run a command without a probe, so it cannot be
non-idempotent by accident. A group of existing resources is a `role`, not a `kind`.

### 2.7 What the commands print

```
$ fettle plan web
web1 (debian 12, amd64)
  + package nginx                                   install 1.22.1-9
  + directory /etc/nginx/tls                        mode 0750, owner root:root
  + file /etc/nginx/tls/a.example.com.crt           1.8 KiB
  + file /etc/nginx/tls/a.example.com.key           (secret)
  + file /etc/nginx/conf.d/a.example.com.conf       9 lines
  > service nginx                                   start, enable; reload if triggered
web2 (debian 12, amd64)
  ~ file /etc/nginx/conf.d/b.example.com.conf
      @@ -2 +2 @@
      -  listen 80 ssl;
      +  listen 443 ssl;
  > service nginx                                   reload (file /etc/nginx/conf.d/b.example.com.conf)

Plan: 2 hosts; 5 to create, 1 to change, 0 to remove, 2 actions.
```

```
$ fettle apply web
web1  [6/6]  changed 6
web2  [2/2]  changed 2
web1, web2: done in 41 s. 8 changed, 0 failed, 0 unreachable.
```

```
error[E0207]: the field `mode` of `file` is a `mode`, but this is a `string`
  --> roles/web.fettle:17:12
   |
17 |     mode = "0600"
   |            ^^^^^^ a string
   |
help: a mode is written as an octal literal: `mode = 0o600`
```

---

## 3. The language

### 3.1 Syntax sketch

Light and indentation-based, two spaces a level, in the family of Avin's syntax so the user's
projects read alike. Comments are `//`. A file may begin with `module a.b`; files in one directory
share a module.

```
file      = [module] {import} {decl}
decl      = data | val | role | fn | kind | apply | group | connect | test
data      = "data" Name ["(" params ")"] [NEWLINE INDENT {variant} DEDENT]
fn        = Name "(" params ")" "->" type "=" expr
role      = ["private"] "role" name "(" params ")" block
kind      = "kind" name "(" params ")" block           // fields probe, ok, apply, show
block     = INDENT {stmt} DEDENT
stmt      = resource | "val" pattern "=" expr | if | for | match | call [after]
          | "as" expr block | "on" refs "->" action | "after" refs | field
resource  = kindName expr [block]                      // title, then fields
field     = name "=" expr
expr      = literal | name | expr "." name | call | "if" … "then" … "else" …
          | "match" expr arms | "for" pattern "in" expr ["if" expr] "yield" expr
          | "[" … "]" | "{" key ":" expr … "}" | "(" exprs ")" | operator forms
string    = "…" with ${expr} interpolation; """…""" for multi-line text
```

`val x = <resource>` binds a reference to the resource (its fields are readable: `tls.path`). A role
call in statement position adds its resources; in `val` position it binds the group.

### 3.2 Types

- **Scalars:** `string`, `int` (64-bit, overflow is an error), `bool`, `path` (absolute, normalised),
  `mode` (`0o640`, range checked), `duration` (`30s`, `10m`), `size` (`512MiB`).
- **Literal types are checked where the value is known.** `path "etc/x"` and `mode 0o1777777` are
  errors at `fettle check`; a computed path that is not absolute is an evaluation error at the
  expression's span, for that host. No regex validation of strings anywhere.
- **`data`**: nominal records with defaults (`data Site(domain: string, port: int = 443)`) and
  algebraic types (variants indented under the name, as Avin writes them). Construction by position
  or by name; `with` copies with changes (`site with { port = 8443 }`).
- **Collections:** `List[T]`, `Map[K, T]` (keys `string` or `int`), `Set[T]`; optional values `T?`
  with `none`.
- **Facts and hosts:** `Host[V]`, `Distro`, `Arch`, `Os`, `Init` (section 5.1), all enums.
- **Resource references:** `File`, `Service`, `User`, …, each a subtype of `Resource`. Only a
  reference can appear in `on` and `after`.
- **`secret`**: opaque. It cannot be compared, interpolated into a `string`, or converted; it can be
  a resource field whose kind declares it secret-capable (`file.content`, `user.password`), or joined
  with text by `secret.concat`, which is again a `secret`.
- **`Command`**: built by `cmd(program, args…)` or the `sh"…"` form, whose literal text is shell
  (pipes, redirections) and whose interpolations are each quoted as one word. Never a string.
  `.stdin(text)` gives it input, a `string` or a `secret`; standard input is the only way a secret
  reaches a command.
- **No user-defined generics, classes, traits or subtyping** beyond resources. Built-in generic
  collections and functions (`map`, `filter`, `sortBy`, `groupBy`, `keys`, …) cover configuration.
- **Inference** is local. Parameters and the results of top-level `fn`s are written; `val`s are
  inferred. Records are checked against the expected type, so `{ … }` literals are rare.

### 3.3 Evaluation model

For each host, in this order:

1. **Parse and check every file** (no network). Positions on every node.
2. **Gather facts** for the hosts selected: one read-only shell script per host (5.1).
3. **Evaluate** the program for each host, with `host` bound to its facts and vars. Evaluation is
   **pure and deterministic**: no clock, no randomness, no environment variables, no network. The
   only inputs are the source files, files read with `local(…)` (read relative to the project, at
   check time, so they are part of the program), the inventory and the facts. Secrets are handles,
   resolved only by the engine when it needs the bytes.
4. The result is a **desired-state graph** of typed resources and trigger edges. It is checked:
   duplicate titles with conflicting fields, ordering cycles (reported with the cycle's path through
   source spans), and resource kinds no provider on this host can serve.
5. Only now does the **engine** read state (probes), diff, plan and apply.

Because evaluation is pure, `fettle check` can evaluate every host against cached facts
(`.fettle/facts/`) or fixtures with no connection, and the language server can do the same as you type.

### 3.4 How far computation goes: total

**Proposal: the language is total.** Every program terminates, by construction:

- No recursion: the call graph of `fn`s and roles must be acyclic; a cycle is a checker error that
  names it.
- No `while`, no unbounded loops. `for` ranges over a finite value (a list, a map, a set, a range of
  literal-bounded or computed `int`s).
- No higher-order recursion in disguise: a function value cannot be stored in a record and applied to
  itself, because functions are not first-class values beyond lambdas passed directly to the built-in
  collection functions.

Why total: configuration computes small things (names, lists, file contents). Starlark (Bazel)
dropped recursion and `while` for the same reason and is pleasant to use; Dhall and CUE show that
total configuration languages scale to large configurations; Nickel and Pkl chose general recursion
and in exchange cannot promise that `check` or the language server finishes. Totality buys:
`fettle check` over 500 hosts always finishes; the language server can evaluate on every keystroke; no
evaluation is ever a hang during a deploy. It costs: tree walks of arbitrary depth, which a
configuration does not need. Anything genuinely algorithmic happens on the host, through a command or
a custom kind. A size budget (evaluation steps, output bytes) stops a pathological program with a
clear error rather than a slow one.

### 3.5 What the checker refuses

Unknown names and fields (with the nearest spelling), type mismatches, non-exhaustive `match`,
unreachable arms, missing record fields, a group host missing vars, a `secret` in a `Command`'s
argument list or in a `string`, a `local(…)` file that does not exist, `staged` outside `validate`,
`on` naming something that is not a resource reference, an action the target kind does not have
(`on conf -> reload` on a `file`), call cycles, unused values and imports (warnings), duplicate
literal titles in one role (error unless identical, section 4.5).

---

## 4. Resources and the engine

### 4.1 The contract

Each kind is a value in the engine with:

| Part | What it is |
|---|---|
| **schema** | fields, types, defaults, documentation, which fields may hold a secret, the actions it offers (`service`: `start`, `stop`, `restart`, `reload`; `command`: `run`) |
| **providers** | per provider (apt, dnf, apk…): the probe, the diff, and the steps |
| **probe** | a POSIX shell fragment that prints the current state as `key=value` lines; the probes of every resource on a host are joined into **one script, one round trip** |
| **diff** | desired vs current → a list of typed changes; empty means `ok` |
| **steps** | changes → commands and uploads, run in order |
| **verify** | the probe again after the steps; still different means `failed: did not converge` |

A probe never changes anything. Apply probes each resource again just before acting on it, because an
earlier resource may have changed it (a package creates `/etc/nginx`); the plan's batch probe is the
preview, the per-resource probe is the truth.

### 4.2 The vocabulary (v1)

| Kind | Title | Main fields |
|---|---|---|
| `package` | name | `present`, `version` (exact or `latest`), `refresh` (index age) |
| `service` | name | `running`, `enabled`; actions `start`, `stop`, `restart`, `reload` |
| `user` | name | `present`, `uid`, `group`, `groups` (exclusive), `shell`, `home`, `system`, `authorizedKeys`, `password` (secret hash) |
| `group` | name | `present`, `gid`, `system` |
| `file` | path | `content` (string or secret), `source` (local file), `owner`, `group`, `mode`, `validate`, `present` |
| `directory` | path | `owner`, `group`, `mode`, `present`, `purge` (remove unmanaged entries, off by default) |
| `symlink` | path | `target`, `present` |
| `lineInFile` | path | `line`, `match` (anchored regex), `present` |
| `archive` | path | `url` or `source`, `sha256` (required), `into`, `creates` |
| `cron` | name | `schedule`, `user`, `command`; one file in `/etc/cron.d` per job |
| `command` | name | `run`, and one of `creates`, `unless`, `onlyIf`, or `on … -> run`; `always = true` says so |

`render(template, args…)` makes a `file`'s `content`. Templates are text files whose first line
declares typed parameters (`@params(site: Site)`); the body uses `${expr}` and `@for`/`@if` lines.
The same checker checks them, so a typo in a template is found at `fettle check` with the template's
line, which is the whole difference from Jinja.

A `command` with no guard and no trigger is a checker error; `always = true` makes it legal and the
plan shows it as `! runs every time`.

### 4.3 Files

Content goes to the host over the command channel's standard input, never SFTP and never an argument:
the engine writes it to a temporary file in the destination's directory, sets owner and mode, runs
`validate` on it (`staged`), and `mv`s it into place, so a reader never sees half a file and a config
that does not validate never replaces a working one. Comparison is by SHA-256 on the host
(`sha256sum`, `shasum -a 256` or `openssl dgst`, chosen from facts). The plan shows a unified diff for
text files under 256 KiB whose content is not a secret; otherwise sizes and `changed`.

### 4.4 Ordering

1. **References.** A field that names a resource (`tls.path`, `on conf`, `after svc`) orders after it.
2. **Known relationships** (Puppet's autorequire): a path after its parent `directory`; a file's
   `owner`/`group` after the `user`/`group` of that name; a user after the groups it lists; a
   `symlink` after its target if managed.
3. **Declaration order** for everything else, as Puppet does since 3.3: the program runs in the order a
   reader sees it. This removes almost every `after` from real programs and makes output stable.
4. **`after a, b`** where nothing above says it.

A cycle is a checker error (or an evaluation error when it depends on host values) printing each edge
with its source span and why it exists.

### 4.5 Identity and duplicates

A resource's identity is kind plus title per host (`package nginx`). Two declarations of one identity
with **identical** fields merge (two roles may both want `package "git"`); with any difference they
are an error that shows both positions and the differing fields.

### 4.6 Triggers

`on a, b -> action` adds a trigger edge. The action runs at most once per run, after every source it
names and before anything that depends on the triggered resource; it runs only if a source changed.
Ansible's handlers have a known hole: a run that changes the config and then fails before the handler
leaves the service on the old config, and the next run sees no change. Fettle closes it: before applying
a change that triggers an action, the engine records the pending action on the host
(`/var/lib/fettle/pending`, or `~/.local/state/fettle/pending` for a non-root login), and clears it when
the action has run. The next run starts by running anything still pending, which the plan shows.

**Removal** is explicit: `present = false`. There is no state file, so a resource deleted from the
program is no longer managed, not removed (section 10, decision 4).

### 4.7 Providers

Chosen from facts per host; a program can force one (`package "x"` with `provider = Apt`).

| Kind | v1 providers | later |
|---|---|---|
| `package` | apt, dnf, apk | pacman, zypper, brew |
| `service` | systemd, openrc | launchd |
| `user`/`group` | shadow utils (`useradd`…), busybox (`adduser`) | macOS `dscl` |

Adjacent `package` resources with no ordering edge between them install in one command. A provider's
index refresh (`apt-get update`) happens once per run, only when something will be installed, and
only if older than `refresh` (1 h by default).

---

## 5. Execution

### 5.1 Facts

One script, one round trip, read-only, POSIX `sh` plus `uname`, `id` and `/etc/os-release`; it
checks which tools exist with `command -v`. The result is typed:

```fettle
data Host[V](name: string, address: string, vars: V, os: Os, distro: Distro, arch: Arch,
             init: Init, cpus: int, memory: size, hostname: string, user: string, root: bool)
data Distro
  Debian(version: int)
  Ubuntu(version: string)
  Fedora(version: int)
  Rhel(version: int)
  Alpine(version: string)
  Arch
  Macos(version: string)
  Other(id: string)
```

`fettle facts <targets>` prints and caches them in `.fettle/facts/` (git-ignored), which `fettle check`
and the language server use. Custom facts (a typed probe) come later.

### 5.2 Plan

Text as in section 2.7: per host, one line per resource that is not `ok` (`+` create, `~` change,
`-` remove, `>` action, `!` command that always runs), unified diffs under changed text, secrets as
`(secret)`, then a summary line. `--json` writes the same plan for machines. `fettle plan -o plan.fettle-plan`
saves it; `fettle apply plan.fettle-plan` applies exactly that, refusing any host whose probes no longer
match what the plan saw (Terraform's saved plan). Exit status: 0 no changes, 2 changes, 1 error.

### 5.3 Apply and reporting

`apply` plans first and, at a terminal, asks before changing anything (`--yes` skips the question).
Each resource ends `ok`, `changed`, `failed` or `skipped` (a dependency failed); each host ends
`done`, `failed` or `unreachable`. The summary lists every failure with the host, the resource's
source span, the command (secrets elided), the exit status and the last 20 lines of its standard
error. `-v` streams every command's output, each line prefixed with its host.

### 5.4 Parallelism and fan-out

One lightweight thread per host (Avin's threads; libssh2 sessions run non-blocking on the runtime's
poller, so hundreds cost no worker each), at most `--parallel` (32) connected at once. Per host:
`--host-timeout` (default none) and a per-resource `timeout` (default 10 min) through `withTimeout`.
At a terminal, a live view (avin-lang/tui) shows one row per host: state, current resource, counts;
elsewhere, plain prefixed lines. A group's `rollout = Batches(size, maxFailures)` applies hosts in
batches and stops starting batches past `maxFailures`; Ctrl-C stops starting new resources, lets
running ones finish, records pending triggers and prints the summary.

### 5.5 Failure policy

- **Within a host:** a failed resource skips everything that depends on it (by any edge in 4.4,
  including triggers), and independent resources continue (Puppet's behaviour).
  `--stop-on-failure` stops the host at its first failure.
- **Across hosts:** other hosts continue; `--max-failures N` stops starting new hosts.
- **Unreachable** (connection, handshake, host key, authentication) is its own outcome, so a summary
  separates "the network is wrong" from "the program is wrong".

### 5.6 Become

The login user is `connect.user`. `become = Sudo | SudoPassword(secret) | Doas | None` sets how a
resource runs as another user, `root` by default; `as "postgres"` changes the user for a lexical block.
`Sudo` runs `sudo -n` (no password, failing at once rather than hanging on a prompt);
`SudoPassword` passes the secret on standard input with `sudo -S -p ''`. A file's content reaches a
root-owned path through the same channel (4.3), so no SFTP permission question arises.

### 5.7 Connection and authentication

- Through avin-lang/ssh (libssh2): agent first (`SSH_AUTH_SOCK`), then `key` files (passphrase a
  secret), then `password` (a secret, never a command-line option).
- **Host keys** are strict by default against `~/.ssh/known_hosts`. `hostKey = "SHA256:…"` pins one
  in the inventory. `fettle trust <targets>` connects, prints each fingerprint and adds it on
  confirmation; `--accept-new` does that during a run, for throwaway machines.
- One session per host per run, with keepalives; every command is an exec on it.

---

## 6. Tooling

### 6.1 The CLI

```
fettle check [path]              parse, check, evaluate every host against cached facts
fettle fmt [--check] [path…]     format in place
fettle lsp                       language server on standard input and output
fettle facts <targets>           gather, print and cache facts
fettle plan <targets> [-o file] [--json]
fettle apply <targets> | <plan file> [--yes] [--parallel n] [--stop-on-failure] [--max-failures n]
fettle test [filter] [--integration]
fettle trust <targets>
fettle graph <host>              the ordered graph as DOT
fettle explain <code>            the long form of a diagnostic
```

Targets: groups and hosts by name, `web,db`, `web:!web2`.

### 6.2 Checker and diagnostics

Every node has a span. The parser recovers (the parsing library's `recover`) and reports every
syntax error in a file; the checker reports every type error. Diagnostics carry a code, a primary
span, secondary labels, notes and a suggested edit where one is certain (the language server offers
it as a quick fix). Evaluation errors name the host and the span. Each code has an `explain` page.

### 6.3 Formatter

One style, no options: two spaces, one blank line between top-level declarations, aligned nothing,
comments kept, lines over 100 characters broken at list items. It parses its own output and compares
syntax trees before writing, as `avin fmt` does.

### 6.4 Language server (scope)

v1: diagnostics (including evaluation errors against cached facts), hover (types, a field's
documentation, a host's facts), go to definition (roles, types, templates, inventory hosts),
document symbols (resources as an outline), formatting, completion of field names, enum variants,
resource kinds and host names. Later: rename, references, semantic tokens, code actions beyond fixes.

### 6.5 Tests

Three levels, all through `fettle test`:

```fettle
// tests/web.test.fettle
import roles.{Site, webServer}

test "the key is private and nginx reloads when it changes"
  val g = evaluate(webServer(Site("x.test"), "CERT", secret.literal("KEY")), facts.debian(12))
  expect g.file("/etc/nginx/tls/x.test.key").mode == 0o600
  expect g.triggers(g.file("/etc/nginx/tls/x.test.key"), g.service("nginx"), Reload)

test "alpine uses openrc"
  val g = evaluate(timeSync(["pool.ntp.org"]), facts.alpine("3.20"))
  expect g.service("chronyd").provider == OpenRc

target debian12 = container("debian:12-systemd")
target alpine = container("alpine:3.20")
```

1. **Pure tests**: evaluate roles against fact fixtures and assert on the graph. No hosts, milliseconds.
2. **Snapshots**: `fettle test --snapshot` writes each role's from-scratch plan per fixture to
   `tests/snapshots/` and compares later runs with them.
3. **Integration**: `--integration` starts each `target` (a container with `sshd` through docker or
   podman, if present on the operator machine, or a local unprivileged `sshd` as avin-lang/ssh's tests
   do), applies the program, **applies it again and fails unless the second run changes nothing**,
   runs the program's `verify` commands, and removes the target. Docker is needed only for this
   level and only by whoever runs it.

---

## 7. How it is built in Avin

One package, `dev.avinlang.fettle` (renamed with the tool), one executable.

| Module | Holds | Rough size |
|---|---|---|
| `syntax` | lexer (indentation, interpolation, templates), parser with recovery, syntax tree with spans | 3,000 |
| `check` | name resolution, modules and imports, types, exhaustiveness, call-graph acyclicity, secret flow | 4,500 |
| `eval` | the interpreter: values, roles, `for`/`match`, templates; builds the graph | 2,000 |
| `graph` | identities, merging, ordering edges, cycles, triggers | 1,000 |
| `kinds` | schema and providers of each kind; custom kinds | 3,500 |
| `shell` | `Command`, POSIX quoting, script assembly, probe output parsing | 800 |
| `facts` | the facts script and its parser | 500 |
| `engine` | plan, apply, verify, pending triggers, failure policy | 2,000 |
| `transport` | sessions, become, uploads over stdin, a local transport for tests | 800 |
| `runner` | fan-out, timeouts, batches, live and plain output | 1,000 |
| `report` | plan text, line diffs, JSON, diagnostics rendering | 1,200 |
| `fmt` | formatter | 1,000 |
| `lsp` | protocol, the requests in 6.4 | 2,000 |
| `testing` | `test` blocks, fixtures, snapshots, targets | 1,200 |
| `cli` | commands and options | 600 |

About 25,000 lines with tests double that. Dependencies: avin-lang/ssh, avin-lang/parsing,
avin-lang/json, avin-lang/tui. The standard library supplies threads and timeouts, SHA-256, hex,
processes (for test targets), `glob`, signals.

The parser: a hand-written lexer that emits `INDENT`/`DEDENT`/`NEWLINE` and string-interpolation
tokens, with the grammar in the parsing library over those tokens. The checker and the evaluator are a
tree-walking front end on the Kite pattern in avin-lang/parsing's examples, which already shows a
checker that reports every mistake and a tree-walking evaluator in Avin.

---

## 8. Phased plan and what Avin needs

### 8.1 Phases

**Phase 1, the MVP: one real web server and its users, from a clean machine, twice.**
Syntax, checker, evaluator, templates; `check`, `fmt`, `facts`, `plan`, `apply`, `trust`, `test`
(pure and integration with the idempotence check); inventory with typed vars; kinds `package` (apt,
dnf, apk), `file`, `directory`, `symlink`, `user`, `group`, `service` (systemd, openrc), `command`
with guards; triggers with the pending record; secrets from env, file and command; `Sudo` and
`SudoPassword`; strict host keys and pins; fan-out with `--parallel`, timeouts and plain output;
language server: diagnostics, hover, definition, symbols, formatting. Examples 2.1, 2.2, 2.3 and 2.5
run end to end against containers.

**Phase 2.** Custom kinds (2.6), `lineInFile`, `archive`, `cron`; modules across directories with
`private` (2.4); saved plans and `--json`; the live terminal view; rollout batches; completion and
rename in the language server; snapshots; `graph`, `explain`; launchd, brew, pacman, `Doas`.

**Phase 3.** Modules from git with a lock file; reading `~/.ssh/config`; jump hosts; facts of other
hosts in a program (a two-pass run); custom facts; an opt-in managed set for pruning removed
resources; a dynamic inventory read from a command's typed JSON.

### 8.2 Avin features and libraries it needs

| Need | Status |
|---|---|
| Linking libssh2 and its crypto library **statically** into an Avin executable, so the binary needs no Homebrew at run time. | Present (avin 0.0.35: the manifest's `c-linking` block, static or dynamic per library) |
| Avin building and running on **Linux** (x86_64, arm64) for operators and CI on Linux. | **Planned** (avin's `docs/content/compiler/linux.md`; waits on Sysl's Linux builds) |
| avin-lang/ssh: requesting a **PTY** (for hosts whose sudoers say `requiretty`). | Present (ssh 0.0.1: `exec(…, pty = Some(Pty(…)))`) |
| avin-lang/ssh: **direct-tcpip channels** for jump hosts (phase 3). | Present (ssh 0.0.1: `tunnel(host, port)`, `ProxyJump`) |
| Reading `~/.ssh/config` (phase 3). | Present (ssh 0.0.1: `SshConfig.load()`, `connect(alias)`) |
| A **language server protocol library in Avin** (framing over stdio, the protocol's types). | Present (avin-lang/lsp; its `--stdio` transport is in progress) |
| A **line diff** (Myers) for plan output. | Present (avin 0.0.35: `avin.diff`, unified output) |
| The parsing library over a **token stream with indentation**. | Present (parsing 0.6.0: `Tokens`, `TokenParsers`); an offside-rule helper is in progress |
| Reading a **password or passphrase from the terminal without echo** (`SudoPassword`, key passphrases when not in env). | Present (avin 0.0.35: `avin.io.readSecret`) |
| Threads, `withTimeout`, SHA-256, hex, `glob`, processes, signals, TUI, JSON, parser error recovery. | Present |

---

## 9. Names

The name serves the tool, the language and the file extension, and is typed hundreds of times a day.

**fettle, chosen by the user 2026-11-18**: to fettle is to put a thing in good order, and "in fine
fettle" is the state the hosts are kept in; `fettle plan`, `fettle apply` read as commands; files end
in `.fettle`; the repository is avin-lang/fettle. The names weighed before it:

| Name | For it | Against it |
|---|---|---|
| tend | a verb for the job ("tend the web hosts"); four letters | a common English word, hard to search for |
| rig | short; "rig the servers" | many projects named rig |
| bosun | the ship's officer who keeps the gear in order; distinctive | harder to type and spell; an existing alerting tool was named Bosun |
| steward | clear meaning | long, and a common product name |
| muster | gathers hosts | says "gather", not "configure" |
| ward | to keep watch | reads as security tooling |

## Prior art: what is taken from each

| System | Taken | Left |
|---|---|---|
| **Ansible** | agentless over SSH, facts gathered first, idempotent modules, handlers, `validate` on files, `serial`/`max_fail_percentage` as rollout batches | YAML with Jinja (untyped, stringly, evaluated mid-run); per-task round trips; a Python dependency on the target; handlers lost on failure |
| **Puppet** | a typed resource graph; autorequire; manifest order as the default; a resource's identity and duplicate detection; skipping only dependents on failure; refresh (notify/subscribe) | an agent and a master; a language that grew ad hoc |
| **Chef** | resources with actions (`reload`, `restart`); `only_if`/`not_if` guards | a general-purpose host language, so specs are programs with side effects |
| **pyinfra** | two phases, compute operations then execute; a plain POSIX shell target | operations as Python with no static checking |
| **Nix / NixOS** | pure evaluation into a configuration, activation separate; deterministic inputs | the store, generations and the learning curve |
| **Terraform / HCL** | `plan`/`apply`, saved plans, the summary line and exit codes, the dependency graph from references, providers | a state file, which Fettle replaces with probing hosts that are themselves the state |
| **CUE, Dhall, Pkl, Nickel** | a typed configuration language with a formatter and language server from the start; Dhall's and CUE's totality, against Nickel's and Pkl's generality (3.4) | CUE's unification lattice and Dhall's lambda-calculus surface, both harder to read than records and functions |
| **Starlark** | no recursion, no `while`, deterministic, an interpreter embedded in one binary | Python's syntax and dynamic typing |
| **mgmt** | the idea that resources are a graph with typed edges | reactive, continuously running enforcement (a non-goal) |
| **Kamal** | rolling batches and a single command a person can run from a laptop; the deploy as an ordinary use of the tool | Docker as the unit of everything |
| **edadma/provision (2022)** | agentless single binary over libssh2; validate before touching a host; a small fixed vocabulary; terse specs | see the fixes below |

The 2022 prototype's problems, each answered: not idempotent (4.1, probe/diff/verify on every kind);
strings checked by regexes (3.2, typed literals checked by the checker); no abstraction (roles,
functions, `if`, `for`, `match`, typed vars); `become` and `def` as hidden global state (`as` blocks,
`val`, no mutation); no handlers (4.6); one host, a password on the command line, apt only (5.4,
5.7, 4.7); shell by concatenation (3.2 `Command`, `sh"…"`).

---

## 10. Decisions (2026-11-18)

1. **The name** is **fettle**, chosen by the user; files end in `.fettle`, and the repository is
   avin-lang/fettle.
2. **The syntax is indentation-based**, two spaces a level, in Avin's family, so one person's
   languages read alike and programs stay terse.
3. **The language is total**: no recursion, no `while` (section 3.4); this is revisited only for a
   real program that needs more.
4. **Removal is explicit** (`present = false`) in v1. An opt-in managed set (`prune = true` per kind)
   comes in phase 3, since silent removal is the most dangerous thing a configuration tool can do.
5. **Identical duplicate declarations merge**; any difference is an error showing both positions.
6. **The pending-trigger record** (`/var/lib/fettle/pending`) is kept on the target. It closes the
   lost-restart hole and is the only thing Fettle leaves on a host.
7. **Cross-host data:** inventory values of every host are visible to every host in v1; facts of
   other hosts come in phase 3.
8. **Files travel over the command's standard input**, never SFTP: it works with `become`, works
   where the SFTP subsystem is disabled, and is one code path.
9. **Integration targets are containers first** (docker or podman with systemd images), a local
   unprivileged `sshd` for the kinds that need no root, and VMs later only if systemd in containers
   proves unreliable.
10. **Static linking** of libssh2 and its crypto library becomes Avin's own item in its C bindings,
    done before phase 1 ships; until then development builds link dynamically.
11. **Operator platforms for the first release** are macOS arm64 and Linux x86_64, subject to the
    Linux unknown in 8.2.
12. **Package versions** are exact or `latest` in v1, never ranges, which would change plans with no
    program change.
13. **`apply` asks for confirmation at a terminal** after printing the plan; `--yes` skips it for
    scripts and CI.
14. **`become` defaults to root through `Sudo` when the inventory sets `become`**, since nearly every
    resource needs it; a host with no `become` runs as the login user.
15. **The inventory is static in v1**; phase 3 reads a local command's JSON against a declared type,
    so it stays checked.

### Decided 2026-11-19, for the first real use (a VPS)

The user's goal: *"get fettle to a point where i can use it to set up a vps"*, with Caddy as the web
server, and Fettle staying generally useful. These were decided on the user's delegation. Review with
the user.

16. **A vault is in phase 1** (the user asked for one, after Ansible's Vault). A vault file
    (`*.vault`) holds named secrets encrypted with a passphrase, and is meant to be committed beside
    the program.
    - **Plaintext:** one `name = "text"` or `name = """…"""` a line, in Fettle's own string syntax.
    - **Reading:** `secret.vault("secrets.vault", "dbPassword")` reads a secret from it, relative
      to the file that names it. `fettle check` checks the names when a passphrase is available, and
      `plan` always does.
    - **Commands:** `fettle vault create | edit | view | encrypt | decrypt | rekey <file>`.
    - **The passphrase comes from**, in order: `--vault-password-file`, `--vault-password-command`,
      `FETTLE_VAULT_PASSWORD`, else a prompt at the terminal without echo. There is one passphrase
      a run in v1; several vault ids come later if needed.
    - **Crypto is libsodium, bound directly** (the user: any C library may be bound), and linked
      statically through the manifest's `c-linking` block, so the binary still stands alone.
      - Argon2id (`crypto_pwhash`) derives the key from the passphrase and a fresh salt, with its
        ops and memory limits stored in the header.
      - The cipher is XChaCha20-Poly1305 IETF with a random 24-byte nonce and the header as
        associated data.
      - Adding scrypt and XChaCha20-Poly1305 to `avin.crypto` was the alternative. It was left
        because a reviewed C library was at hand and Avin has no other user for them yet.
    - **The file is text:** a header line `$FETTLE_VAULT;1;XCHACHA20-POLY1305;ARGON2ID;<ops>;<mem>`,
      then base64 lines of 76 characters, so git sees a text file.
    - **`edit`** decrypts into a fresh `0700` directory, runs `$VISUAL`/`$EDITOR`, re-encrypts with a
      new salt and nonce, and removes the plaintext. A file that does not parse after editing is
      offered for re-editing, never saved.
17. **Caddy needs no Caddy-specific kind.** It is a `package`, a `file` for the Caddyfile (with
    `validate = cmd("caddy", "validate", "--config", "%s", "--adapter", "caddyfile")` style
    validation), and a `service` reloaded on change; Caddy obtains its own certificates.
    - **`aptRepository` joins phase 1's kinds**, since every vendor repository (Caddy, Docker,
      Node, PostgreSQL) needs one. Its fields are name, URIs, suites, components, and a signing
      key fetched from a URL and pinned by its SHA-256, written to `/etc/apt/keyrings/` and named by
      `signed-by` in a deb822 `.sources` file. A changed repository refreshes the package index
      before any package is applied.
    - **A `download` kind** (url, sha256, path, owner, mode) joins too, for single binaries and
      keys that come from no repository.
18. **A worked VPS example**: one Debian or Ubuntu host. It sets up an admin user with SSH keys,
    hardens sshd (no passwords, no root login, validated with `sshd -t` and reloaded), enables the
    firewall with `ufw` through guarded `command`s, turns on unattended upgrades, and runs Caddy
    serving a site. It ships in `examples/vps` and is run end to end against the test containers.
19. **The vault's details**, settling what 16 leaves open:
    - **The body** is base64 of the 16-byte salt, the 24-byte nonce, then the ciphertext and its
      16-byte tag. The associated data is the header line without its line end. A header's limits
      must lie within 1–16 passes and 8 KiB–4 GiB, checked before any key is derived, so a changed
      header cannot make opening take minutes or exhaust memory; new vaults use libsodium's moderate
      limits (3 passes, 256 MiB). Reading accepts CRLF line ends.
    - **The plaintext** allows `//` comments and blank lines, kept as written since the text is sealed
      as it is; a line is not indented, and a string holds no `${…}` (`\$` writes a dollar). Its errors
      are `E05xx` (`E0501` a line that is no secret, `E0502` a name given twice, `E0503` an
      interpolation); `secret.vault`'s are `E0250`–`E0253` in the checker and `E0320`–`E0321` in
      evaluation.
    - **Passphrase sources:** a file's or a command's text loses one line end; the command runs under
      `/bin/sh -c`; a source that fails or gives an empty passphrase is an error, never a fall to the
      next source. `rekey` takes the new passphrase from `--new-vault-password-file`, otherwise
      prompts twice; `encrypt` confirms a typed passphrase as `create` does.
    - **`check` never prompts**: it checks a vault's names only with a file, a command or
      `FETTLE_VAULT_PASSWORD`, and otherwise leaves them to the run that opens the vault. `graph` (and
      later `plan`) asks, once a run, and only when the program names a vault; each vault is opened
      once.
    - **Commands:** `encrypt` and `decrypt` work in place; `encrypt` refuses a file that is already a
      vault or whose secrets do not read. Every write goes to `<file>.fettle-new` and is renamed over
      the file. The editor is run as `/bin/sh -c '<editor> "$1"'`, so `$EDITOR` may carry arguments
      (`code --wait`), on `<name>.txt`; an editor that fails saves nothing, and text left unchanged
      leaves the file unchanged rather than resealing it. `create` refuses an existing file; an empty
      vault is a vault.
    - **A secret's bytes never enter the graph:** `secret.vault` evaluates to a secret recording its
      vault and name, and the bytes are read where a host needs them. Keys and passphrases live in
      `ByteBlock`s outside the collected heap and are wiped with `sodium_memzero`; plaintext that
      passes through Avin strings cannot be wiped.

    Review with the user.

### Decided during phase 1a

Each of these settles something the sections above leave open, in their direction. Review with the
user.

1. **A line continues the one above only when it is indented further and begins with `.`** (a call
   chain, as `pgDatabase`'s `probe` in 2.4). Inside `(`, `[` and `{` line ends are white space.
   Review with the user.
2. **Indentation errors:** a tab, a block indented other than two spaces past its opener, and a
   line that lines up with no open block are each an error at the line, and lexing carries on.
   Review with the user.
3. **Duration and size units** are `ms`, `s`, `m`, `h`, `d`, and `B`, `kB`, `MB`, `GB`, `TB`,
   `KiB`, `MiB`, `GiB`, `TiB`, written right after the digits; any other letters there are an
   error. Digits may be grouped with `_` (`1_000`). Review with the user.
4. **String escapes** are `\n \t \r \0 \\ \" \$` and `\u{…}` (one to six hex digits, not a
   surrogate). A `$` not followed by `{` is text. A one-line string, and an interpolation in it,
   ends with its line. Review with the user.
5. **`"""…"""` text** drops a line end right after the opening quotes; the closing quotes alone on
   their line set a margin, which is taken off every line, and the line end before them is dropped.
   Review with the user.
6. **`sh"…"`** is one token only when `sh` touches the quote; `sh "…"` is the name `sh` and a
   string. Review with the user.
7. **Ordering ties**: resources with no ordering between them keep declaration order, by a stable
   topological sort; declaration order is the tie-break, not an edge, so an `after` against it never
   makes a cycle. A cycle is reported once, starting at its earliest declared resource. Review with
   the user.
8. **Known relationships** use the nearest managed directory above a path, the `owner` and `group`
   fields of files and directories, a user's `group` and `groups`, and a symlink's `target` when a
   `file` or `directory` of that path is declared. Review with the user.
9. **A duplicate declaration that runs as another user (`as`) conflicts**, as a field difference
   does. Review with the user.
10. **The architecture fact's type is `Cpu`** (`Amd64`, `Arm64`), since `Arch` is already a variant
    of `Distro`; `Init` is `Systemd | OpenRc | Launchd | NoInit`, `Os` is `Linux | Darwin | FreeBsd`,
    and `Become` is `Sudo | SudoPassword(secret) | Doas | NoBecome`, so no variant is named `None`
    beside the value `none`. Review with the user.
11. **A computed `string` may stand where a `path` is wanted**; the checker checks literals (absolute)
    and evaluation checks computed values, normalising `//`, `.` and `..`. Review with the user.
12. **A trigger's target is ordered after its sources**, as the trigger edge itself; `on` names
    references only, and a name that is not bound is an unknown name, so a trigger on an undeclared
    resource is refused at `fettle check`. Review with the user.
13. **Diagnostic codes**: `E01xx` lexical and syntax (`E0150` a syntax error, `E0151` a `module`
    line naming another directory's module), `E02xx` checker (`W02xx` warnings), `E03xx`
    evaluation, `E04xx` the graph. Review with the user.
14. **The parser reads tokens by predicate** (avin-lang/parsing's `token(what, p)` and `tokenMatch`),
    not by `==` (decided 2026-11-19). A `Span` keeps its real equality: the graph's duplicate check,
    the diagnostics and the tests compare spans, and an equality under which all spans are equal
    would make two declarations at different places look like one. Review with the user.
15. **A file's module is its directory's**: the directory's path relative to the project with `.`
    for `/`, the root's being the root module. A file may omit its `module` line; one naming another
    module is an error (`E0151`). Review with the user.
16. **`val g = r(…)` where `r` is a role binds the role's group** (a role call); with a function it
    binds a value. The parser cannot tell the two apart, so the project resolves it once every file
    is parsed. Review with the user.
17. **Templates** are `*.tmpl` files. The first line is `@params(name: Type, …)`; the rest is text in
    which `${expr}` is an interpolation, `$${` writes `${`, and nothing else is an escape, so a
    configuration file's backslashes stay as written. A template's module is its directory's.
    `render("name.tmpl", arg = …)` reads the template relative to the file that renders it, checks
    its arguments against the parameters as a call's, and checks the template's interpolations
    against its parameters, so `site.prot` is an error at the template's line. Review with the user.
18. **A trailing comma** is allowed before the closing bracket of a list, a map, a call's arguments,
    a parameter list, a `with` and an import's names. Review with the user.
19. **`;` separates the arms of a one-line `match e { p -> x; q -> y }`**, the form the formatter
    writes for a `match` inside another expression; a `match` standing as a value is written with
    its arms on the lines under it. Review with the user.
20. **The formatter's layout**: two spaces a level and lines of at most 100 characters. A longer line
    breaks at its outermost call, list or map, one item a line; list and map items each end with a
    comma, call arguments are separated by them, and the closing bracket stands on its own line, as
    examples 2.2 and 2.5 write them. One blank line stands between top-level declarations, except
    that a one-line declaration directly under one of its sort (`apply` under `apply`, `val` under
    `val`) stays with it; inside a block, one blank line stands where the source had any. Comments
    are kept, on their own lines at the level of what follows, or at the end of the line they ended.
    A group's settings and hosts keep their order. `else` holding only an `if` is written
    `else if`; `(x) -> e` is written `x -> e`; ranges are spaced like the other operators
    (`1 ..< 4`). Review with the user.
21. **A line indented between a block's indentation and the one outside it** is an error (`E0103`)
    and stays in the block it is misaligned in, so its statements are still checked there.
    Review with the user.
22. **A secret interpolated into `sh"…"`** is refused as a secret in a command's argument list
    (`E0209`), since each interpolation of shell text is one word of the arguments. Review with the
    user.
23. **A resource's kind may be the word `group`** (`group "admins"` in a role), which is also the
    inventory's declaration; at the top level `group` declares an inventory group, in a block it is
    the kind. Review with the user.
24. **Example 2.2's `team.fettle` imports `Person`** (`import roles.{Person}`), since `Person` is
    declared in the module `roles`; the examples as the tests hold them (`tests/examples/site`) add
    that line and are otherwise as written here. Review with the user.
25. **Phase 1's parser reads no `kind` and no `test` declaration**; the kinds of 2.4 and 2.6 come
    with custom kinds, and a `kind` line is a syntax error until then. Review with the user.
26. **Integration targets run in their own colima profile `fettle`** (docker runtime, addressed as
    `docker --context colima-fettle`, never the `default` context), as three images under
    `tests/integration/images`: `debian12` and `ubuntu2404` (systemd as PID 1, run `--privileged` on
    cgroup v2) and `alpine3` (OpenRC), each with `sshd`, `sudo`, key-only login for `fettle`
    (passwordless sudo) and `fettlepw` (sudo needs the password `fettlepw`). `targets.zsh` brings
    them up on dynamic `127.0.0.1` ports and prints an ssh config; the test keypair is generated
    into a git-ignored `.state/`. Review with the user.
27. **Shell quoting**: a word of ASCII letters, digits and `_ @ % + : , . / -` is written as it is;
    any other word, the empty one included, goes in single quotes with each `'` written `'\''`.
    `=` and `~` are not plain, so a quoted first word is never an assignment or a home directory.
    A NUL is refused: by `render` for a command, and as `E0320` for an `sh"…"` interpolation, each
    of which is quoted as one word as 3.2 says (it had been pasted in unquoted). The quoting of an
    `sh"…"` interpolation follows the shell quoting of the literal text before it (outside quotes,
    inside `'…'`, inside `"…"`, a backslash escaping outside single quotes): outside quotes it is one
    word as above; inside `"…"` the value gets a backslash before each `"`, `\`, `$` and backtick and
    lands verbatim, so `sh"echo \"hello ${name}\""` is right; inside `'…'`, or straight after a
    backslash, no quoting can land it exactly, and the checker refuses it as `E0244`, at the
    interpolation. Command substitutions and comments in the literal text are not tracked. Review
    with the user.
28. **One probe script, many commands**: each command runs in a subshell with standard input from
    `/dev/null` (shell text through `/bin/sh -c`, so a syntax error fails only that command), its
    output and error output go to files in a `mktemp -d` scratch directory, and the script prints a
    header `<marker> <index> <code> <out bytes> <err bytes>` and then exactly those bytes. Output is
    counted, never searched, so nothing a command prints can pass for a header; `<marker> begin` and
    `<marker> end` lines, with a random marker per script, find the start past any banner and catch a
    cut-off run. Review with the user.
29. **The transport** is `run(script, input bytes) -> Ran(ending, stdout bytes, stderr bytes)` and
    `close()`; a script that ran and failed is a `Ran`, and only not reaching the host is an error.
    The script is run by `/bin/sh`, never the login shell, which may not be POSIX. Review with the
    user.
30. **Distributions**: `rocky`, `almalinux` and `centos` are `Rhel` by major version; Alpine's
    version is its release branch (`3.20` from `3.20.3`); Ubuntu keeps `24.04`. A Debian or Ubuntu
    without `VERSION_ID` (testing, unstable) and a Linux without `os-release` are refused with a
    message; any other `ID` is `Other(id)`, and FreeBSD without `os-release` is `Other("freebsd")`.
    Review with the user.
31. **`init` is the init system running**, not the one installed: `/run/systemd/system` for systemd,
    `/run/openrc` for OpenRC, launchd on Darwin, otherwise `NoInit`, so a container started without
    an init is `NoInit`. Fact fixtures are checked against the same variant names. Review with the
    user.
32. **`Facts` and `readFacts` live in the `facts` module**, beside the script and its parser, and the
    evaluator imports them. `fettle facts` without `--local` is refused until the ssh transport
    exists. Review with the user.
33. **A provider** is a trait per kind: `probes` (commands, run in the batch), `delta` (what the
    probe found against what is declared: `InSync`, `Create`, `Modify` with field changes, `Remove`,
    the plan line's text, and the current and declared text where a diff is shown), `steps` (scripts
    with their standard input) and `action`. Verify is the probe and the delta again. The engine
    takes a lookup from kind to provider, so later kinds slot in, and a kind with no provider is a
    resource that cannot be planned, not a failed run. Review with the user.
34. **One round trip plans a host**: the pending record is read as the first command of the batch
    probe. Apply re-probes a resource just before changing it only once something on the host has
    changed in this run, so an apply with nothing to do costs no more round trips. Review with the
    user.
35. **Files**: the probe reads type, mode, owner and group with GNU `stat -c` falling back to BSD
    `stat -f`, and the hash with whichever of `sha256sum`, `shasum -a 256` and `openssl dgst` the
    host has, chosen by the probe itself rather than from facts; a symlink's target travels in
    hexadecimal. A write is `mktemp` beside the target, content on standard input, `chown`, `chmod`,
    `validate`, `mv -f`. A mode not declared keeps the replaced file's, else 0644 (directories 0755);
    an owner not declared keeps the replaced file's when the login is root. A change of only mode or
    owner is made in place. A file with neither `content` nor `source` manages its attributes only
    and is created empty. A file replaces a symlink at its path; a directory or special file there
    is an error. Review with the user.
36. **`validate` names the staged file as `%s`** (anywhere in a word, or in shell text, where it is
    passed as `"$1"`), and one without `%s` cannot be planned, as with Ansible; it takes no standard
    input. Review with the user.
37. **A symlink is set with `ln -sfn`**, which is not atomic but is the portable way to replace a
    link to a directory; it replaces a regular file, refuses a directory. Removal (`present = false`)
    is `rm -f` for a file or symlink and `rmdir` for a directory, so a directory that is not empty
    fails rather than being emptied; `directory.purge` cannot be planned yet. Review with the user.
38. **The plan's lines**: a resource's text starts at column 48 past its mark (two spaces after a
    longer name); a title that is empty or holds a control character is shown quoted. A new file shows
    `N lines` for text under 256 KiB, its size otherwise, `(secret)` for a secret; a changed one a
    line diff with no context lines (as 2.7 prints it), or `content changed (a -> b)` past 256 KiB or
    for binary content, or `content: (secret) changed`. A resource that cannot be planned is an `x`
    line, and makes `plan` exit 1. Review with the user.
39. **Pending actions run where their resource stands in the order**, after its sources and before
    what depends on it, together with any trigger of this run so the action runs once; a run with
    pending actions still begins with them in the plan. The record is JSON lines of kind, title and
    action; one whose resource is no longer declared is shown, dropped and cleared. A change whose
    steps fail leaves its actions pending, since it may have changed part of the file. A failed
    action fails its resource, so its dependents are skipped. Review with the user.
40. **Secrets are read when a run needs them**, not at evaluation: a `SecretV` keeps its source
    (`env NAME`, `file PATH`, `command TEXT`, `vault FILE NAME`), or for `literal` and `concat` the
    values it is made of. `secret.command` drops one final line end; `secret.file` expands `~/`.
    A step that carries a secret never shows its error output, and no secret's hash is put in a
    probe. Review with the user.
41. **`plan --local` and `apply --local`** apply to this machine the program of the inventory host
    `--host` names, or of the inventory's only host. `apply` away from a terminal without `--yes`
    refuses rather than proceeding; `apply` exits 0 when everything applied and 1 when anything
    failed. Each changed, failed or skipped resource and each action prints a progress line
    `host  changed  kind title` as it ends. Review with the user.
42. **Account tools are chosen by the probe, not by facts**: `useradd` on the `PATH` or in
    `/usr/sbin` or `/sbin` means the shadow utilities (Debian, Ubuntu, the RHEL family, and Alpine
    with `shadow` installed), otherwise busybox's `adduser`/`addgroup`/`deluser`/`delgroup`, as decision
    35 chose the hash tool. busybox has no `usermod` or `groupmod`, so on it a change of a user's
    `uid`, `group`, `shell` or `home`, or of a group's `gid`, cannot be planned and names the
    `shadow` package; groups are joined and left with `addgroup`/`delgroup`. Entries come from
    `getent`, else `awk` over `/etc/passwd` and `/etc/group`; groups from `id -Gn`. Review with the user.
43. **A user's fields**: names are 1–32 ASCII characters, a letter or `_` first, then letters,
    digits, `_ . -`, with an optional final `$`. `groups` is exclusive and compared as a set, the
    primary group left out of both sides. `system` and a group's `system` act only at creation; a
    new user gets a home directory (`useradd -m`) unless it is a system user declaring neither a
    `home` nor keys. A changed `home` is `usermod -d` without moving the files. Removal is
    `userdel`/`deluser` and never removes the home directory. Review with the user.
44. **`authorizedKeys`** is exclusive and compared as a set of lines (order, repeats, blank lines and
    a CRLF make no difference); `[]` with no file is in sync. The file is written staged beside
    itself in `~/.ssh` (0700) at 0600, both owned by the user and its primary group; a `~/.ssh`
    that is a symlink is refused, not written through. Review with the user.
45. **`password`** is a crypt(3) hash (`$…`, or a locked `!…`/`*`), refused otherwise, so a plain
    password is never set by mistake. The probe prints the SHA-256 of the hash in `/etc/shadow`,
    never the hash, and the comparison is against the SHA-256 of the declared one; it is set by
    `chpasswd -e` with `name:hash` on standard input, never in an argument. An unreadable
    `/etc/shadow` makes a declared password unplannable. Review with the user.
46. **A command runs when every guard it has says so** (`creates` absent, `unless` failing, `onlyIf`
    succeeding); with no guard it runs every time when `always`, otherwise only as its `run` action.
    `always` beside a guard changes nothing. A guard is run in the batch probe with no standard
    input and its output ignored; status 126 or 127 (it could not be run) makes the command
    unplannable rather than read as an answer. A command to run is the operation `Run`, marked `!`
    (always) or `>` (guards), counted among the plan's actions, and not probed again after it
    runs: its exit status is its outcome. The `run` action checks the guards first and exits 0
    when they say no, so a command its own guards just ran is not run again by a trigger. `run` is
    required (`E0245`, the code for any required field). Review with the user.
47. **`as` runs a command, and its guards, through `su -s /bin/sh <user> -c <line>`**, which needs a
    root login (anything else cannot be planned until `become` exists). Review with the user.
48. **`download`** is titled by its path, with `url` (`https`, `http`, `ftp` or `file`, one line) and
    `sha256` (64 hex digits, any case) required, and `owner`, `group`, `mode` as a file's (mode
    0644 when not declared and nothing is replaced). The probe is the file's plus which of `curl`
    and `wget` the host has; the fetch goes to `mktemp` beside the target, is hashed, and a mismatch
    exits before the move, so the target is untouched. A file that matches needs no fetcher.
    Review with the user.
49. **A field may be named `group`** although `group` is the inventory's word, as a resource's kind
    may (decision 23); `user`'s `group = "staff"` had been a syntax error. Review with the user.
50. **Probes are shared, and resources of a batching kind apply together.** A probe command that
    another resource's probe already runs runs once and both read its output: every `package` of a
    host probes all of the host's packages in one command. Within an apply, a probe is answered from
    the last run of the same commands until a step runs. A provider that batches (`package`,
    `aptRepository`) applies the resources of its kind that stand next to each other in the order,
    with no edge into one from another or from a resource that failed, with one set of steps; each is
    still verified, reported and fires its triggers on its own, and the triggers of all of them are
    recorded as pending before the steps run. Providers see the host's facts and graph, the
    resources changed so far in the run, and marks such as "the index was refreshed" through the
    `Context`. Review with the user.
51. **The package index is refreshed at most once a run**, by the first step that installs or
    upgrades something when the index is older than the smallest `refresh` of those packages (one
    hour by default) or of unknown age: `apt-get update` (age from
    `/var/lib/apt/periodic/update-success-stamp`, which apt's own hook touches, else
    `/var/lib/apt/lists`), `apk update` (the newest `/var/cache/apk/APKINDEX.*`). dnf keeps its
    metadata fresh itself, so it is never refreshed and `refresh` does nothing there. `latest` is the
    candidate in the host's index; a `latest` package that is current in an index older than
    `refresh` plans as a change (`2.8.4; refresh the index (older than 1h) for a newer version`), so
    `latest` keeps looking without the plan inventing a version. An index already refreshed in the
    run is taken as it stands. Review with the user.
52. **Package commands.** apt: `dpkg-query -W -f '${Package}=${db:Status-Status} ${Version}'` and
    `apt-cache policy` (under `LC_ALL=C`) probe; one `DEBIAN_FRONTEND=noninteractive apt-get install
    -y --no-install-recommends -o Dpkg::Options::=--force-confold` installs and upgrades (with
    `--allow-downgrades` when an installed package is pinned to an exact version, `name=version`);
    `apt-get remove` removes (not `purge`: configuration stays, as `config-files` reads as not
    installed). dnf: `rpm -q --qf` and `dnf repoquery --latest-limit 1` probe; `dnf install -y`
    (`name-version`) and `dnf upgrade -y` for `latest`, `dnf remove -y`; a declared version matches
    the installed one with or without its release. apk: apk's database `/lib/apk/db/installed` and
    `apk version -l '<'` probe (a newer version is keyed by the installed one, so no version
    comparison is done in Fettle); `apk add` (`name=version`, which pins it in `world`), `apk add -u`
    for `latest`, `apk del`. Removals run before installs. Package names are ASCII letters, digits and
    `. + _ -`, not starting with a symbol; versions add `~ :`. The manager comes from the `Distro`
    fact; `provider =` is not read yet. Review with the user.
53. **`aptRepository`'s fields** are `uris`, `suites`, `components`, `architectures` (lists of
    strings), `key` (an `https://`, `http://` or `file:///` URL) and `keySha256` (64 lowercase hex
    digits), and `present`. Its file is `/etc/apt/sources.list.d/<name>.sources` in deb822 form
    (`Types: deb`, then the fields given, then `Signed-By:`); a repository with no `components` names
    each suite as an exact path ending in `/`. The key is fetched on the host with `curl -fsSL`, else
    `wget`, to a temporary file in `/etc/apt/keyrings`, and refused unless its SHA-256 is the pin,
    before anything is written. It is **kept as fetched, not dearmored**: `<name>.asc` when it starts
    with `-----BEGIN PGP PUBLIC KEY BLOCK-----`, `<name>.gpg` otherwise. apt reads an armored key
    named `.asc` in `Signed-By` since 1.4, so Debian 12 (apt 2.6) and Ubuntu 24.04 (apt 2.7) need no
    `gpg`, which minimal images lack; Docker's own instructions for both write `docker.asc` the same
    way. A key already matching its pin is not fetched again. The repositories written in one step
    run `apt-get update` once after; a removed one (`rm -f` of its file and keys) does not refresh.
    Every `package` is ordered after every `aptRepository` (a known relationship, shown as "packages
    come after apt repositories"). Review with the user.
54. **Services.** systemd's probe reads `LoadState`, `is-enabled`, `is-active` and
    `NeedDaemonReload`. `enabled`, `enabled-runtime`, `alias`, `linked` and `linked-runtime` are
    enabled; `static`, `indirect`, `generated` and `transient` units are as declared whichever way
    (systemd decides them); a masked unit declared running or enabled cannot be planned. A unit not
    installed yet (its package comes in the same run) plans as `start, enable (not installed yet)`.
    Steps are `systemctl enable --now` or `disable --now` when both change, one command each
    otherwise, after `systemctl daemon-reload` when systemd reports the unit changed on disk or a
    `file` of the unit (`/etc/systemd/system/<unit>` or a drop-in under `<unit>.d/`) changed in this
    run since the last reload; an action reloads first under the same rule. On OpenRC, enabled means
    in the `default` runlevel (`rc-update add|del <name> default`), running is `rc-service <name>
    status`, and existence `rc-service --exists`. A host whose `init` is `NoInit` or `Launchd` cannot
    plan a service, and says so. Actions run as named (`systemctl reload`, `rc-service <name>
    reload`), so a reload of a stopped service fails. Review with the user.
55. **A restart does what a reload or a start would**: when one run asks for a restart and a reload
    of one service (from triggers or the pending record), the plan shows one restart with the
    sources of both, the apply runs it once, and it clears both from the pending record. A provider
    says which of its actions subsume which. Review with the user.
56. **`staged` stands for the staged file wherever it lands in `validate`**: the evaluator makes it
    the path `${staged}`, which the `file` provider reads as `%s` (decision 36) as an argument,
    inside a word (`--config=${staged}`) and in shell text, quoted or not. Until now only a literal
    `%s` was read, so example 2.2's `cmd("visudo", "-cf", staged)` could not be planned. Review with
    the user.
