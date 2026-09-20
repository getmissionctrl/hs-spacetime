use anyhow::{Context, Result};
use wasmtime::{Engine, Instance, Linker, Module, Store};
use wasmtime_wasi::preview1::{WasiP1Ctx, add_to_linker_sync};
use wasmtime_wasi::WasiCtxBuilder;

pub struct HostState {
    pub logs: Vec<String>,
    pub inserted: std::collections::HashMap<u32, Vec<Vec<u8>>>,
    pub table_ids: std::collections::HashMap<String, u32>,
    pub wasi: WasiP1Ctx,
}

impl HostState {
    pub fn new() -> Self {
        HostState {
            logs: Vec::new(),
            inserted: std::collections::HashMap::new(),
            table_ids: std::collections::HashMap::new(),
            wasi: WasiCtxBuilder::new().build_p1(),
        }
    }
}

pub struct Host {
    pub engine: Engine,
    pub store: Store<HostState>,
    pub linker: Linker<HostState>,
}

impl Host {
    pub fn new(with_wasi: bool) -> Result<Self> {
        let engine = Engine::default();
        let mut linker: Linker<HostState> = Linker::new(&engine);
        if with_wasi {
            add_to_linker_sync(&mut linker, |s: &mut HostState| &mut s.wasi)?;
        }
        let store = Store::new(&engine, HostState::new());
        Ok(Host { engine, store, linker })
    }

    pub fn instantiate(&mut self, wasm: &[u8]) -> Result<Instance> {
        let module = Module::new(&self.engine, wasm).context("compile module")?;
        let instance = self.linker.instantiate(&mut self.store, &module).context("instantiate module")?;
        Ok(instance)
    }
}
