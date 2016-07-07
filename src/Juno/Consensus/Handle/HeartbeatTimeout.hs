{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Consensus.Handle.HeartbeatTimeout
    (handle)
where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Juno.Consensus.Handle.Types
import qualified Juno.Service.Sender as Sender
import Juno.Runtime.Timer (resetHeartbeatTimer, hasElectionTimerLeaderFired)
import Juno.Util.Util (debug,enqueueEvent, enqueueRequest)
import qualified Juno.Types as JT

data HeartbeatTimeoutEnv = HeartbeatTimeoutEnv {
      _nodeRole :: Role
    , _leaderWithoutFollowers :: Bool
}
makeLenses ''HeartbeatTimeoutEnv

data HeartbeatTimeoutOut = IsLeader | NotLeader | NoFollowers

handleHeartbeatTimeout :: (MonadReader HeartbeatTimeoutEnv m, MonadWriter [String] m) => String -> m HeartbeatTimeoutOut
handleHeartbeatTimeout s = do
  tell ["heartbeat timeout: " ++ s]
  role' <- view nodeRole
  leaderWithoutFollowers' <- view leaderWithoutFollowers
  case role' of
    Leader -> if leaderWithoutFollowers'
              then tell ["Leader found to not have followers"] >> return NoFollowers
              else return IsLeader
    _ -> return NotLeader

handle :: String -> JT.Raft ()
handle msg = do
  s <- get
  leaderWithoutFollowers' <- hasElectionTimerLeaderFired
  (out,l) <- runReaderT (runWriterT (handleHeartbeatTimeout msg)) $
             HeartbeatTimeoutEnv
             (JT._nodeRole s)
             leaderWithoutFollowers'
  mapM_ debug l
  case out of
    IsLeader -> do
      lNextIndex' <- use JT.lNextIndex
      lConvinced' <- use JT.lConvinced
      enqueueRequest $ Sender.BroadcastAE Sender.SendEmptyAEIfOutOfSync lNextIndex' lConvinced'
      resetHeartbeatTimer
      hbMicrosecs <- JT.viewConfig JT.heartbeatTimeout
      JT.timeSinceLastAER %= (+ hbMicrosecs)
    NotLeader -> JT.timeSinceLastAER .= 0 -- probably overkill, but nice to know this gets set to 0 if not leader
    NoFollowers -> do
      timeout' <- return $ JT._timeSinceLastAER s
      enqueueEvent $ ElectionTimeout $ "Leader has not hear from followers in: " ++ show (timeout' `div` 1000) ++ "ms"
