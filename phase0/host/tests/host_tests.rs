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

const PERSON_WASM: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../module/person-module.wasm");
const PERSON_NOWASI: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../module/person-module.nowasi.wasm");
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
fn stubbed_module_runs_with_wasi_off() {
    let wasm = std::fs::read(PERSON_NOWASI).expect("run stub-wasi.sh first");
    let mut host = Host::new(false).unwrap(); // WASI OFF — mimics real SpacetimeDB
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("person".into(), 1);
    let instance = host.instantiate(&wasm).unwrap(); // must NOT fail on missing wasi imports
    host.initialize(&instance).unwrap();
    let schema = host.describe(&instance).unwrap();
    assert_eq!(schema, std::fs::read(GOLDEN).unwrap());
    let (errno, err) = host.call_reducer(&instance, 0, bsatn_string("bob")).unwrap();
    assert_eq!(errno, 0, "reducer error: {}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![bsatn_string("bob")]);
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
