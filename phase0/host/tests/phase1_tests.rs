use phase0_host::Host;

fn bsatn_string(s: &str) -> Vec<u8> {
    let mut v = (s.len() as u32).to_le_bytes().to_vec();
    v.extend_from_slice(s.as_bytes());
    v
}
fn event_row(who: &str, at: i64) -> Vec<u8> {
    let mut v = bsatn_string(who);
    v.extend_from_slice(&at.to_le_bytes());
    v
}
const NOWASI: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../server/example/person-module.nowasi.wasm");

// Reducer ids follow the (alphabetical) schema array order that the host assigns:
//   0 = delete_all, 1 = record, 2 = record_n
const R_DELETE_ALL: u32 = 0;
const R_RECORD: u32 = 1;
const R_RECORD_N: u32 = 2;

fn fresh() -> (Host, wasmtime::Instance) {
    let wasm = std::fs::read(NOWASI).expect("run phase1 build+wizer+stub first");
    let mut host = Host::new(false).unwrap(); // WASI OFF
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("event".into(), 1);
    let inst = host.instantiate(&wasm).unwrap();
    host.initialize(&inst).unwrap();
    (host, inst)
}

#[test]
fn record_uses_context_timestamp() {
    let (mut host, inst) = fresh();
    // record(note) with a non-zero timestamp; the inserted row must carry it.
    let (errno, err) = host.call_reducer_ts(&inst, R_RECORD, 12345, bsatn_string("hi")).unwrap();
    assert_eq!(errno, 0, "{}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![event_row("hi", 12345)]);
}

#[test]
fn record_n_zero_is_error_not_trap() {
    let (mut host, inst) = fresh();
    let (errno, err) = host.call_reducer_ts(&inst, R_RECORD_N, 0, vec![0, 0, 0, 0]).unwrap(); // u32 count = 0
    assert_eq!(errno, 1);
    assert!(String::from_utf8_lossy(&err).contains("positive"));
}

#[test]
fn delete_all_scans_and_deletes() {
    let (mut host, inst) = fresh();
    host.call_reducer_ts(&inst, R_RECORD, 1, bsatn_string("a")).unwrap();
    host.call_reducer_ts(&inst, R_RECORD, 2, bsatn_string("b")).unwrap();
    assert_eq!(host.store.data().inserted.get(&1).unwrap().len(), 2);
    let (errno, _) = host.call_reducer_ts(&inst, R_DELETE_ALL, 0, vec![]).unwrap(); // delete_all, no args
    assert_eq!(errno, 0);
    assert_eq!(host.store.data().inserted.get(&1).map(|v| v.len()).unwrap_or(0), 0);
}

#[test]
fn delete_all_handles_row_larger_than_buffer() {
    // A row bigger than the drain's initial 4096 buffer forces the iterator to
    // return BUFFER_TOO_SMALL; the module must grow its buffer and retry, then
    // split + delete the row.
    let (mut host, inst) = fresh();
    let big = "y".repeat(5000);
    host.call_reducer_ts(&inst, R_RECORD, 1, bsatn_string(&big)).unwrap();
    assert_eq!(host.store.data().inserted.get(&1).unwrap().len(), 1);
    let (errno, err) = host.call_reducer_ts(&inst, R_DELETE_ALL, 0, vec![]).unwrap();
    assert_eq!(errno, 0, "{}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).map(|v| v.len()).unwrap_or(0), 0);
}

#[test]
fn multi_chunk_args_over_4096() {
    let (mut host, inst) = fresh();
    let big = "x".repeat(5000);
    let (errno, err) = host.call_reducer_ts(&inst, R_RECORD, 7, bsatn_string(&big)).unwrap();
    assert_eq!(errno, 0, "{}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![event_row(&big, 7)]);
}
