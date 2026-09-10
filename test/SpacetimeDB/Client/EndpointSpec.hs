module SpacetimeDB.Client.EndpointSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client.Endpoint
import SpacetimeDB.Protocol.Messages (Compression (..))

spec :: Spec
spec = do
  let base = HostPort (T.pack "localhost") 3000 False
  it "assembles the subscribe path with Brotli default" $
    subscribeUrl (EndpointConfig base (T.pack "mydb") CompBrotli Nothing)
      `shouldBe` T.pack "http://localhost:3000/v1/database/mydb/subscribe?compression=Brotli"
  it "adds confirmed when set" $
    subscribeUrl (EndpointConfig base (T.pack "mydb") CompGzip (Just False))
      `shouldBe` T.pack "http://localhost:3000/v1/database/mydb/subscribe?compression=Gzip&confirmed=false"
  it "secure host uses https and wss maps to https" $
    subscribeUrl (EndpointConfig (HostPort (T.pack "h") 443 True) (T.pack "d") CompNone Nothing)
      `shouldBe` T.pack "https://h:443/v1/database/d/subscribe?compression=None"
  it "base URI trims trailing slash and rewrites ws://" $
    subscribeUrl (EndpointConfig (BaseUri (T.pack "ws://proxy/stdb/")) (T.pack "d") CompBrotli Nothing)
      `shouldBe` T.pack "http://proxy/stdb/v1/database/d/subscribe?compression=Brotli"
