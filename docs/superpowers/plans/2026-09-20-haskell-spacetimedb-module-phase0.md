# Haskell SpacetimeDB Server Module — Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove (go/no-go) that a GHC-compiled WebAssembly module can act as a SpacetimeDB v2.10 server module — instantiate with zero WASI imports in unmodified SpacetimeDB, describe a schema, and run a reducer that inserts a row observable via the existing `hs-spacetime` client.

**Architecture:** Two tracks. **Track B** is a standalone Rust + Wasmtime *test host* that stubs the `spacetime_10.0` ABI over an in-memory datastore and can toggle WASI on/off — the hermetic rig. **Track A** is the WASI-stub + Wizer pipeline that produces a no-WASI module and validates it against a real `spacetime start`. A trivial fixture (`person { name: string }`, reducer `add(name)`) is authored in both Rust (golden-schema oracle) and Haskell (the artifact under test). Row BSATN reuses the repo's existing `SpacetimeDB.BSATN` codec; the schema is reproduced from captured golden bytes (no schema emitter until Phase 2).

**Tech Stack:** GHC wasm backend (`ghc-wasm-meta`: `wasm32-wasi-ghc`, bundled `clang`), `wizer`, `wasm-tools`, Rust + `wasmtime`/`wasmtime-wasi` crates, Nix flakes, the `spacetime` CLI (already in `.#live`).

**Design reference:** `docs/superpowers/specs/2026-09-20-haskell-spacetimedb-module-phase0-design.md`.

**Layout created by this plan (all under `phase0/`, isolated from the shipping client library):**

```
phase0/
  host/                    # Track B: Rust wasmtime test host
    Cargo.toml
    src/lib.rs             # host library: fake datastore, spacetime stubs, drivers
    src/main.rs            # thin CLI wrapper
    tests/host_tests.rs    # hermetic tests driven by WAT + built modules
    tests/wat/*.wat        # tiny hand-written test modules
  fixture-person/          # Rust `person` module — golden schema oracle + live sanity
    Cargo.toml
    src/lib.rs
  module/                  # Haskell server module (the artifact under test)
    Module.hs
    cbits/spacetime_abi.c
    cbits/spacetime_abi.h
  scripts/
    build-module.sh        # wasm32-wasi-ghc + clang -> reactor wasm
    capture-golden.sh      # emit golden/person.schema.bsatn from the Rust fixture
    stub-wasi.sh           # produce a no-WASI module
    check-imports.sh       # assert zero wasi_snapshot_preview1 imports
    wizer-init.sh          # pre-initialize the heap
  golden/
    person.schema.bsatn    # captured RawModuleDefV10 BSATN for `person`
```

**Milestones inside this plan:**
- **M-B (hermetic green):** after Task 9 — the WASI build runs end-to-end in the Track B host.
- **M-A (go/no-go):** after Task 13 — the stubbed+Wizer'd module runs on real SpacetimeDB.

---

## Task 1: Add the `.#wasm` Nix dev shell

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add `ghc-wasm-meta` as a flake input**

In `flake.nix`, add to `inputs`:

```nix
    ghc-wasm-meta = {
      url = "github:tweag/ghc-wasm-meta";
      inputs.nixpkgs.follows = "nixpkgs";
    };
```

And add `ghc-wasm-meta` to the `outputs = { ... }:` argument list.

- [ ] **Step 2: Define the `wasm` shell**

In the `let` block (after `live = ...`), add:

```nix
        wasmToolchain = ghc-wasm-meta.packages.${system}.all_9_10;
        wasm = pkgs.mkShell {
          # GHC wasm backend + Wizer + wasm-tools + Rust host toolchain + spacetime CLI.
          packages = [
            wasmToolchain
            pkgs.wizer
            pkgs.wasm-tools
            pkgs.rustup
            pkgs.cargo
            spacetimeCli
          ];
        };
```

Then in the returned attrset add:

```nix
        devShells.wasm = wasm;
```

- [ ] **Step 3: Verify the toolchain resolves**

Run: `nix develop .#wasm --command bash -c 'wasm32-wasi-ghc --version; wizer --version; wasm-tools --version'`
Expected: three version lines print, no error. If `all_9_10` is not an attribute of `ghc-wasm-meta.packages`, run `nix eval .#inputs 2>/dev/null; nix flake show github:tweag/ghc-wasm-meta` to list the available package names and substitute the newest `all_9_*` (GHC ≥ 9.10 is required for the reactor + `--export` flags this plan uses). Record the chosen name in a comment above `wasmToolchain`.

- [ ] **Step 4: Commit**

```bash
git add flake.nix flake.lock
git commit -m "build(phase0): add .#wasm dev shell (ghc-wasm-meta, wizer, wasm-tools)"
```

---

## Task 2: Scaffold the Track B Rust test host and load a trivial module

**Files:**
- Create: `phase0/host/Cargo.toml`
- Create: `phase0/host/src/lib.rs`
- Create: `phase0/host/src/main.rs`
- Create: `phase0/host/tests/wat/noop.wat`
- Create: `phase0/host/tests/host_tests.rs`

- [ ] **Step 1: Write `Cargo.toml`**

```toml
[package]
name = "phase0-host"
version = "0.1.0"
edition = "2021"

[lib]
name = "phase0_host"
path = "src/lib.rs"

[[bin]]
name = "phase0-host"
path = "src/main.rs"

[dependencies]
wasmtime = "27"
wasmtime-wasi = "27"
anyhow = "1"

[dev-dependencies]
wat = "1"
```

- [ ] **Step 2: Write the minimal host `lib.rs` (instantiation only)**

```rust
use anyhow::{Context, Result};
use wasmtime::{Engine, Instance, Linker, Module, Store};

/// Shared state the host functions mutate. Grows in later tasks.
#[derive(Default)]
pub struct HostState {
    pub logs: Vec<String>,
    /// Rows inserted per table id, as raw BSATN bytes.
    pub inserted: std::collections::HashMap<u32, Vec<Vec<u8>>>,
    /// Table name -> id, seeded by the host.
    pub table_ids: std::collections::HashMap<String, u32>,
}

pub struct Host {
    pub engine: Engine,
    pub store: Store<HostState>,
    pub linker: Linker<HostState>,
}

impl Host {
    /// Build a host. `with_wasi` toggles the WASI preview1 shim so the same
    /// host can run both the WASI build (Track B) and the stubbed build
    /// (Track A fidelity check).
    pub fn new(with_wasi: bool) -> Result<Self> {
        let engine = Engine::default();
        let mut linker: Linker<HostState> = Linker::new(&engine);
        if with_wasi {
            wasmtime_wasi::preview1::add_to_linker_sync(&mut linker, |s: &mut HostState| {
                // A per-store WASI ctx is required; store it beside HostState.
                &mut s.wasi
            })?;
        }
        let store = Store::new(&engine, HostState::default());
        Ok(Host { engine, store, linker })
    }

    pub fn instantiate(&mut self, wasm: &[u8]) -> Result<Instance> {
        let module = Module::new(&self.engine, wasm).context("compile module")?;
        let instance = self
            .linker
            .instantiate(&mut self.store, &module)
            .context("instantiate module")?;
        Ok(instance)
    }
}
```

Note: `add_to_linker_sync` needs a `WasiP1Ctx` living in the store. Extend `HostState` with `pub wasi: wasmtime_wasi::preview1::WasiP1Ctx` and initialize it in `Default`/a constructor. If `wasmtime 27`'s exact path differs, `wasm32-wasi` docs for the pinned version give the correct symbol — verify in Step 4 and adjust the two `wasmtime_wasi::preview1::*` references only.

- [ ] **Step 3: Write `main.rs` (thin CLI, used by Track A live steps later)**

```rust
use anyhow::Result;
use phase0_host::Host;

fn main() -> Result<()> {
    let path = std::env::args().nth(1).expect("usage: phase0-host <module.wasm>");
    let wasm = std::fs::read(&path)?;
    let mut host = Host::new(true)?;
    let _instance = host.instantiate(&wasm)?;
    println!("instantiated {path} OK");
    Ok(())
}
```

- [ ] **Step 4: Write the trivial WAT fixture**

`phase0/host/tests/wat/noop.wat`:

```wat
(module
  (memory (export "memory") 1)
  (func (export "_initialize"))
)
```

- [ ] **Step 5: Write the failing test**

`phase0/host/tests/host_tests.rs`:

```rust
use phase0_host::Host;

fn wat_to_wasm(path: &str) -> Vec<u8> {
    let text = std::fs::read_to_string(path).unwrap();
    wat::parse_str(&text).unwrap()
}

#[test]
fn instantiates_trivial_module_with_wasi_off() {
    let wasm = wat_to_wasm("tests/wat/noop.wat");
    let mut host = Host::new(false).unwrap();
    let instance = host.instantiate(&wasm).unwrap();
    assert!(instance.get_memory(&mut host.store, "memory").is_some());
}
```

- [ ] **Step 6: Run it and confirm it builds and passes**

Run: `nix develop .#wasm --command bash -c 'cd phase0/host && rustup default stable >/dev/null 2>&1; cargo test instantiates_trivial_module_with_wasi_off -- --nocapture'`
Expected: PASS. If the `wasmtime_wasi::preview1` symbol was wrong in Step 2, the compile error names it here; fix and rerun.

- [ ] **Step 7: Commit**

```bash
git add phase0/host
git commit -m "feat(phase0): Track B host scaffold instantiates a trivial wasm module"
```

---

## Task 3: Implement the fake datastore + `spacetime_10.0` host stubs

**Files:**
- Modify: `phase0/host/src/lib.rs`
- Create: `phase0/host/tests/wat/log_and_insert.wat`
- Modify: `phase0/host/tests/host_tests.rs`

- [ ] **Step 1: Add the source/sink model and register the stub imports**

Add to `lib.rs`. `BytesSource`/`BytesSink` are host-owned handles; for the tests we seed one source (reducer args) and collect one sink (schema/error output). Append to `HostState`:

```rust
    /// Pending source bytes by handle id (1-based). 0 means "no source".
    pub sources: std::collections::HashMap<u32, Vec<u8>>,
    /// Collected sink bytes by handle id.
    pub sinks: std::collections::HashMap<u32, Vec<u8>>,
```

Add a method on `Host` that wires the `spacetime_10.0` functions into the linker. Register exactly the subset Phase 0 exercises:

```rust
impl Host {
    pub fn add_spacetime_stubs(&mut self) -> Result<()> {
        use wasmtime::Caller;

        // console_log(level:i32, target,target_len, filename,filename_len,
        //             line:i32, message_ptr, message_len)
        self.linker.func_wrap("spacetime_10.0", "console_log", |mut caller: Caller<'_, HostState>,
            _level: i32, _t: i32, _tl: i32, _f: i32, _fl: i32, _line: i32, msg: i32, msg_len: i32| {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut buf = vec![0u8; msg_len as usize];
            mem.read(&caller, msg as usize, &mut buf).unwrap();
            caller.data_mut().logs.push(String::from_utf8_lossy(&buf).into_owned());
        })?;

        // table_id_from_name(name_ptr, name_len, out_ptr) -> u16 errno
        self.linker.func_wrap("spacetime_10.0", "table_id_from_name", |mut caller: Caller<'_, HostState>,
            name: i32, name_len: i32, out: i32| -> i32 {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut buf = vec![0u8; name_len as usize];
            mem.read(&caller, name as usize, &mut buf).unwrap();
            let key = String::from_utf8_lossy(&buf).into_owned();
            match caller.data().table_ids.get(&key).copied() {
                Some(id) => { mem.write(&mut caller, out as usize, &id.to_le_bytes()).unwrap(); 0 }
                None => 4, // NO_SUCH_TABLE
            }
        })?;

        // datastore_insert_bsatn(table_id, row_ptr, row_len_ptr) -> u16 errno
        // row_len_ptr points at the length; we read len, then the row bytes.
        self.linker.func_wrap("spacetime_10.0", "datastore_insert_bsatn", |mut caller: Caller<'_, HostState>,
            table_id: i32, row_ptr: i32, row_len_ptr: i32| -> i32 {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut lenb = [0u8; 4];
            mem.read(&caller, row_len_ptr as usize, &mut lenb).unwrap();
            let len = u32::from_le_bytes(lenb) as usize;
            let mut row = vec![0u8; len];
            mem.read(&caller, row_ptr as usize, &mut row).unwrap();
            caller.data_mut().inserted.entry(table_id as u32).or_default().push(row);
            0
        })?;

        // bytes_source_read(source, buf_ptr, buf_len_ptr) -> i16
        //   0 = wrote some/all, -1 = exhausted, positive = errno (BUFFER_TOO_SMALL=11)
        self.linker.func_wrap("spacetime_10.0", "bytes_source_read", |mut caller: Caller<'_, HostState>,
            source: i32, buf_ptr: i32, buf_len_ptr: i32| -> i32 {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut capb = [0u8; 4];
            mem.read(&caller, buf_len_ptr as usize, &mut capb).unwrap();
            let cap = u32::from_le_bytes(capb) as usize;
            let remaining = caller.data().sources.get(&(source as u32)).cloned().unwrap_or_default();
            if remaining.is_empty() { return -1; }
            let n = remaining.len().min(cap);
            mem.write(&mut caller, buf_ptr as usize, &remaining[..n]).unwrap();
            mem.write(&mut caller, buf_len_ptr as usize, &(n as u32).to_le_bytes()).unwrap();
            caller.data_mut().sources.insert(source as u32, remaining[n..].to_vec());
            0
        })?;

        // bytes_sink_write(sink, buf_ptr, buf_len_ptr) -> u16 errno
        self.linker.func_wrap("spacetime_10.0", "bytes_sink_write", |mut caller: Caller<'_, HostState>,
            sink: i32, buf_ptr: i32, buf_len_ptr: i32| -> i32 {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut lenb = [0u8; 4];
            mem.read(&caller, buf_len_ptr as usize, &mut lenb).unwrap();
            let len = u32::from_le_bytes(lenb) as usize;
            let mut buf = vec![0u8; len];
            mem.read(&caller, buf_ptr as usize, &mut buf).unwrap();
            caller.data_mut().sinks.entry(sink as u32).or_default().extend_from_slice(&buf);
            0 // accept all; never signal NO_SPACE in Phase 0
        })?;

        Ok(())
    }
}
```

Note on `bytes_sink_write` return semantics: the module treats `0` as "all bytes accepted, advance by `*buf_len_ptr`". Because this stub always accepts the full buffer and leaves `*buf_len_ptr` unchanged (= full len), the module's write loop terminates in one pass. This matches the host contract closely enough for Phase 0; full `NO_SPACE` back-pressure is a Phase 1 concern (spec risk table #? — deferred).

- [ ] **Step 2: Write a WAT fixture that logs then inserts**

`phase0/host/tests/wat/log_and_insert.wat` — a module that, in an exported `run`, writes a 3-byte row `AAA` at offset 100, its length at 200, and calls `datastore_insert_bsatn(7, 100, 200)`, and logs "hi" (bytes at 300):

```wat
(module
  (import "spacetime_10.0" "console_log"
    (func $log (param i32 i32 i32 i32 i32 i32 i32 i32)))
  (import "spacetime_10.0" "datastore_insert_bsatn"
    (func $insert (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "AAA")
  (data (i32.const 200) "\03\00\00\00")   ;; row length = 3, LE u32
  (data (i32.const 300) "hi")
  (func (export "_initialize"))
  (func (export "run") (result i32)
    (call $log (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)
               (i32.const 0) (i32.const 0) (i32.const 300) (i32.const 2))
    (call $insert (i32.const 7) (i32.const 100) (i32.const 200))))
```

- [ ] **Step 3: Write the failing test**

Append to `host_tests.rs`:

```rust
#[test]
fn stubs_capture_log_and_insert() {
    let wasm = wat_to_wasm("tests/wat/log_and_insert.wat");
    let mut host = Host::new(false).unwrap();
    host.add_spacetime_stubs().unwrap();
    let instance = host.instantiate(&wasm).unwrap();
    let run = instance.get_typed_func::<(), i32>(&mut host.store, "run").unwrap();
    let errno = run.call(&mut host.store, ()).unwrap();
    assert_eq!(errno, 0);
    assert_eq!(host.store.data().logs, vec!["hi".to_string()]);
    assert_eq!(host.store.data().inserted.get(&7).unwrap(), &vec![b"AAA".to_vec()]);
}
```

- [ ] **Step 4: Run it**

Run: `nix develop .#wasm --command bash -c 'cd phase0/host && cargo test stubs_capture_log_and_insert -- --nocapture'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add phase0/host
git commit -m "feat(phase0): fake datastore + spacetime_10.0 host stubs"
```

---

## Task 4: Add the `__describe_module__` / `__call_reducer__` drivers

**Files:**
- Modify: `phase0/host/src/lib.rs`
- Create: `phase0/host/tests/wat/describe.wat`
- Modify: `phase0/host/tests/host_tests.rs`

- [ ] **Step 1: Add driver methods**

Add to `lib.rs`:

```rust
impl Host {
    /// Call __describe_module__(sink) and return the bytes written to the sink.
    pub fn describe(&mut self, instance: &Instance) -> Result<Vec<u8>> {
        let sink_id: u32 = 1;
        self.store.data_mut().sinks.insert(sink_id, Vec::new());
        let f = instance
            .get_typed_func::<i32, ()>(&mut self.store, "__describe_module__")?;
        f.call(&mut self.store, sink_id as i32)?;
        Ok(self.store.data().sinks.get(&sink_id).cloned().unwrap_or_default())
    }

    /// Call __call_reducer__ with the given args bytes fed via a source.
    /// Returns (errno, error_sink_bytes).
    pub fn call_reducer(&mut self, instance: &Instance, id: u32, args: Vec<u8>) -> Result<(i32, Vec<u8>)> {
        let args_source: u32 = 2;
        let error_sink: u32 = 3;
        self.store.data_mut().sources.insert(args_source, args);
        self.store.data_mut().sinks.insert(error_sink, Vec::new());
        // Signature: (id:i32, sender0..3:i64, conn0,1:i64, ts:i64, args:i32, error:i32) -> i32
        let f = instance.get_typed_func::<
            (i32, i64, i64, i64, i64, i64, i64, i64, i32, i32), i32>(
            &mut self.store, "__call_reducer__")?;
        let errno = f.call(&mut self.store,
            (id as i32, 0, 0, 0, 0, 0, 0, 0, args_source as i32, error_sink as i32))?;
        let err = self.store.data().sinks.get(&error_sink).cloned().unwrap_or_default();
        Ok((errno, err))
    }

    /// Optional reactor init.
    pub fn initialize(&mut self, instance: &Instance) -> Result<()> {
        if let Ok(f) = instance.get_typed_func::<(), ()>(&mut self.store, "_initialize") {
            f.call(&mut self.store, ())?;
        }
        Ok(())
    }
}
```

- [ ] **Step 2: Write a WAT fixture whose `__describe_module__` writes 4 bytes to the sink**

`phase0/host/tests/wat/describe.wat`:

```wat
(module
  (import "spacetime_10.0" "bytes_sink_write"
    (func $sink (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "\de\ad\be\ef")
  (data (i32.const 200) "\04\00\00\00")   ;; len = 4
  (func (export "_initialize"))
  (func (export "__describe_module__") (param $sink i32)
    (drop (call $sink (local.get $sink) (i32.const 100) (i32.const 200)))))
```

- [ ] **Step 3: Write the failing test**

```rust
#[test]
fn describe_driver_collects_sink_bytes() {
    let wasm = wat_to_wasm("tests/wat/describe.wat");
    let mut host = Host::new(false).unwrap();
    host.add_spacetime_stubs().unwrap();
    let instance = host.instantiate(&wasm).unwrap();
    let bytes = host.describe(&instance).unwrap();
    assert_eq!(bytes, vec![0xde, 0xad, 0xbe, 0xef]);
}
```

- [ ] **Step 4: Run it**

Run: `nix develop .#wasm --command bash -c 'cd phase0/host && cargo test describe_driver_collects_sink_bytes -- --nocapture'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add phase0/host
git commit -m "feat(phase0): describe/call_reducer host drivers"
```

---

## Task 5: Author the Rust `person` fixture and capture golden schema bytes

**Files:**
- Create: `phase0/fixture-person/Cargo.toml`
- Create: `phase0/fixture-person/src/lib.rs`
- Create: `phase0/scripts/capture-golden.sh`
- Create: `phase0/golden/person.schema.bsatn` (generated)

- [ ] **Step 1: Write the Rust fixture (matches `person { name: string }`, reducer `add`)**

`phase0/fixture-person/Cargo.toml`:

```toml
[package]
name = "phase0-fixture-person"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
spacetimedb = "2.10"

[profile.release]
opt-level = "z"
lto = true
```

`phase0/fixture-person/src/lib.rs`:

```rust
use spacetimedb::{reducer, table, ReducerContext, Table};

#[table(accessor = person, public)]
pub struct Person {
    pub name: String,
}

#[reducer]
pub fn add(ctx: &ReducerContext, name: String) {
    ctx.db.person().insert(Person { name });
}
```

- [ ] **Step 2: Write the golden-capture script**

`phase0/scripts/capture-golden.sh` (build the Rust fixture to wasm, then extract the BSATN emitted by its `__describe_module__` using the Track B host's `describe`):

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/fixture-person"
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
wasm="target/wasm32-unknown-unknown/release/phase0_fixture_person.wasm"
# Reuse the host binary's describe path via a tiny helper subcommand.
cd "$root/host"
cargo run --quiet --bin phase0-host -- --describe "$root/fixture-person/$wasm" \
  > "$root/golden/person.schema.bsatn"
echo "wrote golden/person.schema.bsatn ($(wc -c < "$root/golden/person.schema.bsatn") bytes)"
```

- [ ] **Step 3: Add the `--describe` subcommand to `main.rs`**

Modify `phase0/host/src/main.rs`:

```rust
use anyhow::Result;
use phase0_host::Host;
use std::io::Write;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let first = args.next().expect("usage: phase0-host [--describe] <module.wasm>");
    let (describe, path) = if first == "--describe" {
        (true, args.next().expect("module path"))
    } else {
        (false, first)
    };
    let wasm = std::fs::read(&path)?;
    let mut host = Host::new(true)?;
    host.add_spacetime_stubs()?;
    let instance = host.instantiate(&wasm)?;
    host.initialize(&instance)?;
    if describe {
        let bytes = host.describe(&instance)?;
        std::io::stdout().write_all(&bytes)?;
    } else {
        eprintln!("instantiated {path} OK");
    }
    Ok(())
}
```

- [ ] **Step 4: Capture the golden bytes**

Run: `nix develop .#wasm --command bash -c 'rustup default stable >/dev/null 2>&1; chmod +x phase0/scripts/capture-golden.sh && phase0/scripts/capture-golden.sh'`
Expected: prints `wrote golden/person.schema.bsatn (N bytes)` with N > 0. If the Rust build needs the wasm target, the script adds it; if `spacetimedb` 2.10 changes the `#[table]` attribute spelling, mirror the working form from `../../fixture/src/lib.rs`.

- [ ] **Step 5: Sanity-check the golden bytes decode as a schema (optional but recommended)**

Run: `nix develop .#live --command bash -c 'xxd phase0/golden/person.schema.bsatn | head'`
Expected: non-empty hex dump. (Deep validation happens in Task 9 when the Haskell module must reproduce these exact bytes.)

- [ ] **Step 6: Commit**

```bash
git add phase0/fixture-person phase0/scripts/capture-golden.sh phase0/host/src/main.rs phase0/golden/person.schema.bsatn
git commit -m "feat(phase0): Rust person fixture + captured golden schema bytes"
```

---

## Task 6: Write the C shim (host imports, exports, RTS init)

**Files:**
- Create: `phase0/module/cbits/spacetime_abi.h`
- Create: `phase0/module/cbits/spacetime_abi.c`

- [ ] **Step 1: Write the header declaring host imports with wasm import attributes**

`phase0/module/cbits/spacetime_abi.h`:

```c
#pragma once
#include <stdint.h>
#include <stddef.h>

#define ST_IMPORT(name) \
  __attribute__((import_module("spacetime_10.0"), import_name(name)))

// Returns u16 errno (0 = ok). out receives the table id (LE u32).
ST_IMPORT("table_id_from_name")
uint16_t st_table_id_from_name(const uint8_t *name, size_t name_len, uint32_t *out);

// Returns u16 errno. row_len points at length (in/out); row bytes at row.
ST_IMPORT("datastore_insert_bsatn")
uint16_t st_datastore_insert_bsatn(uint32_t table_id, uint8_t *row, size_t *row_len);

// Returns i16: 0 ok, -1 exhausted, >0 errno. buf_len is capacity in / written out.
ST_IMPORT("bytes_source_read")
int16_t st_bytes_source_read(uint32_t source, uint8_t *buf, size_t *buf_len);

// Returns u16 errno. buf_len is len in / bytes-consumed out.
ST_IMPORT("bytes_sink_write")
uint16_t st_bytes_sink_write(uint32_t sink, const uint8_t *buf, size_t *buf_len);

ST_IMPORT("console_log")
void st_console_log(uint8_t level, const uint8_t *target, size_t target_len,
                    const uint8_t *filename, size_t filename_len, uint32_t line,
                    const uint8_t *message, size_t message_len);
```

- [ ] **Step 2: Write the C shim body (exports + Haskell trampolines + RTS init)**

`phase0/module/cbits/spacetime_abi.c`:

```c
#include "spacetime_abi.h"
#include "HsFFI.h"

// Implemented in Haskell (Module.hs) via `foreign export ccall`.
// describe: write the schema into `sink`. call_reducer: consume args from
// `args` source, insert, write any error to `err` sink; return 0 or errno.
extern void hs_describe(uint32_t sink);
extern int16_t hs_call_reducer(uint32_t args, uint32_t err);

// Initialize the GHC RTS exactly once, driven by the reactor's ctor pass.
__attribute__((constructor))
static void phase0_init_rts(void) {
    int argc = 0;
    char *argv_storage[] = { 0 };
    char **argv = argv_storage;
    hs_init(&argc, &argv);
}

__attribute__((export_name("__describe_module__")))
void __describe_module__(uint32_t description) {
    hs_describe(description);
}

__attribute__((export_name("__call_reducer__")))
int16_t __call_reducer__(uint32_t id,
        uint64_t s0, uint64_t s1, uint64_t s2, uint64_t s3,
        uint64_t c0, uint64_t c1, uint64_t timestamp,
        uint32_t args, uint32_t error) {
    (void)id; (void)s0; (void)s1; (void)s2; (void)s3;
    (void)c0; (void)c1; (void)timestamp;
    return hs_call_reducer(args, error);
}
```

Note: the `constructor` runs during `_initialize` (reactor model). Wizer (Task 12) snapshots the heap *after* this runs, so the deployed module does not re-init. If GHC's chosen toolchain does not run C constructors under `-mexec-model=reactor`, Task 8 Step 4 detects it (missing `_initialize` or a trap on first call) and the fallback is to call `hs_init` at the top of both trampolines guarded by a static flag.

- [ ] **Step 3: Commit**

```bash
git add phase0/module/cbits
git commit -m "feat(phase0): C shim for spacetime ABI imports/exports + RTS init"
```

---

## Task 7: Write the Haskell module logic

**Files:**
- Create: `phase0/module/Module.hs`

- [ ] **Step 1: Write the module (reuses `SpacetimeDB.BSATN` from the repo library)**

`phase0/module/Module.hs`:

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Module where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.FileEmbed (embedFile)
import Data.IORef ()
import Data.Word (Word16, Word32)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, poke)
import Data.Int (Int16)

import SpacetimeDB.BSATN.Decoder (Decoder, runExact, string)
import SpacetimeDB.BSATN.Encoder (encodeString, runEncoder)

-- Host imports (declared in the C shim).
foreign import ccall unsafe "st_table_id_from_name"
  c_table_id_from_name :: Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "st_datastore_insert_bsatn"
  c_insert :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "st_bytes_source_read"
  c_source_read :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "st_bytes_sink_write"
  c_sink_write :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16

-- Golden schema BSATN, reproduced byte-for-byte (Phase 2 replaces this with a
-- real RawModuleDefV10 emitter). Path is relative to the module source dir.
schemaBytes :: ByteString
schemaBytes = $(embedFile "../golden/person.schema.bsatn")

-- Read all bytes from a source handle, growing the buffer as needed.
readSource :: Word32 -> IO ByteString
readSource src = go BS.empty
  where
    cap = 4096
    go acc = allocaBytes cap $ \buf -> alloca $ \lenp -> do
      poke lenp (fromIntegral cap)
      rc <- c_source_read src buf lenp
      if rc == (-1)
        then pure acc
        else do
          n <- peek lenp
          chunk <- BS.packCStringLen (castPtr buf, fromIntegral n)
          if fromIntegral n < cap then pure (acc <> chunk) else go (acc <> chunk)

-- Write a full ByteString into a sink handle.
writeSink :: Word32 -> ByteString -> IO ()
writeSink sink payload =
  BSU.unsafeUseAsCStringLen payload $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_sink_write sink (castPtr ptr) lenp
    pure ()

-- __describe_module__ trampoline target.
foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe sink = writeSink sink schemaBytes

-- __call_reducer__ trampoline target: decode {name}, insert into `person`.
foreign export ccall hs_call_reducer :: Word32 -> Word32 -> IO Int16
hs_call_reducer :: Word32 -> Word32 -> IO Int16
hs_call_reducer argsSrc _errSink = do
  argBytes <- readSource argsSrc
  case runExact string argBytes of
    Left _ -> pure 1  -- HOST_CALL_FAILURE
    Right name -> do
      tid <- lookupPersonId
      let row = runEncoder encodeString name  -- product {name} = bare string
      insertRow tid row
      pure 0

lookupPersonId :: IO Word32
lookupPersonId =
  BSU.unsafeUseAsCStringLen "person" $ \(ptr, len) -> alloca $ \outp -> do
    _ <- c_table_id_from_name (castPtr ptr) (fromIntegral len) outp
    peek outp

insertRow :: Word32 -> ByteString -> IO ()
insertRow tid row =
  BSU.unsafeUseAsCStringLen row $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_insert tid (castPtr ptr) lenp
    pure ()
```

- [ ] **Step 2: Fix imports the compiler will demand**

Add these to the import list at the top (kept separate here so the intent is clear): `Foreign.Ptr (castPtr)`, `Foreign.C.Types (CSize)`, `Data.Word (Word8)`. The plan omitted them from Step 1's list deliberately — add them now so the module compiles:

```haskell
import Foreign.Ptr (Ptr, castPtr)
import Foreign.C.Types (CSize)
import Data.Word (Word8, Word16, Word32)
```

Remove the unused `Data.IORef ()` line.

- [ ] **Step 3: Commit**

```bash
git add phase0/module/Module.hs
git commit -m "feat(phase0): Haskell module — describe (golden) + add reducer"
```

---

## Task 8: Build the Haskell module to a WASI reactor `.wasm`

**Files:**
- Create: `phase0/scripts/build-module.sh`

- [ ] **Step 1: Write the build script**

`phase0/scripts/build-module.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/module/person-module.wasm"
libdir="$(cd "$root/.." && pwd)/src"   # the hs-spacetime client library sources

cd "$root/module"

# Compile the C shim with the bundled clang (wasm32-wasi), emitting an object.
wasm32-wasi-clang -O2 -c cbits/spacetime_abi.c -o cbits/spacetime_abi.o \
  -I"$(wasm32-wasi-ghc --print-libdir)/include"

# Build the reactor module. We compile the two BSATN modules the fixture uses
# directly (Phase 0 avoids a full cabal wasm build; Phase 1 introduces one).
wasm32-wasi-ghc \
  -no-hs-main -optl-mexec-model=reactor \
  -optl-Wl,--export=__describe_module__ \
  -optl-Wl,--export=__call_reducer__ \
  -optl-Wl,--export=_initialize \
  -optl-Wl,--export=memory \
  -i"$libdir" \
  -O2 \
  Module.hs \
  "$libdir/SpacetimeDB/BSATN/Decoder.hs" \
  "$libdir/SpacetimeDB/BSATN/Encoder.hs" \
  cbits/spacetime_abi.o \
  -o "$out"

echo "built $out"
```

Notes: `--print-libdir/include` supplies `HsFFI.h`. `Encoder.hs`/`Decoder.hs` depend only on `bytestring`, `text`, `wide-word` — all present in the wasm GHC's package db; if `wide-word` is absent from the bundled global package db, add `-package wide-word` and, if needed, vendor it via `cabal`/`--package-db` (a `wasm32-wasi-cabal` build is the Phase 1 replacement for this hand-compile).

- [ ] **Step 2: Add `file-embed` availability**

The module uses `Data.FileEmbed`. Confirm it is in the wasm package db:

Run: `nix develop .#wasm --command bash -c 'wasm32-wasi-ghc-pkg list | grep -i file-embed || echo MISSING'`
Expected: a `file-embed-*` line. If `MISSING`, replace the `embedFile` splice in `Module.hs` with a plain `BS.readFile`-free constant: run `xxd -i phase0/golden/person.schema.bsatn` and paste the byte list as `schemaBytes = BS.pack [ ... ]`, dropping the `file-embed` import and the TemplateHaskell. (TH may also be unavailable in the wasm cross-compiler; if the `embedFile` splice fails to run, use the `BS.pack` form. This is the more robust default — prefer it if unsure.)

- [ ] **Step 3: Build**

Run: `nix develop .#wasm --command bash -c 'chmod +x phase0/scripts/build-module.sh && phase0/scripts/build-module.sh'`
Expected: `built .../person-module.wasm`. Resolve any missing-package or TH errors per Step 2's guidance before proceeding.

- [ ] **Step 4: Verify the required exports are present**

Run: `nix develop .#wasm --command bash -c 'wasm-tools print phase0/module/person-module.wasm | grep -E "\(export \"(__describe_module__|__call_reducer__|memory|_initialize)\"" '`
Expected: four `(export ...)` lines. If `_initialize` is absent, the reactor model flag was not honored — revisit Task 6 Step 2's fallback (guarded `hs_init` in trampolines) and rebuild.

- [ ] **Step 5: Commit**

```bash
git add phase0/scripts/build-module.sh phase0/module/Module.hs
git commit -m "feat(phase0): build Haskell module to WASI reactor wasm"
```

---

## Task 9 (Milestone M-B): Run the WASI build end-to-end in the Track B host

**Files:**
- Modify: `phase0/host/tests/host_tests.rs`

- [ ] **Step 1: Write the failing end-to-end test (WASI on)**

The test seeds `person -> table id 1`, feeds BSATN for `{name = "alice"}` (a bare string: LE u32 length `5` + `alice`), and asserts one row is inserted whose bytes equal the same encoding. It also asserts `describe` equals the golden file.

```rust
const PERSON_WASM: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../module/person-module.wasm");
const GOLDEN: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../golden/person.schema.bsatn");

fn bsatn_string(s: &str) -> Vec<u8> {
    let mut v = (s.len() as u32).to_le_bytes().to_vec();
    v.extend_from_slice(s.as_bytes());
    v
}

#[test]
fn haskell_module_describes_and_inserts_over_wasi() {
    let wasm = std::fs::read(PERSON_WASM).expect("build the module first (build-module.sh)");
    let mut host = Host::new(true).unwrap();          // WASI ON
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("person".into(), 1);
    let instance = host.instantiate(&wasm).unwrap();
    host.initialize(&instance).unwrap();

    let schema = host.describe(&instance).unwrap();
    let golden = std::fs::read(GOLDEN).unwrap();
    assert_eq!(schema, golden, "module schema must match golden");

    let (errno, err) = host.call_reducer(&instance, 0, bsatn_string("alice")).unwrap();
    assert_eq!(errno, 0, "reducer error: {}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![bsatn_string("alice")]);
}

#[test]
fn haskell_module_reentrancy_many_inserts() {
    let wasm = std::fs::read(PERSON_WASM).unwrap();
    let mut host = Host::new(true).unwrap();
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("person".into(), 1);
    let instance = host.instantiate(&wasm).unwrap();
    host.initialize(&instance).unwrap();
    for i in 0..50 {
        let (errno, _) = host.call_reducer(&instance, 0, bsatn_string(&format!("p{i}"))).unwrap();
        assert_eq!(errno, 0);
    }
    assert_eq!(host.store.data().inserted.get(&1).unwrap().len(), 50);
}
```

- [ ] **Step 2: Build the module, then run the tests**

Run: `nix develop .#wasm --command bash -c 'phase0/scripts/build-module.sh && cd phase0/host && cargo test haskell_module -- --nocapture'`
Expected: both tests PASS. If the schema assertion fails, the golden was captured from a fixture whose field encoding differs — re-capture with Task 5 and confirm the Rust and Haskell field names/types match exactly (`person`, single `name: String`).

- [ ] **Step 3: Commit — Milestone M-B reached**

```bash
git add phase0/host/tests/host_tests.rs
git commit -m "test(phase0): M-B — Haskell module describes+inserts over WASI (hermetic)"
```

---

## Task 10: Enumerate and stub the WASI imports

**Files:**
- Create: `phase0/scripts/stub-wasi.sh`
- Create: `phase0/module/cbits/wasi_stubs.c`

- [ ] **Step 1: Record the WASI import list as an artifact**

Run: `nix develop .#wasm --command bash -c 'wasm-tools print phase0/module/person-module.wasm | grep "wasi_snapshot_preview1" | sort -u | tee phase0/module/wasi-imports.txt'`
Expected: a list such as `fd_write`, `fd_close`, `fd_seek`, `clock_time_get`, `random_get`, `proc_exit`, `environ_get`, `environ_sizes_get`, `args_get`, `args_sizes_get`, `fd_fdstat_get`, `poll_oneoff`, `sched_yield`. The exact set is what GHC's RTS pulls in; treat this file as the checklist for Step 2.

- [ ] **Step 2: Write stub implementations for every imported WASI function**

`phase0/module/cbits/wasi_stubs.c` — each stub is defined as an *exported-by-name-replacement*: we compile these with the same import names so wasm-merge/wasm-tools can satisfy them, OR (simpler, chosen here) we define them as normal functions and let `wasm-tools` string-replace the import. The robust mechanism is a link-time replacement using `wasm-tools component`/`wasm-merge`; for Phase 0 use the **stub-and-relink** approach below. Provide deterministic, side-effect-free bodies:

```c
#include <stdint.h>
#include <stddef.h>

// Minimal WASI preview1 stubs. Any function GHC's RTS imports must appear here.
// Return 0 (ESUCCESS) for the harmless ones; trap for the forbidden ones.

#define WASI_EXPORT(n) __attribute__((export_name(n)))

WASI_EXPORT("proc_exit")      void  wasi_proc_exit(int32_t code) { (void)code; __builtin_trap(); }
WASI_EXPORT("clock_time_get") int32_t wasi_clock_time_get(int32_t id, int64_t p, int32_t out) { (void)id;(void)p; *(int64_t*)(uintptr_t)out = 0; return 0; }
WASI_EXPORT("random_get")     int32_t wasi_random_get(int32_t buf, int32_t len) { for (int32_t i=0;i<len;i++) ((uint8_t*)(uintptr_t)buf)[i]=0; return 0; }
WASI_EXPORT("sched_yield")    int32_t wasi_sched_yield(void) { return 0; }
WASI_EXPORT("args_sizes_get") int32_t wasi_args_sizes_get(int32_t c, int32_t b) { *(int32_t*)(uintptr_t)c=0; *(int32_t*)(uintptr_t)b=0; return 0; }
WASI_EXPORT("args_get")       int32_t wasi_args_get(int32_t a, int32_t b) { (void)a;(void)b; return 0; }
WASI_EXPORT("environ_sizes_get") int32_t wasi_environ_sizes_get(int32_t c, int32_t b) { *(int32_t*)(uintptr_t)c=0; *(int32_t*)(uintptr_t)b=0; return 0; }
WASI_EXPORT("environ_get")    int32_t wasi_environ_get(int32_t a, int32_t b) { (void)a;(void)b; return 0; }
// fd_write: swallow output (Phase 1 routes to console_log). Report all bytes written.
WASI_EXPORT("fd_write")       int32_t wasi_fd_write(int32_t fd, int32_t iovs, int32_t n, int32_t nwritten) { (void)fd;(void)iovs;(void)n; *(int32_t*)(uintptr_t)nwritten=0; return 0; }
WASI_EXPORT("fd_close")       int32_t wasi_fd_close(int32_t fd) { (void)fd; return 0; }
WASI_EXPORT("fd_seek")        int32_t wasi_fd_seek(int32_t fd, int64_t off, int32_t w, int32_t out) { (void)fd;(void)off;(void)w; *(int64_t*)(uintptr_t)out=0; return 0; }
WASI_EXPORT("fd_fdstat_get")  int32_t wasi_fd_fdstat_get(int32_t fd, int32_t out) { (void)fd;(void)out; return 0; }
WASI_EXPORT("poll_oneoff")    int32_t wasi_poll_oneoff(int32_t a,int32_t b,int32_t c,int32_t d){(void)a;(void)b;(void)c;(void)d; return 0;}
```

Cross-check this list against `phase0/module/wasi-imports.txt` from Step 1. **Add a stub for every entry that file contains and this file does not.** A WASI import with no safe stub (e.g. one whose semantics the RTS genuinely needs at runtime and cannot be faked deterministically) is a **no-go finding** — record it in `phase0/module/wasi-imports.txt` with a note and stop; that is a valid Phase 0 outcome.

- [ ] **Step 3: Write the relink script (replace WASI imports with the stubs)**

`phase0/scripts/stub-wasi.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
in="$root/module/person-module.wasm"
out="$root/module/person-module.nowasi.wasm"

# Compile stubs to their own module.
wasm32-wasi-clang -O2 -nostdlib -Wl,--no-entry -Wl,--allow-undefined \
  -o "$root/module/wasi_stubs.wasm" "$root/module/cbits/wasi_stubs.c"

# Merge: wasm-merge resolves the module's wasi_snapshot_preview1 imports
# against the stubs module's matching exports.
wasm-merge \
  "$in" spacetime_10.0 \
  "$root/module/wasi_stubs.wasm" wasi_snapshot_preview1 \
  -o "$out" --enable-bulk-memory --enable-multivalue
echo "wrote $out"
```

Note: `wasm-merge` ships with `binaryen`. If `.#wasm` lacks it, add `pkgs.binaryen` to the `wasm` shell packages (Task 1) and re-enter. If `wasm-merge`'s namespace-matching flags differ in the installed binaryen, the alternative is `wasm-tools`'s component tooling; the goal is invariant — produce `person-module.nowasi.wasm` with the same behavior and no `wasi_snapshot_preview1` imports.

- [ ] **Step 4: Produce the no-WASI module**

Run: `nix develop .#wasm --command bash -c 'chmod +x phase0/scripts/stub-wasi.sh && phase0/scripts/stub-wasi.sh'`
Expected: `wrote .../person-module.nowasi.wasm`.

- [ ] **Step 5: Commit**

```bash
git add phase0/scripts/stub-wasi.sh phase0/module/cbits/wasi_stubs.c phase0/module/wasi-imports.txt
git commit -m "feat(phase0): WASI-import stubs + relink to a no-WASI module"
```

---

## Task 11 (go/no-go criterion 1): Assert zero WASI imports and re-run in the host with WASI OFF

**Files:**
- Create: `phase0/scripts/check-imports.sh`
- Modify: `phase0/host/tests/host_tests.rs`

- [ ] **Step 1: Write the import-checker script**

`phase0/scripts/check-imports.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wasm="${1:-$root/module/person-module.nowasi.wasm}"
if wasm-tools print "$wasm" | grep -q "wasi_snapshot_preview1"; then
  echo "FAIL: $wasm still imports wasi_snapshot_preview1:" >&2
  wasm-tools print "$wasm" | grep "wasi_snapshot_preview1" | sort -u >&2
  exit 1
fi
echo "OK: no WASI imports in $wasm"
```

- [ ] **Step 2: Run the checker (this is go/no-go criterion 1, machine-checked)**

Run: `nix develop .#wasm --command bash -c 'chmod +x phase0/scripts/check-imports.sh && phase0/scripts/check-imports.sh'`
Expected: `OK: no WASI imports ...`. A `FAIL` lists the surviving imports — return to Task 10 Step 2 and stub them, or record a no-go if un-stubbable.

- [ ] **Step 3: Write the fidelity test — the stubbed module runs with WASI OFF**

Append to `host_tests.rs`:

```rust
const PERSON_NOWASI: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../module/person-module.nowasi.wasm");

#[test]
fn stubbed_module_runs_with_wasi_off() {
    let wasm = std::fs::read(PERSON_NOWASI).expect("run stub-wasi.sh first");
    let mut host = Host::new(false).unwrap();          // WASI OFF — mimics real SpacetimeDB
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("person".into(), 1);
    let instance = host.instantiate(&wasm).unwrap();   // must NOT fail on missing wasi imports
    host.initialize(&instance).unwrap();
    let schema = host.describe(&instance).unwrap();
    assert_eq!(schema, std::fs::read(GOLDEN).unwrap());
    let (errno, err) = host.call_reducer(&instance, 0, bsatn_string("bob")).unwrap();
    assert_eq!(errno, 0, "reducer error: {}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![bsatn_string("bob")]);
}
```

- [ ] **Step 4: Run it**

Run: `nix develop .#wasm --command bash -c 'phase0/scripts/stub-wasi.sh && cd phase0/host && cargo test stubbed_module_runs_with_wasi_off -- --nocapture'`
Expected: PASS. A failure at `instantiate` means a WASI import survived (should have been caught in Step 2) or a stub traps during init — inspect with `--nocapture` and fix the offending stub in Task 10.

- [ ] **Step 5: Commit**

```bash
git add phase0/scripts/check-imports.sh phase0/host/tests/host_tests.rs
git commit -m "test(phase0): assert zero WASI imports + stubbed module runs WASI-off"
```

---

## Task 12: Pre-initialize the heap with Wizer

**Files:**
- Create: `phase0/scripts/wizer-init.sh`

- [ ] **Step 1: Write the Wizer script**

`phase0/scripts/wizer-init.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Wizer runs _initialize (with WASI available so the RTS ctor can complete),
# snapshots the heap, and emits a module that starts pre-initialized.
wizer \
  --allow-wasi \
  --init-func _initialize \
  --wasm-bulk-memory true \
  "$root/module/person-module.wasm" \
  -o "$root/module/person-module.wizened.wasm"
echo "wrote person-module.wizened.wasm"
```

Note: Wizer is run on the **WASI build** (it needs WASI to execute `_initialize`), producing a snapshot. Then re-run `stub-wasi.sh` against the wizened module to strip any WASI imports the snapshot still references at runtime. If Wizer errors that `_initialize` is missing or that the module is not a reactor, that confirms the Task 6 constructor did not wire to `_initialize`; apply the guarded-`hs_init` fallback and rebuild.

- [ ] **Step 2: Wizen, then stub, then verify**

Run:
```
nix develop .#wasm --command bash -c '
  chmod +x phase0/scripts/wizer-init.sh
  phase0/scripts/wizer-init.sh
  phase0/scripts/stub-wasi.sh   # (edit temporarily to read the .wizened.wasm input, or copy over person-module.wasm)
  phase0/scripts/check-imports.sh phase0/module/person-module.nowasi.wasm'
```
Expected: `wrote person-module.wizened.wasm` then `OK: no WASI imports`. Simplest wiring: change `stub-wasi.sh`'s `in=` to prefer `person-module.wizened.wasm` when it exists. Make that edit and commit it here.

- [ ] **Step 3: Re-run the WASI-off host test against the wizened+stubbed module**

Run: `nix develop .#wasm --command bash -c 'cd phase0/host && cargo test stubbed_module_runs_with_wasi_off -- --nocapture'`
Expected: PASS (same assertions, now on the pre-initialized module).

- [ ] **Step 4: Commit**

```bash
git add phase0/scripts/wizer-init.sh phase0/scripts/stub-wasi.sh
git commit -m "feat(phase0): Wizer pre-initialization of the module heap"
```

---

## Task 13 (Milestone M-A / go/no-go): Publish to real SpacetimeDB and verify via the client

**Files:**
- Create: `phase0/scripts/live-check.sh`
- Create: `phase0/host/../live/LiveCheck.md` (notes only) — optional

- [ ] **Step 1: Write the live check script**

`phase0/scripts/live-check.sh` — boots a throwaway server (reuse the repo's harness), publishes the stubbed+wizened module as a raw wasm, then leaves the server up and prints `READY <port> <db>` for the client step:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
module="$root/module/person-module.nowasi.wasm"
check_imports() { "$root/scripts/check-imports.sh" "$module"; }
check_imports

# Start an in-memory server (background), capture its port.
spacetime start --in-memory --listen-addr 127.0.0.1:0 &
srv=$!
trap 'kill $srv 2>/dev/null || true' EXIT
sleep 2
# Discover the port from `spacetime server list`/logs; the repo's
# scripts/live-harness.sh already solves this — prefer calling it:
#   source-compatible: scripts/live-harness.sh prints "READY <port> <db> <root>"
echo "Publishing $module ..."
spacetime publish --bin-path "$module" --server "http://127.0.0.1:${PORT:?set PORT}" person-hs
echo "Published. Calling reducer add('carol') ..."
spacetime call --server "http://127.0.0.1:${PORT}" person-hs add '"carol"'
echo "Querying rows ..."
spacetime sql --server "http://127.0.0.1:${PORT}" person-hs 'SELECT * FROM person'
```

Note: prefer wiring this to the existing `scripts/live-harness.sh` (which already boots a throwaway server and prints `READY <port> <db> <root>`) rather than re-implementing port discovery. The key new step is `spacetime publish --bin-path <wasm>` pointing at our stubbed module instead of a Rust build. Verify the exact publish flag for a prebuilt wasm: `spacetime publish --help | grep -iE "bin|wasm|path"`; substitute the correct flag name.

- [ ] **Step 2: Run the publish + CLI round-trip (go/no-go criteria 1–3)**

Run: `SPACETIMEDB_INTEGRATION=1 nix develop .#live --command bash -c 'chmod +x phase0/scripts/live-check.sh && phase0/scripts/live-check.sh'`
Expected, in order: `OK: no WASI imports`; `Published.`; the `add` call returns without error; the `SELECT * FROM person` output contains a row `carol`. **Any failure at `publish` that mentions ABI/instantiation is the primary go/no-go signal** — capture the full server log (`spacetime logs person-hs`) into `phase0/module/nogo-<reason>.log` and stop.

- [ ] **Step 3: Verify through the existing `hs-spacetime` client (criterion 3, end-to-end)**

Write a tiny client check that subscribes and asserts the row arrives. Reuse the library's `SpacetimeDB` API (see `README.md` sketch). Create `phase0/live/client-check.hs` and run it against the live db from Step 1 (kept running). Minimal body:

```haskell
{-# LANGUAGE OverloadedStrings #-}
import SpacetimeDB
import Control.Concurrent (threadDelay)

main :: IO ()
main = do
  Right client <- start
    ( builder "127.0.0.1" 3000 "person-hs"     -- use the harness's actual port
        & subscribe "SELECT * FROM person"
        & onEvent print )
  threadDelay 2000000
  stop client
```

Run it in `.#live` (via `runghc` with the library on the path, or add a throwaway cabal exe). Expected: the printed events include the `carol` row (and any earlier `add` rows). If the client cannot connect while the CLI can, that is a client-vs-module issue, not a go/no-go blocker — note it and treat criteria 1–2 + the CLI `SELECT` in Step 2 as the authoritative pass.

- [ ] **Step 4: Reentrancy under the real host (criterion 4)**

Run: `nix develop .#live --command bash -c 'for i in $(seq 1 20); do spacetime call --server "http://127.0.0.1:${PORT}" person-hs add "\"p$i\""; done; spacetime sql --server "http://127.0.0.1:${PORT}" person-hs "SELECT COUNT(*) FROM person"'`
Expected: the count reflects all inserts (initial + 20, plus any from Step 2/3) with no trap in `spacetime logs`.

- [ ] **Step 5: Record the go/no-go verdict and commit**

Create `phase0/GO-NO-GO.md` summarizing: criterion 1 (imports) — pass/fail; criterion 2 (publish accepts schema) — pass/fail; criterion 3 (reducer inserts, row observable) — pass/fail; criterion 4 (reentrancy) — pass/fail; plus the `wasi-imports.txt` list and any blockers. Then:

```bash
git add phase0/scripts/live-check.sh phase0/live phase0/GO-NO-GO.md
git commit -m "test(phase0): M-A — live publish + reducer round-trip; record go/no-go"
```

---

## Self-Review

**Spec coverage:**
- Feasibility go/no-go (spec DoD) → Tasks 11 (criterion 1), 13 (criteria 2–4), verdict in Task 13 Step 5. ✓
- Track B hermetic host in Rust/wasmtime, WASI toggle → Tasks 2–4, 9, 11. ✓
- Track A WASI-stub + Wizer on unmodified SpacetimeDB → Tasks 10–13. ✓
- Trivial `person`/`add` fixture, golden schema bytes, reuse existing BSATN codec → Tasks 5, 7. ✓
- C-shim FFI (import_module attrs) + required exports + RTS init → Task 6; exports verified Task 8 Step 4. ✓
- Toolchain (`ghc-wasm-meta`, `wizer`, `wasm-tools`) in a Nix shell → Task 1. ✓
- Import-list artifact (machine-checked criterion 1) → Task 10 Step 1, Task 11. ✓
- Error/errno + `i16`/`i32` handling → Tasks 3, 4, 6, 7 (return codes 0/1, `-1` exhausted, `BUFFER_TOO_SMALL` grow-loop). ✓
- Named risks: #1 import-module naming (Task 6 attrs), #2 Wizer×reactor (Task 12 note + fallback), #3 clock/random init (Task 10 constant stubs), #4 i16/i32 (Task 4/6 signatures), #5 un-stubbable WASI import = documented no-go (Task 10 Step 2), #6 GC/fuel out of scope (not implemented — correct). ✓

**Placeholder scan:** No "TBD/TODO/handle edge cases". The several "verify the exact flag/symbol against the installed version" steps are concrete discovery actions with commands and a stated reaction, not deferred work — acceptable and necessary for external toolchains whose minor-version surfaces vary.

**Type/name consistency:** `Host::new(bool)`, `add_spacetime_stubs`, `describe`, `call_reducer`, `initialize`, `HostState{logs,inserted,table_ids,sources,sinks,wasi}` used consistently across Tasks 2/3/4/5/9/11. C exports `__describe_module__`/`__call_reducer__` and Haskell trampolines `hs_describe`/`hs_call_reducer` match between Task 6 and Task 7. `bsatn_string` helper defined once (Task 9) and reused (Task 11). `person`/table-id-1/`schemaBytes`/golden path consistent across Tasks 5/7/9/11/13.

**Known softness (flagged, not placeholders):** exact `wasmtime_wasi::preview1` symbol (Task 2 Step 6 catches), `ghc-wasm-meta` package attr name (Task 1 Step 3 catches), `file-embed`/TH availability (Task 8 Step 2 provides the `BS.pack` fallback), `wasm-merge` namespace flags (Task 10 Step 3 note), `spacetime publish --bin-path` flag (Task 13 Step 1 verifies). Each has a command to confirm and a defined fallback.
