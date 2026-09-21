module Main (main) where

import Control.Monad (void)
import Data.Function ((&))
import qualified Data.Text as T
import System.Environment (lookupEnv)

import Brick (customMain)
import Brick.BChan (newBChan, writeBChan)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)

import Chat (App (..), SendMessageArgs (..), SetNameArgs (..), app)
import Chat.Tui.Model (InputAction (..), emptyChat)
import Chat.Tui.Ui (UiEvent (..), UiState (..), chatApp)
import SpacetimeDB.Client
import SpacetimeDB.Client.Typed (callTyped, subscribeTable)
import SpacetimeDB.Client.Types (formatEvent)
import SpacetimeDB.Protocol.Messages (Compression (..))

main :: IO ()
main = do
  host <- T.pack . maybe "127.0.0.1" id <$> lookupEnv "STDB_HOST"
  db <- T.pack . maybe "quickstart-chat" id <$> lookupEnv "STDB_DB"
  port <- maybe 3000 read <$> lookupEnv "STDB_PORT"
  chan <- newBChan 64

  let cfg =
        builder host port db
          & withCompression CompNone
          & withReconnect (Reconnect 200 2000 Nothing)
          & subscribeTable app.user (subSql "user") (\ins del -> writeBChan chan (EvUsers ins del))
          & subscribeTable app.message (subSql "message") (\ins del -> writeBChan chan (EvMessages ins del))
          & onEvent (\e -> writeBChan chan (EvStatus (formatEvent e)))

  started <- start cfg
  case started of
    Left err -> putStrLn ("failed to connect: " <> T.unpack err)
    Right client -> do
      let send action = case action of
            SendMsg t -> callTyped client app.sendMessage (SendMessageArgs t) (const (pure ()))
            SetNameCmd n -> callTyped client app.setName (SetNameArgs n) (const (pure ()))
            NoOp -> pure ()
          initial = UiState {uiChat = emptyChat, uiSend = send}
      vty0 <- mkVty defaultConfig
      void (customMain vty0 (mkVty defaultConfig) (Just chan) chatApp initial)
      stop client
 where
  subSql t = "SELECT * FROM " <> t
