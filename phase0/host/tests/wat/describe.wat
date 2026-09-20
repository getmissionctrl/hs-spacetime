(module
  (import "spacetime_10.0" "bytes_sink_write"
    (func $sink (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 100) "\de\ad\be\ef")
  (data (i32.const 200) "\04\00\00\00")   ;; len = 4
  (func (export "_initialize"))
  (func (export "__describe_module__") (param $sink i32)
    (drop (call $sink (local.get $sink) (i32.const 100) (i32.const 200)))))
