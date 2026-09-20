use spacetimedb::{reducer, table, ReducerContext, Table};

#[table(accessor = person, public)]
pub struct Person {
    pub name: String,
}

#[reducer]
pub fn add(ctx: &ReducerContext, name: String) {
    ctx.db.person().insert(Person { name });
}
