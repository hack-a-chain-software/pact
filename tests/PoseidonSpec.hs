{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}

module PoseidonSpec (spec) where

import Test.Hspec
import Crypto.Hash.PoseidonNative

spec :: Spec
spec = describe "poseidon" $ do
  describe "poseidon-hash" $ do
    it "computes the poseidon hash for two integers" $ do
      poseidon [1, 2] `shouldBe` 12717992376338182279477285556390228582603857817939167998284243525425604090033
      poseidon [999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999, 88888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888] `shouldBe` 1069652563792426660145833190237336045845917811967528486535167837537743676741
