{- | The quickstart-chat example SpacetimeDB module.

The real @App@ record, tables (@user@, @message@), reducers and handlers are
landed in later tasks; for now this is a stub so the scaffolding compiles and
the table test fails for the right reason.
-}
module Chat (chatModule) where

import SpacetimeDB.Server (ModuleDef)

-- | The derived chat module. Not implemented yet.
chatModule :: ModuleDef
chatModule = error "not implemented"
