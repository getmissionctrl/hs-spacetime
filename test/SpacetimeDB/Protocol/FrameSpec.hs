{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Protocol.FrameSpec (spec) where

import qualified Codec.Compression.GZip as GZip
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import SpacetimeDB.BSATN.Types
import SpacetimeDB.Protocol.Frame
import SpacetimeDB.Protocol.Messages
import Test.Hspec

identityOf :: Integer -> Identity
identityOf = identityFromInteger

connOf :: Integer -> ConnectionId
connOf = connectionIdFromInteger

txt :: String -> Text
txt = T.pack

-- UTF-8 bytes of an ASCII string.
ascii :: String -> [Word8]
ascii = map (fromIntegral . fromEnum)

-- A minimal InitialConnection payload: tag 0, identity(32)=1, conn(16)=0, token "" (u32 0)
initialPayload :: BS.ByteString
initialPayload = BS.pack ([0] ++ (1 : replicate 31 0) ++ replicate 16 0 ++ [0, 0, 0, 0])

spec :: Spec
spec = do
  it "tag 0 = uncompressed" $
    decodeFrame (BS.cons 0 initialPayload)
      `shouldBe` Right (InitialConnection (identityOf 1) (connOf 0) (txt ""))
  it "tag 2 = gzip" $ do
    let gz = BL.toStrict (GZip.compress (BL.fromStrict initialPayload))
    decodeFrame (BS.cons 2 gz)
      `shouldBe` Right (InitialConnection (identityOf 1) (connOf 0) (txt ""))
  it "empty frame errors" $ decodeFrame BS.empty `shouldBe` Left EmptyFrame
  it "unknown compression tag errors" $
    decodeFrame (BS.pack [9, 0, 0]) `shouldBe` Left (UnsupportedCompression 9)

  describe "server message fixtures (compression tag 0)" $ do
    it "SubscribeApplied with a FixedSize row list" $
      decodeFrame
        ( BS.pack $
            [0] -- compression: none
              ++ [1] -- server tag: SubscribeApplied
              ++ [5, 0, 0, 0] -- request_id
              ++ [7, 0, 0, 0] -- query_set_id
              ++ [1, 0, 0, 0] -- QueryRows: 1 table
              ++ [6, 0, 0, 0]
              ++ ascii "widget" -- table name
              ++ [0, 2, 0] -- row hint: FixedSize 2
              ++ [4, 0, 0, 0, 1, 2, 3, 4] -- rows_data
        )
        `shouldBe` Right
          (SubscribeApplied 5 7 (QueryRows [SingleTableRows (txt "widget") [BS.pack [1, 2], BS.pack [3, 4]]]))
    it "TransactionUpdate with PersistentTable and EventTable" $
      decodeFrame
        ( BS.pack $
            [0]
              ++ [4] -- server tag: TransactionUpdate
              ++ [1, 0, 0, 0] -- 1 QuerySetUpdate
              ++ [1, 0, 0, 0] -- query_set_id = 1
              ++ [2, 0, 0, 0] -- 2 TableUpdates
              -- TableUpdate 1: widget, one PersistentTable inserts=[[1]] deletes=[]
              ++ [6, 0, 0, 0]
              ++ ascii "widget"
              ++ [1, 0, 0, 0] -- 1 TableUpdateRows
              ++ [0] -- PersistentTable
              ++ [0, 1, 0]
              ++ [1, 0, 0, 0, 1] -- inserts rowlist: FixedSize 1, [1]
              ++ [0, 1, 0]
              ++ [0, 0, 0, 0] -- deletes rowlist: FixedSize 1, empty
              -- TableUpdate 2: event_tbl, one EventTable [[2]]
              ++ [9, 0, 0, 0]
              ++ ascii "event_tbl"
              ++ [1, 0, 0, 0] -- 1 TableUpdateRows
              ++ [1] -- EventTable
              ++ [0, 1, 0]
              ++ [1, 0, 0, 0, 2]
        )
        `shouldBe` Right
          ( TransactionUpdate
              [ QuerySetUpdate
                  1
                  [ TableUpdate (txt "widget") [PersistentTable [BS.pack [1]] []]
                  , TableUpdate (txt "event_tbl") [EventTable [BS.pack [2]]]
                  ]
              ]
          )
    it "ReducerResult Ok with empty ret_value" $
      decodeFrame (BS.pack ([0, 6] ++ [3, 0, 0, 0] ++ replicate 8 0 ++ [0, 0, 0, 0, 0, 0, 0, 0, 0]))
        `shouldBe` Right (ReducerResult 3 (Timestamp 0) (OutcomeOk BS.empty []))
    it "ReducerResult OkEmpty" $
      decodeFrame (BS.pack ([0, 6] ++ [3, 0, 0, 0] ++ replicate 8 0 ++ [1]))
        `shouldBe` Right (ReducerResult 3 (Timestamp 0) OutcomeOkEmpty)
    it "ReducerResult Err" $
      decodeFrame (BS.pack ([0, 6] ++ [3, 0, 0, 0] ++ replicate 8 0 ++ [2, 1, 0, 0, 0, 9]))
        `shouldBe` Right (ReducerResult 3 (Timestamp 0) (OutcomeErr (BS.pack [9])))
    it "ReducerResult InternalError" $
      decodeFrame (BS.pack ([0, 6] ++ [3, 0, 0, 0] ++ replicate 8 0 ++ [3, 2, 0, 0, 0] ++ ascii "no"))
        `shouldBe` Right (ReducerResult 3 (Timestamp 0) (OutcomeInternalError (txt "no")))
    it "ProcedureResult pins the id-last order" $
      decodeFrame
        ( BS.pack $
            [0, 7]
              ++ [0, 1, 0, 0, 0, 7] -- ProcReturned [7]
              ++ replicate 8 0 -- timestamp
              ++ replicate 8 0 -- time_duration
              ++ [9, 0, 0, 0] -- request_id
        )
        `shouldBe` Right (ProcedureResult (ProcReturned (BS.pack [7])) (Timestamp 0) (TimeDuration 0) 9)
    it "OneOffQueryResult ok (empty rows)" $
      decodeFrame (BS.pack [0, 5, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        `shouldBe` Right (OneOffQueryResult 2 (Right (QueryRows [])))
    it "OneOffQueryResult err" $
      decodeFrame (BS.pack ([0, 5, 2, 0, 0, 0, 1, 4, 0, 0, 0] ++ ascii "boom"))
        `shouldBe` Right (OneOffQueryResult 2 (Left (txt "boom")))
    it "unknown server tag becomes Unhandled" $
      decodeFrame (BS.pack [0, 99]) `shouldBe` Right (Unhandled 99)
