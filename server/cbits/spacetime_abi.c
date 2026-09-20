#include "spacetime_abi.h"
#include "HsFFI.h"

// Haskell entry points (foreign export ccall in the example module).
extern void  hs_describe(uint32_t sink);
extern int16_t hs_call_reducer(uint32_t id,
        uint64_t s0, uint64_t s1, uint64_t s2, uint64_t s3,
        uint64_t c0, uint64_t c1, uint64_t timestamp,
        uint32_t args, uint32_t error);

__attribute__((constructor))
static void phase1_init_rts(void) {
    int argc = 0;
    char *argv_storage[] = { 0 };
    char **argv = argv_storage;
    hs_init(&argc, &argv);
}

__attribute__((export_name("__describe_module__")))
void __describe_module__(uint32_t description) { hs_describe(description); }

// Forward EVERY parameter to Haskell (Phase 0 dropped sender/conn/timestamp).
__attribute__((export_name("__call_reducer__")))
int16_t __call_reducer__(uint32_t id,
        uint64_t s0, uint64_t s1, uint64_t s2, uint64_t s3,
        uint64_t c0, uint64_t c1, uint64_t timestamp,
        uint32_t args, uint32_t error) {
    return hs_call_reducer(id, s0, s1, s2, s3, c0, c1, timestamp, args, error);
}

// FFI wrappers so Haskell (which emits imports into "env") reaches the real
// spacetime_10.0 imports. Thin pass-throughs.
uint16_t shim_table_id_from_name(const uint8_t *n, size_t nl, uint32_t *o) { return st_table_id_from_name(n, nl, o); }
uint16_t shim_datastore_insert_bsatn(uint32_t t, uint8_t *r, size_t *rl) { return st_datastore_insert_bsatn(t, r, rl); }
int16_t  shim_bytes_source_read(uint32_t s, uint8_t *b, size_t *bl) { return st_bytes_source_read(s, b, bl); }
uint16_t shim_bytes_sink_write(uint32_t s, const uint8_t *b, size_t *bl) { return st_bytes_sink_write(s, b, bl); }
void     shim_console_log(uint8_t lvl, const uint8_t *t, size_t tl, const uint8_t *f, size_t fl, uint32_t line, const uint8_t *m, size_t ml) { st_console_log(lvl, t, tl, f, fl, line, m, ml); }
uint16_t shim_datastore_table_scan_bsatn(uint32_t t, uint32_t *o) { return st_datastore_table_scan_bsatn(t, o); }
int16_t  shim_row_iter_bsatn_advance(uint32_t it, uint8_t *b, size_t *bl) { return st_row_iter_bsatn_advance(it, b, bl); }
uint16_t shim_row_iter_bsatn_close(uint32_t it) { return st_row_iter_bsatn_close(it); }
uint16_t shim_datastore_delete_all_by_eq_bsatn(uint32_t t, const uint8_t *r, size_t rl, uint32_t *o) { return st_datastore_delete_all_by_eq_bsatn(t, r, rl, o); }
