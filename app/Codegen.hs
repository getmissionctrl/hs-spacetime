module Main (main) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import SpacetimeDB.Codegen
import SpacetimeDB.Codegen.Schema
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  let skip = "--skip" `elem` args
      outs = filter (/= "--skip") args
  raw <- BL.getContents
  case parseModule raw of
    Left e -> hPutStrLn stderr ("schema parse error: " ++ e) >> exitFailure
    Right m -> case generate skip (computeNamedDropped m) of
      Left errs -> mapM_ (hPutStrLn stderr . T.unpack) errs >> exitFailure
      Right src -> case outs of
        (f : _) -> TIO.writeFile f src
        [] -> TIO.putStr src
