{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Util.Util
  ( seqIndex
  , getQuorumSize
  , debug
  , randomRIO
  , runRWS_
  , enqueueEvent, enqueueEventLater
  , dequeueEvent
  , dequeueCommand
  , logMetric
  , logStaticMetrics
  , setTerm
  , setRole
  , setCurrentLeader
  , updateLNextIndex
  , setLNextIndex
  , getCmdSigOrInvariantError
  , getRevSigOrInvariantError
  ) where

import Juno.Types
import Juno.Util.Combinator

import Control.Lens
import Data.Sequence (Seq)
import Control.Monad.RWS.Strict
import qualified Control.Concurrent.Lifted as CL
import qualified Data.Sequence as Seq
import qualified Data.Map.Strict as Map
import qualified System.Random as R

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

debug :: String -> Raft ()
debug s = do
  dbg <- view (rs.debugPrint)
  nid <- view (cfg.nodeId)
  role' <- use nodeRole
  dontDebugFollower' <- view (cfg.dontDebugFollower)
  case role' of
    Leader -> liftIO $ dbg nid $ "\ESC[0;34m[LEADER]\ESC[0m: " ++ s
    Follower -> liftIO $ when (not dontDebugFollower') $ dbg nid $ "\ESC[0;32m[FOLLOWER]\ESC[0m: " ++ s
    Candidate -> liftIO $ dbg nid $ "\ESC[1;33m[CANDIDATE]\ESC[0m: " ++ s

randomRIO :: R.Random a => (a,a) -> Raft a
randomRIO rng = view (rs.random) >>= \f -> liftIO $ f rng -- R.randomRIO

runRWS_ :: MonadIO m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = void $ runRWST ma r s

-- no state update
enqueueEvent :: Event -> Raft ()
enqueueEvent event = view (rs.enqueue) >>= \f -> liftIO $ f event
  -- lift $ writeChan ein event

enqueueEventLater :: Int -> Event -> Raft CL.ThreadId
enqueueEventLater t event = view (rs.enqueueLater) >>= \f -> liftIO $ f t event

-- no state update
dequeueEvent :: Raft Event
dequeueEvent = view (rs.dequeue) >>= \f -> liftIO f

-- dequeue command from API interface
dequeueCommand :: Raft (RequestId, [(Maybe Alias, CommandEntry)])
dequeueCommand = view (rs.dequeueFromApi) >>= \f -> liftIO f

logMetric :: Metric -> Raft ()
logMetric metric = view (rs.publishMetric) >>= \f -> liftIO $ f metric

logStaticMetrics :: Raft ()
logStaticMetrics = do
  logMetric . MetricNodeId =<< view (cfg.nodeId)
  logMetric . MetricClusterSize =<< view clusterSize
  logMetric . MetricQuorumSize =<< view quorumSize


setTerm :: Term -> Raft ()
setTerm t = do
  void $ rs.writeTermNumber ^$ t
  term .= t
  logMetric $ MetricTerm t

setRole :: Role -> Raft ()
setRole newRole = do
  nodeRole .= newRole
  logMetric $ MetricRole newRole

setCurrentLeader :: Maybe NodeId -> Raft ()
setCurrentLeader mNode = do
  currentLeader .= mNode
  logMetric $ MetricCurrentLeader mNode

updateLNextIndex :: (Map.Map NodeId LogIndex -> Map.Map NodeId LogIndex)
                 -> Raft ()
updateLNextIndex f = do
  lNextIndex %= f
  lni <- use lNextIndex
  ci <- use commitIndex
  logMetric $ MetricAvailableSize $ availSize lni ci

  where
    -- | The number of nodes at most one behind the commit index
    availSize lni ci = let oneBehind = pred ci
                       in succ $ Map.size $ Map.filter (>= oneBehind) lni

setLNextIndex :: Map.Map NodeId LogIndex
              -> Raft ()
setLNextIndex = updateLNextIndex . const

getCmdSigOrInvariantError :: String -> Command -> Signature
getCmdSigOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digSig _pDig

getRevSigOrInvariantError :: String -> Revolution -> Signature
getRevSigOrInvariantError where' s@Revolution{..} = case _revProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, got an unsigned Revolution" ++ show s
  ReceivedMsg{..} -> _digSig _pDig
