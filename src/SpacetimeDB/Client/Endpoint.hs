{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Client.Endpoint
  ( Base (..)
  , EndpointConfig (..)
  , subscribeUrl
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import SpacetimeDB.Protocol.Messages (Compression (..))

data Base
  = HostPort Text Int Bool -- host, port, secure
  | BaseUri Text
  deriving (Eq, Show)

data EndpointConfig = EndpointConfig
  { epBase :: Base
  , epDatabase :: Text
  , epCompression :: Compression
  , epConfirmed :: Maybe Bool
  }
  deriving (Eq, Show)

subscribeUrl :: EndpointConfig -> Text
subscribeUrl (EndpointConfig base db comp confirmed) =
  root <> "/v1/database/" <> db <> "/subscribe?compression=" <> compName comp <> confirmedParam
  where
    root = case base of
      HostPort h p secure ->
        (if secure then "https://" else "http://") <> h <> ":" <> T.pack (show p)
      BaseUri u -> rewrite (T.dropWhileEnd (== '/') u)
    rewrite u
      | "wss://" `T.isPrefixOf` u = "https://" <> T.drop 6 u
      | "ws://" `T.isPrefixOf` u = "http://" <> T.drop 5 u
      | otherwise = u
    compName CompNone = "None"
    compName CompBrotli = "Brotli"
    compName CompGzip = "Gzip"
    confirmedParam = case confirmed of
      Nothing -> ""
      Just True -> "&confirmed=true"
      Just False -> "&confirmed=false"
