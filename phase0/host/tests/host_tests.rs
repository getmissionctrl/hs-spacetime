use phase0_host::Host;

fn wat_to_wasm(path: &str) -> Vec<u8> {
    let text = std::fs::read_to_string(path).expect(&format!("read WAT fixture {path}"));
    wat::parse_str(&text).expect(&format!("parse WAT fixture {path}"))
}

#[test]
fn instantiates_trivial_module_with_wasi_off() {
    let wasm = wat_to_wasm("tests/wat/noop.wat");
    let mut host = Host::new(false).unwrap();
    let instance = host.instantiate(&wasm).unwrap();
    assert!(instance.get_memory(&mut host.store, "memory").is_some());
}

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

#[test]
fn describe_driver_collects_sink_bytes() {
    let wasm = wat_to_wasm("tests/wat/describe.wat");
    let mut host = Host::new(false).unwrap();
    host.add_spacetime_stubs().unwrap();
    let instance = host.instantiate(&wasm).unwrap();
    let bytes = host.describe(&instance).unwrap();
    assert_eq!(bytes, vec![0xde, 0xad, 0xbe, 0xef]);
}
