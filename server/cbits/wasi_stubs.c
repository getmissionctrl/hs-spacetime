// WASI preview1 stubs for the WASI-off SpacetimeDB module.
//
// After Wizer snapshots the post-`hs_init` heap, the GHC RTS no longer runs its
// init path at deploy time, so most of these are never called at runtime. But
// the wasm still IMPORTS all 18 functions, and the real SpacetimeDB host links
// NO WASI. We compile this module and merge its exports over the WASI imports
// (see stub-wasi.sh), yielding zero `wasi_snapshot_preview1` imports.
//
// Semantics: return errno 0 (success) unless a real WASI call would need a
// meaningful error to stop the RTS from looping. Out-pointers get zeroed.
// `proc_exit` TRAPs rather than exiting so a runaway reducer surfaces as a wasm
// trap in the host instead of tearing down the process.
//
// Signatures MUST match phase0/module/wasi-imports.txt exactly (arity/types).

#include <stdint.h>

#define WASI_EXPORT(name) __attribute__((export_name(#name)))

// WASI errno values we hand back.
#define ERRNO_SUCCESS 0
#define ERRNO_BADF    8   // no preopens / bad file descriptor

static void zero_bytes(void *p, uint32_t n) {
    unsigned char *b = (unsigned char *)p;
    for (uint32_t i = 0; i < n; i++) b[i] = 0;
}

// --- process ---------------------------------------------------------------

// void proc_exit(i32) — must TRAP, never actually exit.
WASI_EXPORT(proc_exit)
void proc_exit(int32_t code) {
    (void)code;
    __builtin_trap();
}

// --- clock -----------------------------------------------------------------

// i32 clock_time_get(id, precision, out_time_ptr) — write 8 zero bytes.
WASI_EXPORT(clock_time_get)
int32_t clock_time_get(int32_t id, int64_t precision, int32_t out_time_ptr) {
    (void)id; (void)precision;
    zero_bytes((void *)(uintptr_t)out_time_ptr, 8);
    return ERRNO_SUCCESS;
}

// --- environment -----------------------------------------------------------

// i32 environ_sizes_get(count_out, bufsize_out) — write 0, 0.
WASI_EXPORT(environ_sizes_get)
int32_t environ_sizes_get(int32_t count_out, int32_t bufsize_out) {
    zero_bytes((void *)(uintptr_t)count_out, 4);
    zero_bytes((void *)(uintptr_t)bufsize_out, 4);
    return ERRNO_SUCCESS;
}

// i32 environ_get(environ, environ_buf) — nothing to write (count is 0).
WASI_EXPORT(environ_get)
int32_t environ_get(int32_t environ_, int32_t environ_buf) {
    (void)environ_; (void)environ_buf;
    return ERRNO_SUCCESS;
}

// --- file descriptors ------------------------------------------------------

WASI_EXPORT(fd_close)
int32_t fd_close(int32_t fd) {
    (void)fd;
    return ERRNO_SUCCESS;
}

// i32 fd_fdstat_get(fd, out) — zero the ~24-byte fdstat struct.
WASI_EXPORT(fd_fdstat_get)
int32_t fd_fdstat_get(int32_t fd, int32_t out) {
    (void)fd;
    zero_bytes((void *)(uintptr_t)out, 24);
    return ERRNO_SUCCESS;
}

WASI_EXPORT(fd_fdstat_set_flags)
int32_t fd_fdstat_set_flags(int32_t fd, int32_t flags) {
    (void)fd; (void)flags;
    return ERRNO_SUCCESS;
}

// i32 fd_filestat_get(fd, out) — zero the ~64-byte filestat struct.
WASI_EXPORT(fd_filestat_get)
int32_t fd_filestat_get(int32_t fd, int32_t out) {
    (void)fd;
    zero_bytes((void *)(uintptr_t)out, 64);
    return ERRNO_SUCCESS;
}

WASI_EXPORT(fd_filestat_set_size)
int32_t fd_filestat_set_size(int32_t fd, int64_t size) {
    (void)fd; (void)size;
    return ERRNO_SUCCESS;
}

// i32 fd_prestat_get(fd, out) — no preopens: report EBADF.
WASI_EXPORT(fd_prestat_get)
int32_t fd_prestat_get(int32_t fd, int32_t out) {
    (void)fd; (void)out;
    return ERRNO_BADF;
}

// i32 fd_prestat_dir_name(fd, path, path_len) — no preopens: report EBADF.
WASI_EXPORT(fd_prestat_dir_name)
int32_t fd_prestat_dir_name(int32_t fd, int32_t path, int32_t path_len) {
    (void)fd; (void)path; (void)path_len;
    return ERRNO_BADF;
}

// i32 fd_read(fd, iovs, iovs_len, nread_out) — read nothing (EOF).
WASI_EXPORT(fd_read)
int32_t fd_read(int32_t fd, int32_t iovs, int32_t iovs_len, int32_t nread_out) {
    (void)fd; (void)iovs; (void)iovs_len;
    zero_bytes((void *)(uintptr_t)nread_out, 4);
    return ERRNO_SUCCESS;
}

// i32 fd_seek(fd, offset, whence, newoffset_out) — write 0.
WASI_EXPORT(fd_seek)
int32_t fd_seek(int32_t fd, int64_t offset, int32_t whence, int32_t newoffset_out) {
    (void)fd; (void)offset; (void)whence;
    zero_bytes((void *)(uintptr_t)newoffset_out, 8);
    return ERRNO_SUCCESS;
}

// The iovec layout WASI uses: { u32 buf_ptr; u32 buf_len; }.
typedef struct {
    uint32_t buf;
    uint32_t buf_len;
} ciovec_t;

// i32 fd_write(fd, iovs, iovs_len, nwritten_out) — report every byte "written"
// (sum iovec lengths) so the RTS does not retry a partial write.
WASI_EXPORT(fd_write)
int32_t fd_write(int32_t fd, int32_t iovs, int32_t iovs_len, int32_t nwritten_out) {
    (void)fd;
    const ciovec_t *v = (const ciovec_t *)(uintptr_t)iovs;
    uint32_t total = 0;
    for (int32_t i = 0; i < iovs_len; i++) {
        total += v[i].buf_len;
    }
    *(uint32_t *)(uintptr_t)nwritten_out = total;
    return ERRNO_SUCCESS;
}

// --- paths (no filesystem) -------------------------------------------------

WASI_EXPORT(path_create_directory)
int32_t path_create_directory(int32_t fd, int32_t path, int32_t path_len) {
    (void)fd; (void)path; (void)path_len;
    return ERRNO_BADF;
}

WASI_EXPORT(path_filestat_get)
int32_t path_filestat_get(int32_t fd, int32_t flags, int32_t path,
                          int32_t path_len, int32_t out) {
    (void)fd; (void)flags; (void)path; (void)path_len; (void)out;
    return ERRNO_BADF;
}

WASI_EXPORT(path_open)
int32_t path_open(int32_t fd, int32_t dirflags, int32_t path, int32_t path_len,
                  int32_t oflags, int64_t fs_rights_base, int64_t fs_rights_inheriting,
                  int32_t fdflags, int32_t out) {
    (void)fd; (void)dirflags; (void)path; (void)path_len; (void)oflags;
    (void)fs_rights_base; (void)fs_rights_inheriting; (void)fdflags; (void)out;
    return ERRNO_BADF;
}

// --- polling ---------------------------------------------------------------

// i32 poll_oneoff(in, out, nsubscriptions, nevents_out) — write 0.
WASI_EXPORT(poll_oneoff)
int32_t poll_oneoff(int32_t in, int32_t out, int32_t nsubs, int32_t nevents_out) {
    (void)in; (void)out; (void)nsubs;
    zero_bytes((void *)(uintptr_t)nevents_out, 4);
    return ERRNO_SUCCESS;
}
