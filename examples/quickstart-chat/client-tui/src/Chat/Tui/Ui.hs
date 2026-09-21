module Chat.Tui.Ui
  ( Name (..)
  , UiEvent (..)
  , UiState (..)
  , applyEvent
  , chatApp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder)
import qualified Graphics.Vty as V

import Chat (Message, User)
import Chat.Tui.Model
import SpacetimeDB.Server.HKD (View (Value))

data Name = MsgViewport
  deriving (Eq, Ord, Show)

-- | Events pushed onto the Brick channel by the SDK wiring in Main.
data UiEvent
  = EvUsers [User 'Value] [User 'Value] -- inserts, deletes
  | EvMessages [Message 'Value] [Message 'Value]
  | EvStatus Text

data UiState = UiState
  { uiChat :: !ChatState
  , uiSend :: !(InputAction -> IO ()) -- injected by Main; closes over the Client
  }

applyEvent :: UiEvent -> ChatState -> ChatState
applyEvent ev s = case ev of
  EvUsers ins del -> removeUsers del (upsertUsers ins s)
  EvMessages ins _del -> addMessages ins s
  EvStatus t -> s {csStatus = t}

chatApp :: App UiState UiEvent Name
chatApp =
  App
    { appDraw = draw
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handle
    , appStartEvent = pure ()
    , appAttrMap = const (attrMap V.defAttr [])
    }

draw :: UiState -> [Widget Name]
draw st =
  [ vBox
      [ borderWithLabel (str "quickstart-chat (Haskell TUI)") (messages st)
      , hBorder
      , padRight Max (txt ("status: " <> st.uiChat.csStatus))
      , txt ("> " <> st.uiChat.csInput)
      ]
  ]

messages :: UiState -> Widget Name
messages st =
  viewport MsgViewport Vertical $
    vBox [txt (renderMessage st.uiChat m) | m <- st.uiChat.csMessages]

handle :: BrickEvent Name UiEvent -> EventM Name UiState ()
handle = \case
  AppEvent ev -> modify (\s -> s {uiChat = applyEvent ev s.uiChat})
  VtyEvent (V.EvKey V.KEnter []) -> do
    s <- get
    let action = parseInput s.uiChat.csInput
    liftIO (s.uiSend action)
    modify (\s' -> s' {uiChat = s'.uiChat {csInput = ""}})
  VtyEvent (V.EvKey (V.KChar c) []) ->
    modify (\s -> s {uiChat = s.uiChat {csInput = s.uiChat.csInput `T.snoc` c}})
  VtyEvent (V.EvKey V.KBS []) ->
    modify (\s -> s {uiChat = s.uiChat {csInput = dropLast s.uiChat.csInput}})
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl]) -> halt
  _ -> pure ()
 where
  dropLast t = if T.null t then t else T.init t
