module SpacetimeDB.Client.StateSpec (spec) where

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client.State

spec :: Spec
spec = do
  describe "call correlation" $ do
    it "allocateCall hands out increasing ids and records pending" $ do
      let s0 = emptyState
          (s1, r1) = allocateCall s0 (T.pack "add")
          (s2, r2) = allocateCall s1 (T.pack "add")
      (r1, r2) `shouldBe` (1, 2)
      M.keys (pendingCalls s2) `shouldBe` [1, 2]
    it "takePending removes and returns the name" $ do
      let (s1, rid) = allocateCall emptyState (T.pack "add")
          (s2, nm) = takePending s1 rid
      (nm, M.member rid (pendingCalls s2)) `shouldBe` (Just (T.pack "add"), False)
    it "takePending on unknown id yields Nothing and leaves the map unchanged" $ do
      let (s1, nm) = takePending emptyState 99
      (nm, pendingCalls s1) `shouldBe` (Nothing, pendingCalls emptyState)
    it "drainPending clears everything" $ do
      let (s1, _) = allocateCall emptyState (T.pack "a")
          (s2, _) = allocateCall s1 (T.pack "b")
          (s3, drained) = drainPending s2
      (map fst drained, M.null (pendingCalls s3)) `shouldBe` ([1, 2], True)
  describe "subscription ids" $ do
    it "start at 1 and increase; forget never lowers next" $ do
      let (s1, a) = allocateSub emptyState (T.pack "q1") Nothing
          (s2, b) = allocateSub s1 (T.pack "q2") Nothing
          s3 = forgetSub s2 (subQuerySetId a)
          (_, c) = allocateSub s3 (T.pack "q3") Nothing
      map subQuerySetId [a, b, c] `shouldBe` [1, 2, 3]
    it "subForId finds live subs and misses forgotten ones" $ do
      let (s1, a) = allocateSub emptyState (T.pack "q1") Nothing
          s2 = forgetSub s1 (subQuerySetId a)
      (subForId s1 1, subForId s2 1) `shouldBe` (Just a, Nothing)
