{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.AE
  ( AppendEntries(..), aeTerm, leaderId, prevLogIndex, prevLogTerm, aeEntries, aeQuorumVotes, aeProvenance
  ) where

import Codec.Compression.LZ4
import Control.Parallel.Strategies
import Control.Lens
import Data.Set (Set)
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Foldable
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Message.Signed
import Kadena.Types.Message.RVR
import Kadena.Types.Log

data AppendEntries = AppendEntries
  { _aeTerm        :: !Term
  , _leaderId      :: !NodeId
  , _prevLogIndex  :: !LogIndex
  , _prevLogTerm   :: !Term
  , _aeEntries     :: !LogEntries
  , _aeQuorumVotes :: !(Set RequestVoteResponse)
  , _aeProvenance  :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''AppendEntries

data AEWire = AEWire (Term,NodeId,LogIndex,Term,[LEWire],[SignedRPC])
  deriving (Show, Generic)
instance Serialize AEWire

instance WireFormat AppendEntries where
  toWire nid pubKey privKey AppendEntries{..} = case _aeProvenance of
    NewMsg -> let bdy = maybe (error "failure to compress AE") id $ compressHC $ S.encode $ AEWire (_aeTerm
                                          ,_leaderId
                                          ,_prevLogIndex
                                          ,_prevLogTerm
                                          ,encodeLEWire nid pubKey privKey _aeEntries
                                          ,toWire nid pubKey privKey <$> toList _aeQuorumVotes)
                  sig = sign bdy privKey pubKey
                  dig = Digest (_alias nid) sig pubKey AE
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left err
    Right () -> if _digType dig /= AE
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with AEWire instance"
      else case maybe (Left "Decompression failure") S.decode $ decompress bdy of
        Left err -> Left $! "Failure to decode AEWire: " ++ err
        Right (AEWire (t,lid,pli,pt,les,vts)) -> runEval $ do
          eLes <- rpar (toLogEntries ((decodeLEWire' ts ks <$> les) `using` parList rseq))
          eRvr <- rseq (toSetRvr ((fromWire ts ks <$> vts) `using` parList rseq))
          case eRvr of
            Left !err -> return $! Left $! "Caught an invalid RVR in an AE: " ++ err
            Right !vts' -> do
              _ <- rseq eLes
              case eLes of
                Left !err -> return $! Left $ "Found a LogEntry with an invalid Command: " ++ err
                Right !les' -> return $! Right $! AppendEntries t lid pli pt les' vts' $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
