# Learning the Nix language

This guide teaches the Nix language from zero, one small step at a time, until you can read every file in `nixos/modules/` and fix it when it breaks. Every step has something to type into `nix repl`, a pointer to where the same thing appears in your own config, and a short question to check yourself.

How it fits next to the other docs here:

- **This guide:** the language itself. What `{ pkgs, ... }:`, `let ... in`, `with`, `inherit`, `//` and `${ }` mean, and how to debug Nix code.
- **The x1 handbook** ([x1-nixos-handbook.md](x1-nixos-handbook.md)): NixOS as a whole. Chapter 05 is a compact reference of the same language, chapter 06 explains the module system in depth, and chapter 09 covers debugging builds, services and boot.
- **The flake guide** ([dendritic-flake-guide.md](dendritic-flake-guide.md)): how the files in `modules/` turn into a system, and how to add features and machines.

Every REPL result in this guide was produced by Nix 2.34.9, the version on the x1, against the nixpkgs 26.05 your system is built from. Error messages are real output too. Most of them come from copies of your own modules that were broken on purpose. Version numbers and store hashes change when you update `flake.lock`, so yours may differ after an update.

- [The short version (ELI5)](#the-short-version-eli5)
- [The longer version (ELI12)](#the-longer-version-eli12)
- [Words this guide uses](#words-this-guide-uses)
- [Set up your playground](#set-up-your-playground)
- [Step by step](#step-by-step)
  - [Step 1: Everything is an expression](#step-1-everything-is-an-expression)
  - [Step 2: Strings](#step-2-strings)
  - [Step 3: Lists](#step-3-lists)
  - [Step 4: Attribute sets](#step-4-attribute-sets)
  - [Step 5: Naming things with let and inherit](#step-5-naming-things-with-let-and-inherit)
  - [Step 6: with](#step-6-with)
  - [Step 7: Functions](#step-7-functions)
  - [Step 8: Calling functions](#step-8-calling-functions)
  - [Step 9: Conditions and comparisons](#step-9-conditions-and-comparisons)
  - [Step 10: Laziness](#step-10-laziness)
  - [Step 11: Paths and files](#step-11-paths-and-files)
  - [Step 12: builtins, lib and pkgs](#step-12-builtins-lib-and-pkgs)
  - [Step 13: Read a whole file](#step-13-read-a-whole-file)
  - [Step 14: Where the language stops and the module system starts](#step-14-where-the-language-stops-and-the-module-system-starts)
- [Debugging Nix code](#debugging-nix-code)
- [Practice](#practice)
- [Cheat sheet](#cheat-sheet)
- [Learning path](#learning-path)
- [Sources](#sources)

## The short version (ELI5)

Think of a spreadsheet.

Each cell holds either a plain value, like `55`, or a formula, like `= B2 + 1`. A formula can use other cells. You never "run" a spreadsheet. You fill in cells, and the spreadsheet works out the answers. It also only works out the cells somebody is looking at.

Nix is a spreadsheet for describing a computer.

- Your `.nix` files are the cells. Some hold plain values (`time.timeZone = "Europe/Warsaw";`), some hold formulas (`"${pkgs.slurp}/bin/slurp"`).
- Nothing in a cell changes after you write it. There is no "set x to 5, later set x to 6". There is only "x is 5".
- The final answer is one big box of labelled values: every setting of your x1. NixOS reads that box and builds the system from it.
- Nix only works out the values that the build actually needs. That is why a mistake in a corner nobody uses can stay hidden until something starts using it.

```
   your .nix files               Nix works it out                 one big answer
  +----------------+          +-------------------+          +-------------------------+
  | audio.nix      |          | formulas use each |          | networking.hostName =   |
  | printing.nix   | -------> | other, values are | -------> |   "x1"                  |
  | desktop.nix    |          | never changed     |          | services.pipewire = ... |
  | ...            |          |                   |          | ... every setting       |
  +----------------+          +-------------------+          +-----------+-------------+
                                                                         |
                                                              NixOS builds the system
```

## The longer version (ELI12)

Most languages you know, like bash or Python, are lists of instructions: do this, then that, then change this variable. Nix is different. A Nix file does not do anything. It **describes a value**, the way `2 + 3` describes `5`.

Five facts explain almost everything you will see.

1. **Everything is an expression.** A whole `.nix` file is one expression that has one value. `modules/audio.nix` is one big attribute set. There are no statements and no `return`.
2. **Attribute sets are the main data structure.** An attribute set is a map from names to values, written `{ name = value; }`. Your entire NixOS configuration is one huge attribute set.
3. **Functions take exactly one argument.** `x: x + 1` is a function. `{ pkgs, ... }: { ... }` is a function that takes one attribute set and picks `pkgs` out of it. Most of your files are functions of this kind.
4. **Nix is lazy.** A value is computed only when something needs it. This is what lets NixOS modules read each other's settings, and it is why error messages point at the place a value was *used*.
5. **Nix is pure.** When Nix evaluates your flake, the same inputs always give the same result. The code cannot read the clock, the network or an untracked file. That is what makes a rebuild reproducible. (`nix repl` is relaxed by default, which is why `<nixpkgs>` works there. `nix eval --expr` is strict: it refuses `<nixpkgs>` with `cannot look up '<nixpkgs/lib>' in pure evaluation mode` unless you add `--impure`.)

On top of the language sit two more layers. Most confusion comes from mixing them up, so it helps to know which one you are looking at.

```
  +-----------------------------------------------------------------------------+
  | 3. module systems (written in Nix, using lib)                               |
  |    NixOS:       services.tlp.enable, imports, options, merging, mkForce     |
  |    flake-parts: flake.modules.nixos.audio, perSystem, packages              |
  +-----------------------------------------------------------------------------+
  | 2. nixpkgs (a huge library written in Nix)                                  |
  |    lib:  lib.mkIf, lib.optionals, lib.getExe ...   (helper functions)       |
  |    pkgs: pkgs.git, pkgs.callPackage, pkgs.fetchurl ... (packages, builders) |
  +-----------------------------------------------------------------------------+
  | 1. the Nix language (this guide)                                            |
  |    values, { }, [ ], let, with, inherit, functions, //, if, import          |
  +-----------------------------------------------------------------------------+
```

| You see | Layer | Where to read about it |
|----|----|----|
| `let x = 1; in`, `with pkgs;`, `inherit system;`, `x: ...`, `//`, `${ }` | language | this guide, steps 1 to 12 |
| `lib.mkForce`, `lib.getExe`, `pkgs.callPackage`, `pkgs.writeShellScript` | nixpkgs library | step 12, then [noogle.dev](https://noogle.dev/) |
| `services.pipewire.enable`, `imports = [ ... ]`, "option does not exist" | NixOS module system | step 14, then handbook chapter 06 |
| `flake.modules.nixos.audio`, `perSystem`, `self.packages` | flake-parts | the flake guide |

The language part is small. You can learn all of it in a weekend. The library and the module system are big, but you only ever look things up in them.

## Words this guide uses

| Word | Meaning |
|----|----|
| expression | Any piece of Nix code that has a value: `1 + 2`, `"hi"`, a whole file. |
| evaluate | Work out the value of an expression. `nix eval` and `nix repl` evaluate. |
| attribute set (attrset, set) | `{ a = 1; b = "x"; }`. A map from names to values. The names are called attributes. |
| attribute path | Names joined by dots: `services.pipewire.enable`. |
| list | `[ 1 2 "x" ]`. Elements are separated by spaces, not commas. |
| function, lambda | `x: x + 1`. Takes one argument and returns a value. |
| argument pattern | `{ pkgs, lib, ... }:`. A function argument that must be an attrset, with the listed names pulled out. |
| binding | A name and its value: `x = 1;` inside `let` or `{ }`. |
| scope | The names you can use at a given point in the code. |
| thunk | A value Nix has not computed yet. The REPL shows it as `«thunk»`. |
| derivation | A build recipe. Every package, like `pkgs.git`, is an attrset that describes a derivation. |
| store path | Where a built thing lives: `/nix/store/<hash>-<name>`. |
| `builtins` | The functions built into Nix itself, like `builtins.map`. |
| `lib` | The helper library from nixpkgs, like `lib.mkIf`. |
| `pkgs` | The nixpkgs package set: about 120,000 packages plus build helpers. |
| module | A file or attrset the NixOS (or flake-parts) module system merges with other modules. Not a language feature. |

## Set up your playground

You learn this language by typing it. Keep a terminal open next to this guide.

### The REPL

```sh
cd ~
nix repl
```

`nix repl` reads one expression per line and prints its value. Start it from your home directory, so that the path examples below print the same paths. Useful commands inside it:

| Command | What it does |
|----|----|
| `:?` | list every REPL command |
| `x = 5` | bind a name for the rest of the session (only the REPL allows this) |
| `:t expr` | describe the type of a value |
| `:p expr` | print a value fully, nested parts included |
| `:doc fn` | show the documentation of a function |
| `:lf <flake>` | load a flake's outputs into scope |
| `:r` | reload files after you edit them |
| `:q` | quit |

Try it:

```
nix-repl> 1 + 2
3
nix-repl> x = 5
nix-repl> x * 2
10
nix-repl> :t x
an integer
```

A long expression can span several lines in the REPL. It keeps reading until the expression is complete. For anything longer than a line, a file is easier.

### A scratch file

Write a file, for example `/tmp/play.nix`:

```nix
let
  name = "x1";
  script = ''
    echo "hello from ${name}"
    echo "$HOME stays a shell variable"
    echo "''${HOME} is escaped too"
  '';
in
{
  inherit name script;
  greeting = "hi " + name;
}
```

Evaluate it in three ways:

```sh
$ nix eval --file /tmp/play.nix
{ greeting = "hi x1"; name = "x1"; script = "echo \"hello from x1\"\necho \"$HOME stays a shell variable\"\necho \"\${HOME} is escaped too\"\n"; }

$ nix eval --raw --file /tmp/play.nix script
echo "hello from x1"
echo "$HOME stays a shell variable"
echo "${HOME} is escaped too"

$ nix eval --json --file /tmp/play.nix
{"greeting":"hi x1","name":"x1","script":"echo \"hello from x1\"\necho \"$HOME stays a shell variable\"\necho \"${HOME} is escaped too\"\n"}
```

`--raw` prints a string as it is, without quotes and escapes. `--json` is handy with `jq`. The attribute name after the file (`script`) selects one attribute.

### Checking syntax only

`nix-instantiate --parse` reads a file without evaluating it. It prints the parsed expression or the syntax error. The output also shows how Nix understood your code: `inherit` stays as written, and string interpolation becomes plain `+`.

```sh
$ nix-instantiate --parse /tmp/play.nix
(let name = "x1"; script = ("echo \"hello from " + name + "\"\necho \"$HOME stays a shell variable\"\necho \"" + "$" + "{HOME} is escaped too\"\n"); in { inherit name script; greeting = ("hi " + name); })
```

### lib, pkgs and your own flake

Steps 1 to 11 need nothing extra. Step 12 and later use nixpkgs. Load it into the REPL like this:

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> pkgs = import <nixpkgs> { }
nix-repl> pkgs.hello.name
"hello-2.12.3"
```

On the x1, `<nixpkgs>` is the nixpkgs your running system was built from: NixOS sets `NIX_PATH=nixpkgs=flake:nixpkgs`, and the `nixpkgs` flake registry entry points at the system's nixpkgs.

To explore your real configuration, load the flake:

```
nix-repl> :lf /home/mgajewskik/.local/share/chezmoi/nixos
Added 18 variables.
_type, apps, checks, devShells, formatter, inputs, lastModified, lastModifiedDate, legacyPackages, modules, narHash, nixosConfigurations, nixosModules, outPath, outputs, overlays, packages, sourceInfo
nix-repl> builtins.attrNames modules.nixos
[
  "agentbox"
  "apps"
  "audio"
  "boot"
  "cli"
  "desktop"
  "keys"
  "laptop"
  "locale"
  "networking"
  "nix"
  "openssh"
  "podman"
  "printing"
  "syncthing"
  "tools"
  "user"
  "x1"
]
nix-repl> nixosConfigurations.x1.config.networking.hostName
"x1"
```

Use `:r` to reload after editing a file. Nix reads a flake in a git repo only through git, so a new file must be `git add`ed before the flake can see it.

## Step by step

Take the steps in order. Each one builds on the ones before it. Every code block works in a fresh `nix repl`: a block that needs `lib` or `pkgs` loads them in its first lines.

### Step 1: Everything is an expression

The simplest expressions are plain values.

```
nix-repl> 42
42
nix-repl> 2 + 3 * 4
14
nix-repl> 10 / 3
3
nix-repl> 10 / 3.0
3.33333
nix-repl> true
true
nix-repl> null
null
nix-repl> builtins.typeOf 1.5
"float"
```

Integer division stays an integer. `null` means "no value" and appears in configs as "unset", for example `environment.PATH = lib.mkForce null;` in `modules/desktop.nix`.

Two traps come from the way Nix reads characters:

```
nix-repl> 1/2
/home/mgajewskik/1/2
nix-repl> let x = 3; in x-1
error: undefined variable 'x-1'
nix-repl> let x = 3; in x - 1
2
```

`1/2` without spaces is a **path** (step 11), not a division. A hyphen is allowed inside names, so `x-1` is one name, and names like `agent-browser` and `cups-brother-dcpt720dw` are legal. Put spaces around operators.

**In your config:** `55` in `START_CHARGE_THRESH_BAT0 = 55;` (`modules/laptop.nix`), `true` in every `enable = true;`, and `"26.05"` in `system.stateVersion = "26.05";`.

**Check yourself:** what is `7 / 2`, and what is `7 / 2.0`?

<details><summary>Answer</summary>

```
nix-repl> 7 / 2
3
nix-repl> 7 / 2.0
3.5
```

</details>

### Step 2: Strings

A string is written in double quotes. `${ }` inside a string inserts the value of an expression. That is called **interpolation**.

```
nix-repl> name = "x1"
nix-repl> "hello ${name}"
"hello x1"
nix-repl> "hi " + name
"hi x1"
nix-repl> "n=${5}"
error: cannot coerce an integer to a string: 5
nix-repl> "n=${toString 5}"
"n=5"
nix-repl> toString true
"1"
nix-repl> toString false
""
```

Only strings, paths and packages can be interpolated. Numbers need `toString`.

**Multi-line strings** use two single quotes, `''`. Nix removes the indentation the lines share, which is why scripts and config snippets can be indented with the rest of the code. Inside them:

- `${expr}` is still Nix interpolation.
- `$HOME` or `$(cmd)` without braces is left alone, so shell code just works.
- `''${HOME}` writes a literal `${HOME}` for the shell.

The scratch file in the playground section shows all three. In the REPL, `:p` prints a string as it is, with real newlines:

```
nix-repl> "a\nb"
"a\nb"
nix-repl> :p "a\nb"
a
b
```

**In your config:**

- `modules/pkgs/crib.nix` builds a URL: `url = "https://github.com/fgrehm/crib/releases/download/v${version}/crib_linux_amd64.tar.gz";`.
- `modules/desktop.nix` mixes Nix and shell in one multi-line string:

  ```nix
  pkgs.writeShellScript "soteria-in-display-session" ''
    XDG_SESSION_ID=$(loginctl show-user "$UID" --property=Display --value) exec ${lib.getExe pkgs.soteria}
  ''
  ```

  `$(...)` and `"$UID"` are shell, left untouched. `${lib.getExe pkgs.soteria}` is Nix and becomes the full store path of the soteria binary.
- `modules/keys.nix` puts a whole JavaScript polkit rule in a `''` string. It contains no `${`, so nothing in it is interpolated.

**Check yourself:** in `"${pkgs.slurp}/bin/slurp -f 'Monitor: %o' -or"` from `desktop.nix`, which part does Nix replace?

<details><summary>Answer</summary>

Only `${pkgs.slurp}`. It becomes the store path of the slurp package, for example `/nix/store/<hash>-slurp-1.5.0`, and the rest of the string stays as written. Step 12 shows why a package turns into a path.

</details>

### Step 3: Lists

A list is written in square brackets with elements separated by **spaces**. No commas.

```
nix-repl> [ 1 "two" true ]
[
  1
  "two"
  true
]
nix-repl> [ 1, 2 ]
error: syntax error, unexpected ','
nix-repl> [ "a" ] ++ [ "b" ]
[
  "a"
  "b"
]
nix-repl> builtins.length [ 1 2 3 ]
3
nix-repl> builtins.elemAt [ "a" "b" ] 1
"b"
```

`++` joins two lists. Elements can be of different types.

**In your config:** every package list. `environment.systemPackages = with pkgs; [ ghostty kitty ... ];` in `modules/apps.nix` is a list of packages. `modules/hosts/x1/configuration.nix` joins two lists with `++`:

```nix
imports = [
  inputs.disko.nixosModules.disko
  inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme
]
++ (with self.modules.nixos; [
  nix
  boot
  ...
]);
```

**Check yourself:** what is `[ 1 2 ] ++ [ ]`?

<details><summary>Answer</summary>

```
nix-repl> [ 1 2 ] ++ [ ]
[
  1
  2
]
```

</details>

### Step 4: Attribute sets

An attribute set maps names to values. Every binding ends with `;`.

```
nix-repl> s = { a = 1; b = "x"; }
nix-repl> s.a
1
nix-repl> s.c
error: attribute 'c' missing
nix-repl> s.c or "fallback"
"fallback"
nix-repl> s ? b
true
nix-repl> builtins.attrNames s
[
  "a"
  "b"
]
```

`.` selects an attribute. `or` gives a default for a missing one. `?` tests whether it exists.

**Dotted names nest.** These two are the same value:

```
nix-repl> :p { a.b = 1; a.c = 2; }
{
  a = {
    b = 1;
    c = 2;
  };
}
nix-repl> :p { a = { b = 1; c = 2; }; }
{
  a = {
    b = 1;
    c = 2;
  };
}
```

Without `:p`, the REPL prints nested sets as `{ ... }` and only shows the top level.

**Quoted names** are needed when a name contains `.` or `/`, or starts with a digit. **Dynamic names** use `${ }`:

```
nix-repl> { "20-wired".x = 1; }."20-wired".x
1
nix-repl> system = "x86_64-linux"
nix-repl> packages = { x86_64-linux = { crib = "crib-0.10.0"; }; }
nix-repl> packages.${system}.crib
"crib-0.10.0"
```

**Updating:** `//` returns a new set with the right side's attributes on top. It is shallow: a nested set on the right replaces the whole nested set on the left.

```
nix-repl> { a = 1; b = 2; } // { b = 3; }
{
  a = 1;
  b = 3;
}
nix-repl> :p { a.x = 1; } // { a.y = 2; }
{
  a = { y = 2; };
}
```

`a.x` is gone. `lib.recursiveUpdate` (step 12) merges nested sets deeply, but you will rarely need it, because the module system merges deeply for you (step 14).

An attribute can be defined only once in the same set:

```
nix-repl> { a = 1; a = 2; }
error: attribute 'a' already defined at «string»:1:3
```

**In your config:**

- `modules/networking.nix` uses quoted names and dotted names side by side:

  ```nix
  systemd.network.networks = {
    "20-wired" = {
      matchConfig = {
        Type = "ether";
        Kind = "!*";
      };
      linkConfig.RequiredForOnline = "routable";
      ...
  ```

  `linkConfig.RequiredForOnline = "routable";` is short for `linkConfig = { RequiredForOnline = "routable"; };`.
- `boot.kernel.sysctl = { "net.ipv4.conf.all.arp_ignore" = 1; ... }` quotes the name because the sysctl key itself contains dots. Without quotes, Nix would build nested sets `net.ipv4.conf...`.
- `self.packages.${pkgs.stdenv.hostPlatform.system}` in `modules/apps.nix` is a dynamic name: it selects `x86_64-linux`.
- `appimageTools.defaultFhsEnvArgs // { pname = "helium"; ... }` in `modules/pkgs/helium.nix` takes nixpkgs' default arguments and overrides a few.

**Check yourself:** what is the difference between `{ "a.b" = 1; }` and `{ a.b = 1; }`?

<details><summary>Answer</summary>

```
nix-repl> builtins.attrNames { "a.b" = 1; }
[ "a.b" ]
nix-repl> builtins.attrNames { a.b = 1; }
[ "a" ]
```

The first has one attribute whose name contains a dot. The second has an attribute `a` that holds another set with `b` in it.

</details>

### Step 5: Naming things with let and inherit

`let ... in` gives names to values, then uses them in one expression. Bindings inside `let` can use each other, in any order.

```
nix-repl> let x = 1; y = x + 1; in y
2
nix-repl> let x = 1 in x
error: syntax error, unexpected 'in', expecting ';'
```

Plain attribute sets cannot refer to their own attributes. `rec` allows it, but `let` is the usual way:

```
nix-repl> { a = 1; b = a + 1; }
error: undefined variable 'a'
nix-repl> rec { a = 1; b = a + 1; }
{
  a = 1;
  b = 2;
}
```

`inherit` copies a name from the surrounding scope into a set. `inherit (s) name;` copies it from the set `s`.

```
nix-repl> system = "x86_64-linux"
nix-repl> { inherit system; }
{ system = "x86_64-linux"; }
nix-repl> fakePkgs = { git = "git-2.50"; vim = "vim-9.1"; }
nix-repl> { inherit (fakePkgs) git vim; }
{
  git = "git-2.50";
  vim = "vim-9.1";
}
```

`inherit system;` is exactly `system = system;`. `inherit (fakePkgs) git;` is exactly `git = fakePkgs.git;`.

**In your config:**

- `modules/tools.nix` names a configured package set once and uses it twice:

  ```nix
  let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
    agent-browser = pkgsUnstable.symlinkJoin { ... };
  in
  { packages.tools = pkgsUnstable.buildEnv { ... }; }
  ```

  `inherit system;` passes the `system` this function received as an argument.
- `modules/pkgs/helium.nix` puts `inherit (inputs._meta.helium) version;` in a `let`, then uses `inherit version;` twice below it, so the version tack locked is read once.
- `modules/apps.nix` binds `packages = self.packages.${pkgs.stdenv.hostPlatform.system};` so the list can say `packages.helium` instead of the long path.

**Check yourself:** rewrite `{ name = name; version = version; }` with `inherit`.

<details><summary>Answer</summary>

`{ inherit name version; }`. One `inherit` can list several names.

</details>

### Step 6: with

`with s; expr` makes every attribute of `s` usable as a plain name inside `expr`.

```
nix-repl> fakePkgs = { git = "git-2.50"; vim = "vim-9.1"; }
nix-repl> with fakePkgs; [ git vim ]
[
  "git-2.50"
  "vim-9.1"
]
nix-repl> with fakePkgs; [ git vimm ]
[
  "git-2.50"
  «error: undefined variable 'vimm'»
]
```

A typo inside `with` is reported as `undefined variable`, not as a missing attribute. That is the message you will see for a misspelled package name in a `with pkgs; [ ... ]` list.

**`with` loses to every other name.** A name from `let` or a function argument always wins over the same name from `with`, no matter where the `with` is written:

```
nix-repl> let x = 1; in with { x = 2; }; x
1
nix-repl> with { x = 2; }; let x = 1; in x
1
```

**In your config:**

- `environment.systemPackages = with pkgs; [ ghostty kitty ... ];` in `modules/apps.nix` lets you write `kitty` instead of `pkgs.kitty`.
- `with self.modules.nixos; [ nix boot networking ... ]` in `modules/hosts/x1/configuration.nix` turns feature names into modules.
- In `modules/tools.nix`, the list `with pkgsUnstable; [ mise chezmoi ... agent-browser ... ]` contains `agent-browser`. `pkgsUnstable` has an `agent-browser` too, but the `let` binding in the same file wins, so the list gets the wrapped version from the `let`. That is the rule above, doing real work.

**Check yourself:** in `modules/apps.nix`, the list after `with pkgs;` also contains `packages.helium`. Why does that work, and where does `packages` come from?

<details><summary>Answer</summary>

`packages` is bound in the file's `let`: `packages = self.packages.${pkgs.stdenv.hostPlatform.system};`. `let` names beat `with` names, so even if nixpkgs had something called `packages`, the list would use the local one. `.helium` then selects one package from it.

</details>

### Step 7: Functions

A function is written `argument: body`. It has exactly one argument.

```
nix-repl> inc = x: x + 1
nix-repl> inc 2
3
nix-repl> add = a: b: a + b
nix-repl> add 1 2
3
nix-repl> add 1
«lambda add @ «string»:1:10»
```

A function of "two arguments" is a function that returns another function. `add 1` is a new function still waiting for `b`. This is called currying.

Most Nix functions take **one attribute set** and pull names out of it with an **argument pattern**:

```
nix-repl> f = { a, b ? 5, ... }: a + b
nix-repl> f { a = 1; }
6
nix-repl> f { a = 1; b = 2; c = 9; }
3
nix-repl> ({ a, b }: a + b) { a = 1; }
error: function 'anonymous lambda' called without required argument 'b'
nix-repl> ({ a }: a) { a = 1; b = 2; }
error: function 'anonymous lambda' called with unexpected argument 'b'
nix-repl> (args@{ a, ... }: args) { a = 1; c = 9; }
{
  a = 1;
  c = 9;
}
```

| Pattern piece | Meaning |
|----|----|
| `{ a, b }:` | the argument must have exactly `a` and `b` |
| `b ? 5` | `b` is optional, with a default |
| `...` | other attributes are allowed and ignored |
| `args@{ ... }` | also bind the whole set as `args` |
| `{ a, b, }:` | a trailing comma is fine; nixfmt writes long patterns this way |

Patterns use **commas**. Lists use spaces. Sets use semicolons.

**In your config,** almost every file is a function with a pattern, and many contain a second function inside:

```
{ inputs, self, ... }:          <- outer function: flake-parts calls it with inputs, self, lib, ...
{
  flake.modules.nixos.apps =
    { pkgs, ... }:              <- inner function: NixOS calls it with config, lib, pkgs, ...
    {
      environment.systemPackages = [ ... ];
    };
}
```

- The `...` is required. Both callers pass more names than you list. Without it you get `called with unexpected argument`.
- The inner function can use `inputs` and `self` from the outer one, because it is written inside it. A function sees every name that was in scope where it was written. This is how `inputs` reaches NixOS code in your config.

**Check yourself:** `modules/printing.nix` starts its NixOS part with `{ pkgs, ... }:`. What goes wrong if you write `pkgs:` instead?

<details><summary>Answer</summary>

`pkgs:` is a plain function argument, not a pattern. The whole attrset NixOS passes in gets the name `pkgs`, so `pkgs.cups-brother-dcpt720dw` looks for a package directly in that attrset. Breaking a copy of your config this way gave:

```
error: attribute 'cups-brother-dcpt720dw' missing
       at /nix/store/<hash>-source/modules/printing.nix:7:21:
```

That attrset does not even contain `pkgs`. Asking a module with a plain argument for its names, on your real config, returned `[ "_class" "_prefix" "config" "lib" "modulesPath" "options" "specialArgs" ]`. NixOS reads the names in a module's pattern and passes `pkgs` only when the pattern asks for it. That is why the pattern matters, not only the name.

</details>

### Step 8: Calling functions

Calling a function is just a space: `f x`. There are no parentheses around arguments and no commas between them.

```
nix-repl> builtins.add 1 2
3
nix-repl> builtins.length [ (builtins.add 1 2) ]
1
nix-repl> builtins.length [ builtins.add 1 2 ]
3
nix-repl> [ builtins.add 1 2 ]
[
  «primop add»
  1
  2
]
```

**Calls inside a list need parentheses.** Inside `[ ]`, a space separates elements, so `[ builtins.add 1 2 ]` is a list of three things. `[ (builtins.add 1 2) ]` is a list with one result.

Function calls bind tighter than any operator, and `.` binds tighter than a call:

```
nix-repl> inc = x: x + 1
nix-repl> inc 2 * 10
30
nix-repl> inc (2 * 10)
21
```

When unsure, add parentheses.

**`import`** is a function too. `import ./file.nix` reads a file and returns its value. If that value is a function, you can call it right away:

```
nix-repl> builtins.typeOf (import <nixpkgs>)
"lambda"
nix-repl> builtins.typeOf (import <nixpkgs> { })
"set"
```

nixpkgs is a function that takes settings and returns the package set.

**In your config:**

- `flake.nix`: `outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);`. `outputs` is a function of `inputs`. `mkFlake` is called with two arguments: the set `{ inherit inputs; }` and the result of calling `inputs.import-tree ./modules`, which needs parentheses so that it counts as one argument.
- `modules/tools.nix`: `import inputs.nixpkgs-unstable { inherit system; config.allowUnfree = true; }` imports nixpkgs-unstable, then calls it with settings, exactly like `import <nixpkgs> { }` above.
- `modules/pkgs/crib.nix`: `pkgs.callPackage ( { stdenvNoCC, fetchurl }: ... ) { }`. `callPackage` reads the names in the function's pattern, finds each of them in `pkgs`, and calls the function with them. The trailing `{ }` is the second argument, for overrides.

```
nix-repl> builtins.functionArgs ({ stdenvNoCC, fetchurl, extra ? null }: 1)
{
  extra = true;
  fetchurl = false;
  stdenvNoCC = false;
}
```

`builtins.functionArgs` is how `callPackage` sees the names. `true` marks the ones with a default.

**Check yourself:** what is `map (x: x * 2) [ 1 2 3 ]`, and why does `(x: x * 2)` need parentheses?

<details><summary>Answer</summary>

```
nix-repl> map (x: x * 2) [ 1 2 3 ]
[
  2
  4
  6
]
```

Without parentheses, the function body would run to the end of the line: `x: x * 2 [ 1 2 3 ]` would be one function whose body tries to call `2` with a list.

</details>

### Step 9: Conditions and comparisons

```
nix-repl> if 1 < 2 then "yes" else "no"
"yes"
nix-repl> if 1 then "a" else "b"
error: expected a Boolean but found an integer: 1
nix-repl> 1 == 1.0
true
nix-repl> [ 1 2 ] == [ 1 2 ]
true
nix-repl> true && false || true
true
nix-repl> !true
false
nix-repl> assert 1 == 2; 3
error: an integer with value '1' is not equal to an integer with value '2'
```

- `if` always needs `else`, because it is an expression and must have a value either way.
- Conditions must be real booleans. `1` and `""` are not "truthy".
- `assert cond; expr` returns `expr` when `cond` is true and stops evaluation otherwise.

Your config has no `if` of its own. In NixOS code you will see `lib.mkIf cond { ... }` much more often. That is a module-system helper, not the language's `if` (step 14).

**Check yourself:** what is `if "a" == "a" then 1 else 0`?

<details><summary>Answer</summary>

```
nix-repl> if "a" == "a" then 1 else 0
1
```

</details>

### Step 10: Laziness

Nix computes a value only when something needs it. Until then, the value is a thunk.

```
nix-repl> a = { x = throw "boom"; y = 2; }
nix-repl> a.y
2
nix-repl> a
{
  x = «error: boom»;
  y = 2;
}
nix-repl> let x = x + 1; in x
error: infinite recursion encountered
```

`a.y` works even though `a.x` would fail, because nobody asked for `a.x`. `throw` produces an error only when its value is needed.

This explains three things you will meet:

- **NixOS modules can read each other.** A module can use `config.something` while also helping to define `config`. Nix works out each value only when it is needed, so the pieces fall into place, as long as no value depends on itself.
- **Errors appear where a value is used.** A typo in a package list is reported when the list is finally needed, which can be far from the line you changed. `--show-trace` shows the whole chain.
- **`nix eval` of one option is fast.** `nix eval ...#nixosConfigurations.x1.config.networking.hostName` computes only what the hostname needs, not the whole system.

**Check yourself:** what does `builtins.length [ (throw "a") (throw "b") ]` return?

<details><summary>Answer</summary>

```
nix-repl> builtins.length [ (throw "a") (throw "b") ]
2
```

Counting the elements does not need their values, so neither `throw` runs.

</details>

### Step 11: Paths and files

A path is its own type, written without quotes. A relative path is resolved against the file it is written in (in the REPL, against the current directory).

```
nix-repl> ./foo
/home/mgajewskik/foo
nix-repl> builtins.typeOf ./foo
"path"
nix-repl> ./foo + "/bar"
/home/mgajewskik/foo/bar
nix-repl> builtins.toString ./foo
"/home/mgajewskik/foo"
```

What you can do with a path:

- `import ./file.nix` evaluates another Nix file.
- `builtins.readFile ./file` reads a file as a string.
- `"${./file}"` copies the file into the Nix store and gives you the store path. It fails if the file does not exist.

Paths inside a flake must be inside the flake directory. In a git repo, Nix sees only the files git tracks, so a new file must be `git add`ed first (staging is enough).

**In your config:** `./modules` in `flake.nix` is the only path. import-tree lists every `.nix` file under it. Nothing in `modules/` imports another file by path, which is the point of the dendritic layout (see the flake guide).

**Check yourself:** why does `1/2` evaluate to a path?

<details><summary>Answer</summary>

Any text with a `/` and no spaces that looks like a relative path is read as a path. `1/2` is the path `./1/2`. Write `1 / 2` for division.

</details>

### Step 12: builtins, lib and pkgs

The language has very few keywords. Everything else is a function from one of three places.

| Name | What it is | How you get it |
|----|----|----|
| `builtins` | functions built into Nix | always in scope; a few (`map`, `toString`, `import`, `throw`) work without the `builtins.` prefix |
| `lib` | helpers written in Nix, from nixpkgs | a module argument (`{ lib, ... }:`), or `import <nixpkgs/lib>` in the REPL |
| `pkgs` | packages and build helpers | a NixOS module argument (`{ pkgs, ... }:`), or `import <nixpkgs> { }` |

Load them first:

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> pkgs = import <nixpkgs> { }
nix-repl> builtins.filter (x: x > 1) [ 1 2 3 ]
[
  2
  3
]
nix-repl> lib.optionals true [ "a" ]
[ "a" ]
nix-repl> lib.optionals false [ "a" ]
[ ]
nix-repl> lib.concatStringsSep ", " [ "a" "b" ]
"a, b"
nix-repl> lib.genAttrs [ "a" "b" ] (name: name + "!")
{
  a = "a!";
  b = "b!";
}
nix-repl> :p lib.mapAttrs (name: value: value * 10) { a = 1; b = 2; }
{
  a = 10;
  b = 20;
}
nix-repl> :p lib.recursiveUpdate { a.x = 1; } { a.y = 2; }
{
  a = {
    x = 1;
    y = 2;
  };
}
```

**A package is an attribute set.** It describes a derivation, a build recipe. Interpolating it into a string gives its store path, and Nix remembers that the string depends on that package.

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> pkgs = import <nixpkgs> { }
nix-repl> builtins.typeOf pkgs.hello
"set"
nix-repl> pkgs.hello.type
"derivation"
nix-repl> pkgs.hello.meta.description
"Program that produces a familiar, friendly greeting"
nix-repl> lib.hasPrefix "/nix/store/" "${pkgs.hello}"
true
nix-repl> lib.hasSuffix "/bin/hello" (lib.getExe pkgs.hello)
true
```

`"${pkgs.hello}"` is a path like `/nix/store/<hash>-hello-2.12.3`. `lib.getExe` returns the path of the package's main program, which is how `modules/desktop.nix` starts soteria.

Read the documentation of any function with `:doc`:

```
nix-repl> :doc builtins.map
Synopsis: builtins.map f list

Apply the function f to each element in the list list. For
example,

  │ map (x: "foo" + x) [ "bar" "bla" "abc" ]

evaluates to [ "foobar" "foobla" "fooabc" ].
```

`:doc lib.optionals` works too. On the web, [noogle.dev](https://noogle.dev/) searches every `builtins` and `lib` function with its type and examples.

**In your config:** `lib.mkForce`, `lib.getExe` and `lib.gvariant.mkInt32` in `modules/desktop.nix`; `pkgs.writeShellScript`, `pkgs.callPackage`, `pkgs.symlinkJoin` and `pkgs.buildEnv` as builders; every name in a `with pkgs; [ ... ]` list as a package.

**Check yourself:** what does `lib.optional false "a"` (no `s`) return, and how is it different from `lib.optionals`?

<details><summary>Answer</summary>

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> lib.optional false "a"
[ ]
nix-repl> lib.optional true "a"
[ "a" ]
```

`lib.optional cond x` wraps one element in a list. `lib.optionals cond list` takes a whole list.

</details>

### Step 13: Read a whole file

You now know every piece of syntax in your config. Here is `modules/tools.nix`, shortened only in the package list and the agent-browser wrapper, read piece by piece.

```nix
{ inputs, self, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      agent-browser = pkgsUnstable.symlinkJoin { ... };
    in
    {
      packages.tools = pkgsUnstable.buildEnv {
        name = "dotfiles-tools";
        paths = with pkgsUnstable; [
          mise
          chezmoi
          ...
          agent-browser
          rtk
          devenv
        ];
      };
    };

  flake.modules.nixos.tools =
    { pkgs, ... }:
    let
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      environment.systemPackages = [
        packages.tools
        packages.crib
      ];
    };
}
```

| Code | Language feature (step) | What it means here |
|----|----|----|
| `{ inputs, self, ... }:` | function with a pattern (7) | The whole file is a function. flake-parts calls it with `inputs`, `self` and more. |
| `{ perSystem = ...; flake.modules.nixos.tools = ...; }` | attribute set, dotted names (4) | The file's value: one set with two attributes. |
| `perSystem = { system, ... }: ...` | function (7) | flake-parts calls it once per system, here only `x86_64-linux`. |
| `let pkgsUnstable = ...; agent-browser = ...; in` | let (5) | Two local names, used in the set below. |
| `import inputs.nixpkgs-unstable { ... }` | import, call (8) | Import nixpkgs-unstable and call it with settings. |
| `inherit system;` | inherit (5) | `system = system;`, the argument from `perSystem`. |
| `config.allowUnfree = true;` | dotted name (4) | `config = { allowUnfree = true; };`, a nixpkgs setting. Not NixOS `config`. |
| `pkgsUnstable.buildEnv { ... }` | call (8) | One package that links many packages together. |
| `with pkgsUnstable; [ mise chezmoi ... ]` | with (6), list (3) | Package names without the `pkgsUnstable.` prefix. |
| `agent-browser` in that list | let beats with (6) | The wrapped package from the `let`, not `pkgsUnstable.agent-browser`. |
| `flake.modules.nixos.tools = { pkgs, ... }: ...` | dotted name (4), function (7) | Publish a NixOS module named `tools`. NixOS calls the function with `pkgs`. |
| `self.packages.${pkgs.stdenv.hostPlatform.system}` | dynamic name (4), outer scope (7) | This flake's packages for this machine's system. `self` comes from the outer function. |
| `[ packages.tools packages.crib ]` | list of selections (3, 4) | No calls in the list, so no parentheses are needed. |

Which layer each part belongs to:

- **Language:** all the syntax above.
- **nixpkgs:** `import inputs.nixpkgs-unstable { ... }`, `buildEnv`, `symlinkJoin`, the package names.
- **flake-parts:** the meaning of `perSystem`, `packages.tools`, `flake.modules.nixos.tools`, `self.packages`.
- **NixOS:** the meaning of `environment.systemPackages`.

Now open `modules/desktop.nix` and `modules/pkgs/helium.nix` and read them the same way. Every construct in them is covered by steps 1 to 12.

### Step 14: Where the language stops and the module system starts

The language has no idea what `services.tlp.enable` means. To the language, a NixOS module is just an attribute set, or a function that returns one.

```
nix-repl> mod = { pkgs, ... }: { environment.systemPackages = [ pkgs.git ]; }
nix-repl> :p mod { pkgs = { git = "git-2.50"; }; }
{
  environment = {
    systemPackages = [ "git-2.50" ];
  };
}
```

That is all the language does: call a function and build a set. The **module system**, written in Nix inside `lib`, adds the rest:

- It collects many modules and merges every value set for the same option.
- It checks each value against the option's declared type.
- It decides who wins with priorities (`lib.mkDefault`, plain values, `lib.mkForce`).
- It drops definitions wrapped in `lib.mkIf false`.

You can run the module system by hand on tiny modules with `lib.evalModules`. Each line below is three modules: one declares an option, two set it.

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> (lib.evalModules { modules = [ { options.xs = lib.mkOption { type = lib.types.listOf lib.types.str; }; } { xs = [ "a" ]; } { xs = [ "b" ]; } ]; }).config.xs
[
  "b"
  "a"
]
nix-repl> (lib.evalModules { modules = [ { options.name = lib.mkOption { type = lib.types.str; }; } { name = "a"; } { name = "b"; } ]; }).config.name
error: The option `name' has conflicting definition values:
nix-repl> (lib.evalModules { modules = [ { options.name = lib.mkOption { type = lib.types.str; }; } { name = "a"; } { name = lib.mkForce "b"; } ]; }).config.name
"b"
nix-repl> (lib.evalModules { modules = [ { options.name = lib.mkOption { type = lib.types.str; }; } { name = lib.mkDefault "a"; } { name = "b"; } ]; }).config.name
"b"
nix-repl> (lib.evalModules { modules = [ { options.name = lib.mkOption { type = lib.types.str; }; } { nmae = "a"; } ]; }).config.name
error: The option `nmae' does not exist. Definition values:
```

- Lists from different modules are **joined**. Two strings at the same priority **conflict**.
- `lib.mkForce` and `lib.mkDefault` change who wins.
- Setting an option nobody declared is an error. That is the check that catches typos like `services.pipewir`.

`lib.mkForce` is not magic either. It returns a plain attrset that the module system knows how to read:

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> lib.mkForce "b"
{
  _type = "override";
  content = "b";
  priority = 50;
}
```

Compare the two kinds of merging:

| | `//` (language) | modules (module system) |
|----|----|----|
| nested sets | right side replaces the whole nested set | merged key by key, as deep as it goes |
| same key twice | right side wins | lists join; single values conflict unless priorities differ |
| unknown names | allowed | error: option does not exist |

Your config uses one module system inside another. flake-parts is a module system for the flake, with options like `flake.modules.nixos.<name>` and `perSystem`. NixOS is a module system for the machine. That is why each feature file has two function layers (step 7). Handbook chapter 06 explains option types, priorities and `definitionsWithLocations` in depth. The flake guide explains the flake-parts layer.

## Debugging Nix code

### Four questions

When evaluation fails, answer these in order.

1. **Does it parse?** A syntax error means Nix never ran the code. `nix-instantiate --parse file.nix` checks one file.
2. **Which layer complained?** Language errors say things like `undefined variable`, `attribute ... missing`, `expected a set but found ...`. Module-system errors talk about options: `The option ... does not exist`, `conflicting definition values`.
3. **Where?** Read the **last** `error:` line first. It is the cause. The `at <file>:<line>:<column>` under it is where Nix noticed. The `… while ...` lines above it say how Nix got there.
4. **What is the value, really?** Shrink the problem: evaluate the one value that fails with `nix eval` or the REPL, check its type, print it.

### Reading an error

This is real output from a copy of your flake with one `;` removed from `modules/audio.nix`, line 8 (`jack.enable = true`). Store hashes and the middle of the trace are shortened.

```
error:
       … while evaluating the attribute 'root.result'
         at «flakes-internal»/call-flake.nix:94:7:
       ...

       (stack trace truncated; use '--show-trace' to show the full, detailed trace)

       error: syntax error, unexpected '=', expecting ';'
       at /nix/store/<hash>-source/modules/audio.nix:11:89:
           10|       # Drop this once a pipewire release survives Xwayland exiting. Disabling the module only loses the X11 bell sound.
           11|       extraConfig.pipewire."99-disable-x11-bell"."context.properties"."module.x11.bell" = false;
             |                                                                                         ^
           12|     };
```

- The first `error:` and the `… while` lines are context inside Nix itself. Skip them.
- The last `error:` is the cause: a syntax error.
- It points at **line 11**, but the missing `;` is on **line 8**. Without the `;`, Nix reads `true extraConfig.pipewire...` as a function call (step 8), skips the comment lines, and only gets stuck at the next `=`. **A syntax error points at where Nix gave up, which is often after the real mistake.** Look at the lines before the caret.

### Errors from the language

All of these are real Nix 2.34.9 output.

| Error | Usual cause | Fix |
|----|----|----|
| `syntax error, unexpected '}', expecting ';'` | missing `;` after a binding | add `;` at the end of the previous binding |
| `syntax error, unexpected 'in', expecting ';'` | missing `;` in a `let` | same |
| `syntax error, unexpected ','` | commas in a list | lists use spaces |
| `undefined variable 'foo'` | typo, a name used outside its scope, a name missing from a `with` set, or an argument not listed in the pattern | check spelling; add it to the function pattern; check the `with` set has it |
| `attribute 'foo' missing` | `s.foo` where `s` has no `foo` | check spelling with `builtins.attrNames s`; Nix 2.34 often adds `Did you mean ...?` |
| `attribute 'a' already defined at ...` | the same name twice in one set | merge them into one binding |
| `function '...' called without required argument 'b'` | the caller did not pass `b` | pass it, or give it a default `b ? ...` |
| `function '...' called with unexpected argument 'x'` | the pattern has no `...` | add `...` |
| `expected a set but found a function` | used `.` on a function, often a module you forgot to call | call it first, or check what you selected |
| `expected a set but found null` / `an integer` | selected an attribute from something that is not a set | check the value with `builtins.typeOf` |
| `attempt to call something which is not a function but a set` | a space between two things that Nix read as a call; often a missing `;` or missing parentheses in a list | look for the missing `;` or wrap the call in `( )` |
| `cannot coerce an integer to a string` | `"${5}"` or `"a" + 1` | `toString 5` |
| `expected a Boolean but found ...` | `if` with a non-boolean condition | compare explicitly: `x != null`, `x == ""` |
| `expected a list but found ...` | `++` with a non-list | wrap the value in `[ ]` |
| `infinite recursion encountered` | a value that depends on itself | find the cycle with `--show-trace`; in NixOS, often `imports` that depend on `config` |

### Errors from your config

These came from copies of your flake, each broken in one place on purpose, evaluated with `nix eval`. Only the last `error:` line and its location are shown.

| What was broken | Error | What it tells you |
|----|----|----|
| `services.pipewire` misspelled as `services.pipewir` in `audio.nix` | ``The option `services.pipewir' does not exist. Definition values: - In `/nix/store/<hash>-source/modules/audio.nix, via option flake.modules.nixos.audio' ... Did you mean `services.pipewire'?`` | A module-system error. It names the file and suggests the right option. |
| `firefox` misspelled as `firefx` in the `with pkgs;` list in `apps.nix` | `undefined variable 'firefx'` at `modules/apps.nix:13:9` | A misspelled package inside `with pkgs` is an undefined variable. Find the real name with `nix search nixpkgs firef`. |
| `audio` misspelled as `audoi` in the feature list of `hosts/x1/configuration.nix` | `undefined variable 'audoi'` at `modules/hosts/x1/configuration.nix:20:7` | Same: the list is inside `with self.modules.nixos`. |
| `{ pkgs, ... }:` changed to `{ pkgs }:` in `printing.nix` | `function 'printing' called with unexpected argument 'lib'` at `modules/printing.nix:3:5` | NixOS passes more than `pkgs`. Add `...`. |
| `{ pkgs, ... }:` changed to `pkgs:` in `printing.nix` | `attribute 'cups-brother-dcpt720dw' missing` at `modules/printing.nix:7:21` | `pkgs` is now the whole module argument set, which has no packages in it (step 7). |
| `inputs` removed from `{ inputs, self, ... }:` in `apps.nix` | `undefined variable 'inputs'` at `modules/apps.nix:26:9` | The file uses `inputs.voxtype`, so the outer pattern must list `inputs`. |

### Tools

**Evaluate one value instead of the whole system.** This is the fastest way to test a change. It needs no sudo and builds nothing.

```sh
F=~/.local/share/chezmoi/nixos
nix eval $F#nixosConfigurations.x1.config.networking.hostName
# "x1"
nix eval $F#nixosConfigurations.x1.config.networking.firewall.extraInputRules
# "ip saddr 192.168.0.0/16 accept"
nix eval $F#nixosConfigurations.x1.config.services.printing.drivers --apply 'map (p: p.name)'
# [ "cups-brother-dcpt720dw-3.5.0-1" ]
nix eval $F#packages.x86_64-linux --apply builtins.attrNames
# [ "claude-desktop" "crib" "grok-bot" "helium" "tools" ]
```

`--apply` runs a Nix function on the result before printing it. A list of packages prints as unreadable derivations, so map it to names first.

**Ask which file set an option.**

```sh
nix eval $F#nixosConfigurations.x1.options.services.tlp.settings.definitionsWithLocations --apply 'map (d: d.file)'
# [ "/nix/store/<hash>-source/modules/laptop.nix, via option flake.modules.nixos.laptop"
#   "/nix/store/<hash>-source/nixos/modules/services/hardware/tlp.nix" ]
```

**See the full chain.** Add `--show-trace` to any `nix eval`, `nixos-rebuild` or `nh` command. The trace is long. Read it from the bottom, and look for the first frame that names one of your files.

**Explore in the REPL.** `:lf` your flake (see the playground), then walk the value with tab completion. `nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1` opens a REPL with `config`, `options`, `pkgs` and `lib` already in scope (handbook chapter 09).

**Check types.** Many errors are "I thought this was a set, but it is a function". Ask Nix:

```
nix-repl> :t import <nixpkgs>
a function
nix-repl> builtins.typeOf { }
"set"
```

**Print values while evaluating.** `builtins.trace msg value` prints `msg` and returns `value` unchanged, so you can wrap any expression in it without changing what it means.

```
nix-repl> builtins.trace "hello" 42
trace: hello
42
nix-repl> builtins.trace { a.b = 1; } 0
trace: { a = «thunk»; }
0
nix-repl> lib = import <nixpkgs/lib>
nix-repl> lib.traceSeq { a.b = 1; } 0
trace: { a = { b = 1; }; }
0
nix-repl> lib.traceVal 5
trace: 5
5
```

`builtins.trace` does not compute nested values (laziness, step 10). `lib.traceSeq` computes them fully before printing. `lib.traceVal x` prints `x` and returns it.

In a module, wrap a value you want to see. In a copy of `modules/apps.nix`:

```nix
packages = builtins.trace "apps.nix: system is ${pkgs.stdenv.hostPlatform.system}" self.packages.${pkgs.stdenv.hostPlatform.system};
```

Evaluating the package list then printed `trace: apps.nix: system is x86_64-linux` before the result. Remove the trace when you are done.

**Cut the problem in half.** If you cannot tell which change broke evaluation, comment out half of the new code, evaluate, and repeat on the half that still fails. In a host's feature list, removing a feature name is a quick way to rule a whole file in or out.

### A worked session: "I added a package and it is not there"

1. **Is it in the config?** Evaluate the list, mapped to package names:

   ```sh
   nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.environment.systemPackages \
     --apply 'ps: builtins.elem "obsidian" (map (p: p.pname or p.name) ps)'
   # true
   ```

   `p.pname or p.name` uses `or` (step 4), because not every package has `pname`.
2. **If `false`:** was the file saved, and if it is new, is it `git add`ed? Is the feature that installs it in the host's list? Find where the list is defined with `definitionsWithLocations` on `environment.systemPackages`.
3. **If evaluation fails:** read the last `error:` line, then use the tables above.
4. **If `true` but the command is missing:** the config is right and the system is not switched yet. `nh os switch`, then `readlink -f "$(command -v obsidian)"`.

## Practice

Do these in a scratch file or the REPL. Answers are below each one.

**1. Read a pattern.** What does `({ a ? 1, ... }@args: args) { b = 2; }` return?

<details><summary>Answer</summary>

```
nix-repl> ({ a ? 1, ... }@args: args) { b = 2; }
{ b = 2; }
```

`args` is the set that was actually passed. Defaults like `a ? 1` do not appear in it.

</details>

**2. Write a function.** Write `greet`, which takes `{ name, greeting ? "hello" }` and returns `"hello x1"` for `greet { name = "x1"; }`.

<details><summary>Answer</summary>

```
nix-repl> greet = { name, greeting ? "hello" }: "${greeting} ${name}"
nix-repl> greet { name = "x1"; }
"hello x1"
nix-repl> greet { name = "x1"; greeting = "hi"; }
"hi x1"
```

</details>

**3. Build a set from a list.** Turn `[ "audio" "printing" ]` into `{ audio = true; printing = true; }`.

<details><summary>Answer</summary>

```
nix-repl> lib = import <nixpkgs/lib>
nix-repl> lib.genAttrs [ "audio" "printing" ] (name: true)
{
  audio = true;
  printing = true;
}
```

</details>

**4. Find the bug.** What is wrong with this list, and what error would you expect?

```nix
environment.systemPackages = with pkgs; [
  git
  pkgs.callPackage ./foo.nix { }
];
```

<details><summary>Answer</summary>

The call is not in parentheses, so the list has four elements: `git`, the function `pkgs.callPackage`, the path `./foo.nix` and an empty set. The module system then rejects the three that are not packages. Trying this in a copy of `modules/apps.nix` gave, for the function:

```
error: A definition for option `environment.systemPackages."[definition 2-entry 3]"' is not of type `package'. Definition values:
- In `/nix/store/<hash>-source/modules/apps.nix, via option flake.modules.nixos.apps': <function>
```

and the same message for the path and the `{ }`. The entry number depends on where in the list you put the call. Write `(pkgs.callPackage ./foo.nix { })`. In your config, packages built this way live in `modules/pkgs/` and are installed as `packages.<name>`, which is a selection and needs no parentheses.

</details>

**5. Write a feature.** Write a new `modules/gaming.nix` that publishes a NixOS module named `gaming` with `programs.steam.enable = true;`. Which function layers does it need?

<details><summary>Answer</summary>

None. It uses neither `pkgs` nor `inputs`, so both layers can be plain sets:

```nix
{
  flake.modules.nixos.gaming = {
    programs.steam.enable = true;
  };
}
```

Then add `gaming` to the host list and `git add` the file. The flake guide has the full recipe.

</details>

**6. Predict, then check.** In `modules/tools.nix`, would changing `agent-browser` in the list to `pkgsUnstable.agent-browser` change the system?

<details><summary>Answer</summary>

Yes. The bare name `agent-browser` refers to the `let` binding, the wrapper that drops `LD_LIBRARY_PATH` (step 6). `pkgsUnstable.agent-browser` is the unwrapped package, so the bug the wrapper's comment describes would come back.

</details>

## Cheat sheet

### Syntax

```nix
42  3.14  true  null  "string"  ./path               # values
"a ${b} c"                                           # interpolation (b: string, path or package)
''
  multi-line, ${nixExpr}, $SHELL_VAR, ''${LITERAL}
''
[ 1 "two" (f x) ]                                    # list: spaces; calls in ( )
{ a = 1; b.c = 2; "d-e" = 3; ${name} = 4; }          # set: ; after each; dotted names nest
s.a   s.a.b or 0   s ? a   s.${name}                 # select, default, has, dynamic
let x = 1; y = x + 1; in y                           # local names
{ inherit x; inherit (s) a b; }                      # x = x;  a = s.a; b = s.b;
with s; [ a b ]                                      # s's names in scope (lowest priority)
rec { a = 1; b = a + 1; }                            # set that sees itself
x: x + 1                                             # function
a: b: a + b                                          # two arguments, curried
{ a, b ? 2, ... }: a + b                             # pattern, default, allow extra
args@{ a, ... }: args                                # whole argument too
f x y                                                # call: just spaces
if c then a else b                                   # else is required
assert c; e                                          # stop if c is false
import ./file.nix                                    # value of another file
```

### Operators, tightest first

| Operator | Meaning |
|----|----|
| `s.a`, `s.a or d` | select |
| `f x` | call |
| `-x` | negate |
| `s ? a` | has attribute |
| `++` | join lists |
| `*` `/` | multiply, divide |
| `+` `-` | add, subtract, join strings and paths |
| `!` | not |
| `//` | update set (shallow, right wins) |
| `<` `<=` `>` `>=` | compare |
| `==` `!=` | equal, not equal |
| `&&` | and |
| `\|\|` | or |
| `->` | implies |

From the Nix 2.34 manual, "Operators". When unsure, add parentheses.

### Functions you will use

| Function | Example | Result |
|----|----|----|
| `builtins.attrNames` | `builtins.attrNames { b = 1; a = 2; }` | `[ "a" "b" ]` |
| `builtins.attrValues` | `builtins.attrValues { a = 1; b = 2; }` | `[ 1 2 ]` |
| `map` | `map (x: x * 2) [ 1 2 ]` | `[ 2 4 ]` |
| `builtins.filter` | `builtins.filter (x: x > 1) [ 1 2 3 ]` | `[ 2 3 ]` |
| `builtins.elem` | `builtins.elem 2 [ 1 2 3 ]` | `true` |
| `builtins.length` | `builtins.length [ 1 2 ]` | `2` |
| `builtins.typeOf` | `builtins.typeOf { }` | `"set"` |
| `builtins.toJSON` | `builtins.toJSON { a = [ 1 true null ]; }` | `"{\"a\":[1,true,null]}"` |
| `builtins.readFile` | `builtins.readFile ./file` | the file as a string |
| `builtins.trace` | `builtins.trace "msg" v` | prints `trace: msg`, returns `v` |
| `toString` | `toString [ 1 2 ]` | `"1 2"` |
| `lib.optionals` | `lib.optionals cond [ a b ]` | `[ a b ]` or `[ ]` |
| `lib.optional` | `lib.optional cond a` | `[ a ]` or `[ ]` |
| `lib.genAttrs` | `lib.genAttrs [ "a" ] (n: n)` | `{ a = "a"; }` |
| `lib.mapAttrs` | `lib.mapAttrs (n: v: v * 10) { a = 1; }` | `{ a = 10; }` |
| `lib.concatStringsSep` | `lib.concatStringsSep ", " [ "a" "b" ]` | `"a, b"` |
| `lib.recursiveUpdate` | `lib.recursiveUpdate { a.x = 1; } { a.y = 2; }` | `{ a = { x = 1; y = 2; }; }` |
| `lib.getExe` | `lib.getExe pkgs.soteria` | `"/nix/store/<hash>-soteria-<version>/bin/soteria"` |
| `lib.traceSeq` | `lib.traceSeq v r` | prints `v` fully, returns `r` |
| `lib.mkForce` / `lib.mkDefault` | `lib.mkForce v` | module priority 50 / 1000 |
| `lib.mkIf` | `lib.mkIf cond { ... }` | module definitions only when `cond` |

### REPL

```
nix repl                          start (from ~, for the path examples)
:lf /home/mgajewskik/.local/share/chezmoi/nixos   load your flake
lib = import <nixpkgs/lib>        load lib
pkgs = import <nixpkgs> { }       load packages
:t expr      type                 :p expr     print fully
:doc fn      documentation        :r          reload
:?           all commands         :q          quit
```

### Evaluating and checking

```sh
nix eval --file f.nix [attr]                     # value of a file
nix eval --raw / --json ...                      # string as is / JSON
nix eval --expr '1 + 2'                          # an inline expression
nix-instantiate --parse f.nix                    # syntax check only
nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.<option>
nix eval ...<option> --apply 'map (p: p.name)'   # post-process the result
nix eval ...options.<option>.definitionsWithLocations --apply 'map (d: d.file)'
<any nix / nixos-rebuild / nh command> --show-trace
nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1
nix run nixpkgs#nixfmt -- f.nix                  # format like the rest of the repo
```

### Errors in one line each

| You see | Look for |
|----|----|
| `syntax error ... expecting ';'` | missing `;` on or before the line shown |
| `undefined variable` | typo, missing argument in the pattern, name not in the `with` set |
| `attribute ... missing` | typo in a selection |
| `unexpected argument` | missing `...` in a pattern |
| `called without required argument` | caller forgot an argument, or add a default |
| `cannot coerce` | number in a string: `toString` |
| `expected a set but found a function` | forgot to call something |
| `option ... does not exist` | option typo, or the module that declares it is not imported |
| `conflicting definition values` | two modules set one value: remove one or `lib.mkForce` |
| `infinite recursion` | a value depends on itself; `--show-trace` |
| new file has no effect | `git add` it |

## Learning path

About eight hours, best spread over a week or two. Each block ends with something to do on the x1, so it sticks. Handbook chapter 12 has the broader NixOS learning path; this one is only about the language.

| # | Time | Do | Done when |
|----|----|----|----|
| 1 | 30 min | Read the ELI5 and ELI12 sections. Set up the playground and run every command in it. | `nix repl` and `nix eval --file` both work for you, and you can say which layer `lib.mkForce` belongs to. |
| 2 | 60 min | Steps 1 to 4. Type every example. Answer each check-yourself before opening the answer. | You can read `modules/networking.nix` and explain every `.` and every quote. |
| 3 | 60 min | Steps 5 to 8. | You can explain both function layers in `modules/apps.nix` and why `agent-browser` in `modules/tools.nix` is the wrapped one. |
| 4 | 45 min | Steps 9 to 12. | `:doc lib.optionals` works for you, and you can say what `"${pkgs.hello}"` evaluates to. |
| 5 | 90 min | [nix.dev: Nix language basics](https://nix.dev/tutorials/nix-language), the whole page, typing the examples. It covers the same ground from another angle, with more exercises. | You can read every expression on that page without running it. |
| 6 | 45 min | Step 13, then read `modules/desktop.nix` and `modules/pkgs/helium.nix` alone. | Every line of both files makes sense, or you know which step to reread. |
| 7 | 60 min | Step 14, then handbook chapter 06 and [nix.dev: module system](https://nix.dev/tutorials/module-system/). | You can explain why two files can both add to `environment.systemPackages` but cannot both set `networking.hostName`. |
| 8 | 45 min | Debugging section. Break a copy of a module on purpose (missing `;`, misspelled option, missing `...`), evaluate it with `nix eval`, read each error, fix it. Use `git stash` or `git checkout` to restore. | You can find the cause of each error from the message alone. |
| 9 | when needed | The [Nix manual's language chapter](https://nix.dev/manual/nix/2.34/language/) as a reference. It is also installed offline at `/run/current-system/sw/share/doc/nix/manual/language/index.html`. [noogle.dev](https://noogle.dev/) for `lib` and `builtins`. | — |

Skip for now: Nix Pills (they teach derivations from scratch, useful later for packaging), the nixpkgs manual (lookups only), string context details, and `builtins.derivation`.

Habits that make it stick:

- Before changing a file, predict what `nix eval` of the option will print. Then run it.
- When a line confuses you, copy the smallest piece into the REPL with fake values, like the `fakePkgs` set in steps 5 and 6.
- Format with nixfmt before committing. Consistent layout makes structure visible.

## Sources

- Nix 2.34 manual, language chapter: <https://nix.dev/manual/nix/2.34/language/>, and the same pages offline in `/run/current-system/sw/share/doc/nix/manual/language/`. The operator table comes from `operators.html`.
- nix.dev, Nix language basics: <https://nix.dev/tutorials/nix-language>
- nix.dev, module system tutorial: <https://nix.dev/tutorials/module-system/>
- noogle, search for `builtins` and `lib` functions: <https://noogle.dev/>
- nixpkgs `lib` source for the version in use: `lib/` under the nixpkgs path in `/etc/nix/registry.json`
- Your config: `nixos/flake.nix` and `nixos/modules/`
- The x1 handbook, chapters 05, 06, 09 and 12, and the flake guide, in this directory
