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
