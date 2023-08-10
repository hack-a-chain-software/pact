{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}

module ModularArithmeticSpec (spec) where

import Test.Hspec
import Pact.Native.ModularArithmetic

spec :: Spec
spec = describe "modular arithmetic" $ do
  describe "egcd" $ do
    it "return the extended greatest common divisors of two integers" $ do
      egcd 3 26 `shouldBe` (1, 9, -1)
      egcd 10 11 `shouldBe` (1, -1, 1)
      egcd 5865413254 646787313212 `shouldBe` (2, -136892601753, 1241415322)
      egcd 2094759673937393 7542689557689386379 `shouldBe` (1, -3477782688621484921, 965851620316926)
  describe "keccak256-bs" $ do
    it "computes the keccak256 hash of a given size and number, and returns the result as a integer" $ do
      keccak256bs 32 2343218353 `shouldBe` 70693813391479751919291652168721459418096488414145790121500220848916020780076
      keccak256bs 64 4637928374822348932 `shouldBe` 31913459109244394690918113775821069766218386171344476352830309015864679314372
      keccak256bs 128 86734239273823482392374839238192 `shouldBe` 73259886156781299012365827306350972332057929114712718446011773447329916800282
      keccak256bs 256 2939802230983298498274024970323894828329382938283938293283 `shouldBe` 112308053996183008364732118192044491261660825982790234118109580320965363105885
  describe "poseidon-hash" $ do
    it "computes the poseidon hash for a given list of integers" $ do
      poseidon [1, 2] `shouldBe` 12717992376338182279477285556390228582603857817939167998284243525425604090033
      poseidon [999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999, 88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888] `shouldBe` 1069652563792426660145833190237336045845917811967528486535167837537743676741
