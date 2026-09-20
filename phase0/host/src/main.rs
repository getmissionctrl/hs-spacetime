use anyhow::Result;
use phase0_host::Host;
use std::io::Write;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let first = args.next().expect("usage: phase0-host [--describe] <module.wasm>");
    let (describe, path) = if first == "--describe" {
        (true, args.next().expect("module path"))
    } else {
        (false, first)
    };
    let wasm = std::fs::read(&path)?;
    let mut host = Host::new(true)?;
    host.add_spacetime_stubs()?;
    let instance = if describe {
        host.instantiate_allowing_unknown(&wasm)?
    } else {
        host.instantiate(&wasm)?
    };
    host.initialize(&instance)?;
    if describe {
        let bytes = host.describe(&instance)?;
        std::io::stdout().write_all(&bytes)?;
    } else {
        eprintln!("instantiated {path} OK");
    }
    Ok(())
}
