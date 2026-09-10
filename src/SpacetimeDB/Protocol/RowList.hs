module SpacetimeDB.Protocol.RowList
  ( RowSizeHint (..)
  , splitRows
  , decodeRowList
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word16, Word64)
import SpacetimeDB.BSATN.Decoder

data RowSizeHint = FixedSize Word16 | RowOffsets [Word64]
  deriving (Eq, Show)

splitRows :: RowSizeHint -> ByteString -> [ByteString]
splitRows (FixedSize n) d
  | n == 0 || BS.null d = []
  | otherwise = go d
 where
  sz = fromIntegral n
  go bs
    | BS.null bs = []
    | otherwise = let (h, t) = BS.splitAt sz bs in h : go t
splitRows (RowOffsets []) _ = []
splitRows (RowOffsets offs) d = zipWith slice starts ends
 where
  starts = map fromIntegral offs
  ends = drop 1 starts ++ [BS.length d]
  slice s e = BS.take (e - s) (BS.drop s d)

decodeRowSizeHint :: Decoder RowSizeHint
decodeRowSizeHint = sumD $ \t -> case t of
  0 -> Right (FixedSize <$> u16)
  1 -> Right (RowOffsets <$> list u64)
  _ -> Left (UnknownVariant t)

-- | BsatnRowList = { size_hint, rows_data: Bytes } -> split rows.
decodeRowList :: Decoder [ByteString]
decodeRowList = do
  hint <- decodeRowSizeHint
  d <- bytes
  pure (splitRows hint d)
