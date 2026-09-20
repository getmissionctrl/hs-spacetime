use anyhow::{Context, Result};
use wasmtime::{Engine, Instance, Linker, Module, Store};
use wasmtime_wasi::preview1::{WasiP1Ctx, add_to_linker_sync};
use wasmtime_wasi::WasiCtxBuilder;

/// Shared state the host functions mutate. Grows in later tasks.
pub struct HostState {
    pub logs: Vec<String>,
    pub inserted: std::collections::HashMap<u32, Vec<Vec<u8>>>,
    pub table_ids: std::collections::HashMap<String, u32>,
    pub wasi: Option<WasiP1Ctx>,
}

impl HostState {
    pub fn new() -> Self {
        HostState {
            logs: Vec::new(),
            inserted: std::collections::HashMap::new(),
            table_ids: std::collections::HashMap::new(),
            wasi: None,
        }
    }
}

impl Default for HostState {
    fn default() -> Self {
        Self::new()
    }
}

/// Wasmtime engine, store, and linker bundled for convenient use in tests and the driver.
pub struct Host {
    pub engine: Engine,
    pub store: Store<HostState>,
    pub linker: Linker<HostState>,
}

impl Host {
    /// Create a new `Host`. Pass `with_wasi: true` to link WASI preview1 imports.
    pub fn new(with_wasi: bool) -> Result<Self> {
        let engine = Engine::default();
        let mut linker: Linker<HostState> = Linker::new(&engine);
        let mut state = HostState::new();
        if with_wasi {
            let ctx = WasiCtxBuilder::new().build_p1();
            state.wasi = Some(ctx);
            add_to_linker_sync(&mut linker, |s: &mut HostState| {
                s.wasi.as_mut().expect("WASI ctx not configured")
            })?;
        }
        let store = Store::new(&engine, state);
        Ok(Host { engine, store, linker })
    }

    /// Compile and instantiate a Wasm module against the linker's current imports.
    pub fn instantiate(&mut self, wasm: &[u8]) -> Result<Instance> {
        let module = Module::new(&self.engine, wasm).context("compile module")?;
        let instance = self.linker.instantiate(&mut self.store, &module).context("instantiate module")?;
        Ok(instance)
    }
}
