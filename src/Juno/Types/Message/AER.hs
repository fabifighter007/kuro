{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Message.AER
  ( AppendEntriesResponse(..), aerTerm, aerNodeId, aerSuccess, aerConvinced
  , aerIndex, aerHash, aerProvenance
  , AERWire(..)
  , aerDecodeNoVerify, aerReverify
  ) where

import Control.Lens

import Data.ByteString (ByteString)
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import GHC.Generics

import Juno.Types.Base
import Juno.Types.Config
import Juno.Types.Message.Signed

data AppendEntriesResponse = AppendEntriesResponse
  { _aerTerm       :: !Term
  , _aerNodeId     :: !NodeId
  , _aerSuccess    :: !Bool
  , _aerConvinced  :: !Bool
  , _aerIndex      :: !LogIndex
  , _aerHash       :: !ByteString
  , _aerProvenance :: !Provenance
  }
  deriving (Show, Generic, Eq)
makeLenses ''AppendEntriesResponse

instance Ord AppendEntriesResponse where
  -- This is here to get a set of AERs to order correctly
  -- Node matters most (apples to apples)
  -- Term supersedes index always
  -- Index is really what we're after for how Set AER is used
  -- Hash matters more than verified due to conflict resolution
  -- Then verified, which is metadata really, because if everything up to that point is the same then the one that already ran through crypto is more valuable
  -- After that it doesn't matter.
  (AppendEntriesResponse t n s c i h p) <= (AppendEntriesResponse t' n' s' c' i' h' p') =
    (n,t,i,h,s,c,p) <= (n',t',i',h',s',c',p')

data AERWire = AERWire (Term,NodeId,Bool,Bool,LogIndex,ByteString)
  deriving (Show, Generic)
instance Serialize AERWire

instance WireFormat AppendEntriesResponse where
  toWire nid pubKey privKey AppendEntriesResponse{..} = case _aerProvenance of
    NewMsg -> let bdy = S.encode $ AERWire ( _aerTerm
                                               , _aerNodeId
                                               , _aerSuccess
                                               , _aerConvinced
                                               , _aerIndex
                                               , _aerHash)
                  sig = sign bdy privKey pubKey
                  dig = Digest nid sig pubKey AER
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left $! err
    Right () -> if _digType dig /= AER
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with AERWire instance"
      else case S.decode bdy of
        Left !err -> Left $! "Failure to decode AERWire: " ++ err
        Right (AERWire !(t,nid,s',c,i,h)) -> Right $! AppendEntriesResponse t nid s' c i h $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

aerDecodeNoVerify :: (ReceivedAt, SignedRPC) -> Either String AppendEntriesResponse
aerDecodeNoVerify (ts, (SignedRPC !dig !bdy)) = case S.decode bdy of
  Left !err -> Left $! "Failure to decode AERWire: " ++ err
  Right (AERWire !(t,nid,s',c,i,h)) -> Right $! AppendEntriesResponse t nid s' c i h $ ReceivedMsg dig bdy $ Just ts

aerReverify :: KeySet -> AppendEntriesResponse -> Either String AppendEntriesResponse
aerReverify ks aer = case _aerProvenance aer of
  NewMsg -> Right aer
  (ReceivedMsg !dig !bdy _) -> verifySignedRPC ks (SignedRPC dig bdy) >> return aer
