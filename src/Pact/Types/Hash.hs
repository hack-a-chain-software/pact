{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Pact.Types.Hash
  (
  -- Bytestring hashing
    Hash(..)
  , hash
  , hashToText
  , verifyHash
  , initialHash
  , hashLength
  , TypedHash(..)
  , toUntypedHash, fromUntypedHash
  , HashAlgo(..)
  , PactHash, pactHash, pactInitialHash, pactHashLength
  ) where


import Control.DeepSeq
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString, fromShort, toShort)
import Data.Hashable (Hashable(hashWithSalt))
import Data.Serialize (Serialize(..))
import Pact.Types.Pretty
import Pact.Types.Util
import Data.Aeson
import GHC.Generics
import Pact.Types.SizeOf
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Reflection
import Data.Proxy
import Test.QuickCheck
import Test.QuickCheck.Instances()

import qualified Pact.JSON.Encode as J
import Pact.JSON.Legacy.Hashable (LegacyHashable)

#if !defined(ghcjs_HOST_OS)

import qualified Data.ByteArray as ByteArray
import qualified Crypto.Hash as Crypto

#else

import Crypto.Hash.Blake2Native

#endif



-- | Untyped hash value, encoded with unpadded base64url.
-- Within Pact these are blake2b_256 but unvalidated as such,
-- so other hash values are kosher (such as an ETH sha256, etc).
newtype Hash = Hash { unHash :: ShortByteString }
  deriving (Eq, Ord, Generic, Hashable, Serialize, SizeOf, LegacyHashable)

instance Arbitrary Hash where
  -- TODO: add generators for other hash types
  arbitrary = pactHash <$> encodeUtf8 <$> resize 1000 arbitrary

instance Show Hash where
  show (Hash h) = show $ encodeBase64UrlUnpadded $ fromShort h

instance Pretty Hash where
  pretty = pretty . asString

instance AsString Hash where
  asString = hashToText

hashToText :: Hash -> Text
hashToText (Hash h) = toB64UrlUnpaddedText $ fromShort h

instance NFData Hash

instance J.Encode Hash where
  build = J.build . hashToText
  {-# INLINABLE build #-}

instance FromJSON Hash where
  parseJSON = withText "Hash" parseText
  {-# INLINE parseJSON #-}

instance FromJSONKey Hash where
    fromJSONKey = FromJSONKeyTextParser parseText
    {-# INLINABLE fromJSONKey #-}

instance ParseText Hash where
  parseText s = Hash . toShort <$> parseB64UrlUnpaddedText s
  {-# INLINE parseText #-}


-- | All supported hashes in Pact (although not necessarily GHCJS pact).
data HashAlgo =
  Blake2b_256 |
  SHA3_256
  deriving (Eq,Show,Ord,Bounded,Enum)

instance Reifies 'Blake2b_256 HashAlgo where
  reflect _ = Blake2b_256
instance Reifies 'SHA3_256 HashAlgo where
  reflect _ = SHA3_256

hashLength :: HashAlgo -> Int
hashLength Blake2b_256 = 32
hashLength SHA3_256 = 32

-- | Typed hash, to indicate algorithm
data TypedHash (h :: HashAlgo) where
  TypedHash :: !ShortByteString -> TypedHash h
  deriving (Eq, Ord, Generic)

instance Hashable (TypedHash h) where
  hashWithSalt a h = hashWithSalt a (toUntypedHash h)

instance Serialize (TypedHash h) where
  put = put . toUntypedHash
  get = fromUntypedHash <$> get

instance Show (TypedHash h) where
  show (TypedHash h) = show $ encodeBase64UrlUnpadded $ fromShort h

instance Pretty (TypedHash h) where
  pretty = pretty . asString

instance AsString (TypedHash h) where
  asString (TypedHash h) = decodeUtf8 (encodeBase64UrlUnpadded $ fromShort h)

instance NFData (TypedHash h)

instance J.Encode (TypedHash h) where
  build = J.build . typedHashToText
  {-# INLINABLE build #-}

instance FromJSON (TypedHash h) where
  parseJSON = withText "Hash" parseText
  {-# INLINE parseJSON #-}

instance ParseText (TypedHash h) where
  parseText s = TypedHash . toShort <$> parseB64UrlUnpaddedText s
  {-# INLINE parseText #-}

instance Arbitrary (TypedHash a) where
  arbitrary = fromUntypedHash <$> arbitrary

typedHashToText :: TypedHash h -> Text
typedHashToText (TypedHash h) = toB64UrlUnpaddedText $ fromShort h

toUntypedHash :: TypedHash h -> Hash
toUntypedHash (TypedHash h) = Hash h

fromUntypedHash :: Hash -> TypedHash h
fromUntypedHash (Hash h) = TypedHash h

type PactHash = TypedHash 'Blake2b_256

pactHash :: ByteString -> Hash
pactHash = toUntypedHash . (hash :: ByteString -> PactHash)

pactInitialHash :: Hash
pactInitialHash = toUntypedHash $ (initialHash :: PactHash)

pactHashLength :: Int
pactHashLength = hashLength Blake2b_256


#if !defined(ghcjs_HOST_OS)

hash :: forall h . Reifies h HashAlgo => ByteString -> TypedHash h
hash = TypedHash . toShort . go
  where
    algo = reflect (Proxy :: Proxy h)
    go = case algo of
      Blake2b_256 -> ByteArray.convert . Crypto.hashWith Crypto.Blake2b_256
      SHA3_256 -> ByteArray.convert . Crypto.hashWith Crypto.SHA3_256
{-# INLINE hash #-}

#else

hash :: forall h . Reifies h HashAlgo => ByteString -> TypedHash h
hash bs = TypedHash (toShort go)
  where
    algo = reflect (Proxy :: Proxy h)
    go = case algo of
      Blake2b_256 -> case blake2b (hashLength algo) mempty bs of
        Left _ -> error "hashing failed"
        Right h -> h
      _ -> error $ "Unsupported hash algo: " ++ show algo

#endif
verifyHash :: Reifies h HashAlgo => TypedHash h -> ByteString -> Either String Hash
verifyHash h b = if hashed == h
  then Right (toUntypedHash h)
  else Left $ "Hash Mismatch, received " ++ renderCompactString h ++
              " but our hashing resulted in " ++ renderCompactString hashed
  where hashed = hash b
{-# INLINE verifyHash #-}


initialHash :: Reifies h HashAlgo => TypedHash h
initialHash = hash mempty
