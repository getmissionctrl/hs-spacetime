use spacetimedb::{reducer, table, ConnectionId, Identity, ReducerContext, Timestamp};

#[table(accessor = probe, public)]
pub struct Probe {
    #[primary_key]
    pub id: Identity,
    pub ts: Timestamp,
    pub conn: ConnectionId,
    pub note: Option<String>,
}

#[reducer(init)]
pub fn init(_ctx: &ReducerContext) {}
