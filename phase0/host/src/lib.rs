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
    /// Pending source bytes by handle id (1-based). 0 means "no source".
    pub sources: std::collections::HashMap<u32, Vec<u8>>,
    /// Collected sink bytes by handle id.
    pub sinks: std::collections::HashMap<u32, Vec<u8>>,
}

impl HostState {
    pub fn new() -> Self {
        HostState {
            logs: Vec::new(),
            inserted: std::collections::HashMap::new(),
            table_ids: std::collections::HashMap::new(),
            wasi: None,
            sources: std::collections::HashMap::new(),
            sinks: std::collections::HashMap::new(),
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

    /// Like `instantiate`, but fills any imports not already in the linker with
    /// trap stubs.  This lets a real SpacetimeDB module (which imports many more
    /// host functions than our minimal stubs cover) instantiate without error.
    /// The extra imports will trap if called, but `__describe_module__` only
    /// calls `bytes_sink_write`, so they are never reached on the describe path.
    ///
    /// NOTE: this mutates the linker (adds trap stubs for unknown imports). Do
    /// not reuse this `Host` for a later strict `instantiate` call that must
    /// enforce imports — construct a fresh `Host` instead.
    pub fn instantiate_allowing_unknown(&mut self, wasm: &[u8]) -> Result<Instance> {
        let module = Module::new(&self.engine, wasm).context("compile module")?;
        self.linker.define_unknown_imports_as_traps(&module).context("define unknown imports as traps")?;
        let instance = self.linker.instantiate(&mut self.store, &module).context("instantiate module (allowing unknown)")?;
        Ok(instance)
    }

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
    ///
    /// Calls all `__preinit__*` exports (sorted by name) before `_initialize`.
    /// SpacetimeDB modules use `__preinit__20_register_describer_*` exports to
    /// populate the static describer list used by `__describe_module__`.  If
    /// these are not called, `__describe_module__` returns an empty module.
    pub fn initialize(&mut self, instance: &Instance) -> Result<()> {
        // Collect __preinit__ export names first to avoid borrow conflicts.
        let preinit_names: Vec<String> = instance
            .exports(&mut self.store)
            .filter_map(|e| {
                let name = e.name().to_owned();
                if name.starts_with("__preinit__") { Some(name) } else { None }
            })
            .collect();
        // Sort lexicographically (the numeric prefix ensures correct order).
        let mut sorted = preinit_names;
        sorted.sort();
        for name in sorted {
            let f = instance.get_typed_func::<(), ()>(&mut self.store, &name)?;
            f.call(&mut self.store, ())?;
        }
        if let Ok(f) = instance.get_typed_func::<(), ()>(&mut self.store, "_initialize") {
            f.call(&mut self.store, ())?;
        }
        Ok(())
    }

    /// Wire the `spacetime_10.0` host-function stubs into the linker.
    ///
    /// This subset covers logging, table-id lookup, row insertion, and the
    /// bytes source/sink streams used by the reducer calling convention.
    pub fn add_spacetime_stubs(&mut self) -> Result<()> {
        use wasmtime::Caller;

        // console_log(level, target, target_len, filename, filename_len, line, message_ptr, message_len)
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
        //   Mirrors the real SpacetimeDB host (crates/core/.../wasm_instance_env.rs):
        //   copy up to `cap` bytes into `buf`, ALWAYS write the count read back to
        //   `buf_len_ptr` (including 0), then return -1 iff the source is now
        //   exhausted (the -1 accompanies the final chunk), else 0. The real host
        //   also frees an exhausted source; we emulate that by clearing it. It is
        //   critical this returns -1 TOGETHER with the last bytes, not on a
        //   separate empty call — a module must harvest the bytes on the -1 call.
        self.linker.func_wrap("spacetime_10.0", "bytes_source_read", |mut caller: Caller<'_, HostState>,
            source: i32, buf_ptr: i32, buf_len_ptr: i32| -> i32 {
            let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
            let mut capb = [0u8; 4];
            mem.read(&caller, buf_len_ptr as usize, &mut capb).unwrap();
            let cap = u32::from_le_bytes(capb) as usize;
            let remaining = caller.data().sources.get(&(source as u32)).cloned().unwrap_or_default();
            let n = remaining.len().min(cap);
            if n > 0 {
                mem.write(&mut caller, buf_ptr as usize, &remaining[..n]).unwrap();
            }
            // Always report how many bytes were written (even 0).
            mem.write(&mut caller, buf_len_ptr as usize, &(n as u32).to_le_bytes()).unwrap();
            let rest = remaining[n..].to_vec();
            let exhausted = rest.is_empty();
            caller.data_mut().sources.insert(source as u32, rest);
            if exhausted { -1 } else { 0 }
        })?;

        // bytes_sink_write(sink, buf_ptr, buf_len_ptr) -> u16 errno
        //   Returns 0 = all bytes accepted; full NO_SPACE back-pressure is a Phase 1 concern.
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
