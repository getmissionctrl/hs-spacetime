use spacetimedb::{reducer, table, ReducerContext, Table};

#[table(name = widget, public)]
pub struct Widget {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    pub name: String,
    pub quantity: u32,
}

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.widget().insert(Widget {
        id: 0,
        name: "seed".into(),
        quantity: 1,
    });
}

#[reducer]
pub fn add_widget(ctx: &ReducerContext, name: String, quantity: u32) {
    ctx.db.widget().insert(Widget {
        id: 0,
        name,
        quantity,
    });
}
