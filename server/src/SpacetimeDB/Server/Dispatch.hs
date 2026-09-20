{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Server.Dispatch
  ( mkContext
  , dispatchReducer
  , describeBytes
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Types (Timestamp (..), connectionIdFromInteger, identityFromInteger)
import SpacetimeDB.Server.Internal

-- | Assemble a ReducerContext from the raw ABI words.
mkContext
  :: Word64
  -> Word64
  -> Word64
  -> Word64 -- sender (Identity, 4 LE words)
  -> Word64
  -> Word64 -- connection id (2 LE words)
  -> Word64 -- timestamp micros
  -> ReducerContext
mkContext s0 s1 s2 s3 c0 c1 ts =
  ReducerContext
    { sender = identityFromInteger (le4 s0 s1 s2 s3)
    , connectionId =
        if c0 == 0 && c1 == 0
          then Nothing
          else Just (connectionIdFromInteger (le2 c0 c1))
    , timestamp = Timestamp (fromIntegral ts)
    }
 where
  le2 a b = toInteger a .|. (toInteger b `shiftL` 64)
  le4 a b c d =
    toInteger a
      .|. (toInteger b `shiftL` 64)
      .|. (toInteger c `shiftL` 128)
      .|. (toInteger d `shiftL` 192)

-- | Look up a reducer by ABI id, decode its args, run its handler.
dispatchReducer :: ModuleDef -> Int -> ReducerContext -> ByteString -> Backend -> IO (Either Text ())
dispatchReducer md rid ctx args be =
  case drop rid md.reducers of
    [] -> pure (Left ("unknown reducer id " <> T.pack (show rid)))
    (BoundReducer dec h : _) -> case runExact dec args of
      Left err -> pure (Left ("arg decode failed: " <> T.pack (show err)))
      Right a -> (h a).unReducerM ctx be

describeBytes :: ModuleDef -> ByteString
describeBytes md = md.schemaBytes
