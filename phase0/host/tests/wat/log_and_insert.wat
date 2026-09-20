(module
  (import "spacetime_10.0" "console_log"
    (func $log (param i32 i32 i32 i32 i32 i32 i32 i32)))
  (import "spacetime_10.0" "datastore_insert_bsatn"
    (func $insert (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "AAA")
  (data (i32.const 200) "\03\00\00\00")   ;; row length = 3, LE u32
  (data (i32.const 300) "hi")
  (func (export "_initialize"))
  (func (export "run") (result i32)
    (call $log (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)
               (i32.const 0) (i32.const 0) (i32.const 300) (i32.const 2))
    (call $insert (i32.const 7) (i32.const 100) (i32.const 200))))
