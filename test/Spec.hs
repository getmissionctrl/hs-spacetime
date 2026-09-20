module Main (main) where

import qualified SpacetimeDB.BSATN.DecoderSpec
import qualified SpacetimeDB.BSATN.EncoderSpec
import qualified SpacetimeDB.BSATN.RoundtripSpec
import qualified SpacetimeDB.BSATN.TypesSpec
import qualified SpacetimeDB.Client.ConnectionSpec
import qualified SpacetimeDB.Client.TypedSpec
import qualified SpacetimeDB.Client.DispatchSpec
import qualified SpacetimeDB.Client.EndpointSpec
import qualified SpacetimeDB.Client.StateSpec
import qualified SpacetimeDB.Codegen.GeneratedRoundtripSpec
import qualified SpacetimeDB.Codegen.GoldenSpec
import qualified SpacetimeDB.Codegen.SchemaSpec
import qualified SpacetimeDB.IntegrationCheck
import qualified SpacetimeDB.Protocol.FrameSpec
import qualified SpacetimeDB.Protocol.MessagesSpec
import qualified SpacetimeDB.Protocol.RowListSpec
import qualified SpacetimeDB.Server.DispatchSpec
import qualified SpacetimeDB.Server.SchemaSpec
import qualified SpacetimeDB.Server.SpacetimeTypeSpec
import qualified SpacetimeDB.Server.TableSpec
import qualified SpacetimeDB.Server.ModuleSpec
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, hspec)

main :: IO ()
main = do
  integration <- lookupEnv "SPACETIMEDB_INTEGRATION"
  hspec $ do
    hermetic
    case integration of
      Just "1" -> SpacetimeDB.IntegrationCheck.spec
      _ -> pure ()

hermetic :: Spec
hermetic = do
  describe "SpacetimeDB.BSATN.Decoder" SpacetimeDB.BSATN.DecoderSpec.spec
  describe "SpacetimeDB.BSATN.Encoder" SpacetimeDB.BSATN.EncoderSpec.spec
  describe "SpacetimeDB.BSATN.Roundtrip" SpacetimeDB.BSATN.RoundtripSpec.spec
  describe "SpacetimeDB.BSATN.Types" SpacetimeDB.BSATN.TypesSpec.spec
  describe "SpacetimeDB.Protocol.RowList" SpacetimeDB.Protocol.RowListSpec.spec
  describe "SpacetimeDB.Protocol.Messages" SpacetimeDB.Protocol.MessagesSpec.spec
  describe "SpacetimeDB.Protocol.Frame" SpacetimeDB.Protocol.FrameSpec.spec
  describe "SpacetimeDB.Client.Endpoint" SpacetimeDB.Client.EndpointSpec.spec
  describe "SpacetimeDB.Client.State" SpacetimeDB.Client.StateSpec.spec
  describe "SpacetimeDB.Client.Dispatch" SpacetimeDB.Client.DispatchSpec.spec
  describe "SpacetimeDB.Client.Connection" SpacetimeDB.Client.ConnectionSpec.spec
  describe "SpacetimeDB.Client.Typed" SpacetimeDB.Client.TypedSpec.spec
  describe "SpacetimeDB.Codegen.Schema" SpacetimeDB.Codegen.SchemaSpec.spec
  describe "SpacetimeDB.Codegen.Golden" SpacetimeDB.Codegen.GoldenSpec.spec
  describe "SpacetimeDB.Codegen.GeneratedRoundtrip" SpacetimeDB.Codegen.GeneratedRoundtripSpec.spec
  describe "SpacetimeDB.Server.Dispatch" SpacetimeDB.Server.DispatchSpec.spec
  describe "SpacetimeDB.Server.Schema" SpacetimeDB.Server.SchemaSpec.spec
  describe "SpacetimeDB.Server.SpacetimeType" SpacetimeDB.Server.SpacetimeTypeSpec.spec
  describe "SpacetimeDB.Server.Table" SpacetimeDB.Server.TableSpec.spec
  describe "SpacetimeDB.Server.Module" SpacetimeDB.Server.ModuleSpec.spec
