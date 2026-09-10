{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Protocol.MessagesSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Protocol.Messages
import Test.Hspec

spec :: Spec
spec = do
  describe "reducerOutcome" $ do
    it "Ok with empty ret_value + no updates" $
      -- tag 0; ret_value bytes: u32 len 0; transaction_update: Array len 0
      runExact decodeReducerOutcome (BS.pack [0, 0, 0, 0, 0, 0, 0, 0, 0])
        `shouldBe` Right (OutcomeOk BS.empty [])
    it "OkEmpty is tag 1, zero payload" $
      runExact decodeReducerOutcome (BS.pack [1]) `shouldBe` Right OutcomeOkEmpty
    it "Err carries bytes" $
      runExact decodeReducerOutcome (BS.pack [2, 1, 0, 0, 0, 9]) `shouldBe` Right (OutcomeErr (BS.pack [9]))
  describe "client encoders (byte-exact)" $ do
    it "Subscribe matches the documented hex" $
      let bs = runEncoder encodeClientMessage (Subscribe 1 1 [T.pack "SELECT * FROM widget"])
       in BS.unpack bs
            `shouldBe` [0x00, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 20, 0, 0, 0]
              ++ map (fromIntegral . fromEnum) "SELECT * FROM widget"
    it "CallReducer with empty args ends in 00 00 00 00" $
      let bs = runEncoder encodeClientMessage (CallReducer 1 0 (T.pack "x") BS.empty)
       in drop (BS.length bs - 4) (BS.unpack bs) `shouldBe` [0, 0, 0, 0]
