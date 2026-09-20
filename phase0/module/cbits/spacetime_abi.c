#include "spacetime_abi.h"
#include "HsFFI.h"

// Implemented in Haskell (Module.hs) via `foreign export ccall`.
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
