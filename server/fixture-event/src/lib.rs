use spacetimedb::{reducer, table, ReducerContext, Table};

#[table(accessor = event, public)]
pub struct Event {
    pub who: String,
    pub at: i64,
}

#[reducer]
pub fn record(ctx: &ReducerContext, note: String) {
    ctx.db.event().insert(Event { who: note, at: ctx.timestamp.to_micros_since_unix_epoch() });
}

#[reducer]
pub fn record_n(ctx: &ReducerContext, count: u32) {
    ctx.db.event().insert(Event { who: "n".into(), at: count as i64 });
}

#[reducer]
pub fn delete_all(ctx: &ReducerContext) {
    for e in ctx.db.event().iter() { ctx.db.event().delete(e); }
}
