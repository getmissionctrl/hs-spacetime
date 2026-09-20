#pragma once
#include <stdint.h>
#include <stddef.h>

#define ST_IMPORT(name) \
  __attribute__((import_module("spacetime_10.0"), import_name(name)))

// Returns u16 errno (0 = ok). out receives the table id (LE u32).
ST_IMPORT("table_id_from_name")
uint16_t st_table_id_from_name(const uint8_t *name, size_t name_len, uint32_t *out);

// Returns u16 errno. row_len points at length (in/out); row bytes at row.
ST_IMPORT("datastore_insert_bsatn")
uint16_t st_datastore_insert_bsatn(uint32_t table_id, uint8_t *row, size_t *row_len);

// Returns i16: 0 ok, -1 exhausted, >0 errno. buf_len is capacity in / written out.
ST_IMPORT("bytes_source_read")
int16_t st_bytes_source_read(uint32_t source, uint8_t *buf, size_t *buf_len);

// Returns u16 errno. buf_len is len in / bytes-consumed out.
ST_IMPORT("bytes_sink_write")
uint16_t st_bytes_sink_write(uint32_t sink, const uint8_t *buf, size_t *buf_len);

ST_IMPORT("console_log")
void st_console_log(uint8_t level, const uint8_t *target, size_t target_len,
                    const uint8_t *filename, size_t filename_len, uint32_t line,
                    const uint8_t *message, size_t message_len);
