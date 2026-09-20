use anyhow::Result;
use phase0_host::Host;

fn main() -> Result<()> {
    let path = std::env::args().nth(1).expect("usage: phase0-host <module.wasm>");
    let wasm = std::fs::read(&path)?;
    let mut host = Host::new(true)?;
    let _instance = host.instantiate(&wasm)?;
    println!("instantiated {path} OK");
    Ok(())
}
