{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.RequestVote (
  handle
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.Writer.Strict
import Control.Monad.State (get)

import qualified Data.Set as Set

import Juno.Util.Util (debug, enqueueRequest, queryLogs)
import qualified Juno.Service.Sender as Sender
import qualified Juno.Service.Log as Log
import qualified Juno.Types as JT

import Juno.Consensus.Handle.Types

data RequestVoteEnv = RequestVoteEnv {
-- Old Constructors
    _term             :: Term
  , _votedFor         :: Maybe NodeId
  , _lazyVote         :: Maybe (Term, NodeId, LogIndex)
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _lastLogIndexIn   :: LogIndex
  , _lastTerm         :: Term
  }
makeLenses ''RequestVoteEnv

data RequestVoteOut = NoAction
                    | UpdateLazyVote { _stateCastLazyVote :: (Term, NodeId, LogIndex) }
                    | ReplyToRPCSender { _targetNode :: NodeId
                                       , _lastLogIndex :: LogIndex
                                       , _vote :: Bool }

handleRequestVote :: (MonadWriter [String] m, MonadReader RequestVoteEnv m) => RequestVote -> m RequestVoteOut
handleRequestVote RequestVote{..} = do
  tell ["got a requestVote RPC for " ++ show _rvTerm]
  votedFor' <- view votedFor
  term' <- view term
  currentLeader' <- view currentLeader
  ignoreLeader' <- view ignoreLeader
  lli <- view lastLogIndexIn
  llt <- view lastTerm
  case votedFor' of
    _      | ignoreLeader' && currentLeader' == Just _rvCandidateId -> return NoAction
      -- don't respond to a candidate if they were leader and a client
      -- asked us to ignore them

    _      | _rvTerm < term' -> do
      -- this is an old candidate
      tell ["this is for an old term"]
      return $ ReplyToRPCSender _rvCandidateId lli False

    Just c | c == _rvCandidateId && _rvTerm == term' -> do
      -- already voted for this candidate in this term
      tell ["already voted for this candidate"]
      return $ ReplyToRPCSender _rvCandidateId lli True

    Just _ | _rvTerm == term' -> do
      -- already voted for a different candidate in this term
      tell ["already voted for a different candidate"]
      return $ ReplyToRPCSender _rvCandidateId lli False

    _ | _rvLastLogIndex < lli -> do
      tell ["Candidate has an out of date log, so vote no immediately"]
      return $ ReplyToRPCSender _rvCandidateId lli False

    _ | (_rvLastLogTerm, _rvLastLogIndex) >= (llt, lli) -> do
      lv <- view lazyVote
      case lv of
        Just (t, _, _) | t >= _rvTerm -> do
          tell ["would vote lazily, but already voted lazily for candidate in same or higher term"]
          return NoAction
        Just _ -> do
          tell ["replacing lazy vote"]
          return $ UpdateLazyVote (_rvTerm, _rvCandidateId, lli)
        Nothing -> do
          tell ["haven't voted, (lazily) voting for this candidate"]
          return $ UpdateLazyVote (_rvTerm, _rvCandidateId, lli)
    _ -> do
      tell ["haven't voted, but my log is better than this candidate's"]
      return $ ReplyToRPCSender _rvCandidateId lli False

--createRequestVoteResponse' :: (MonadWriter [String] m, MonadReader RequestVoteEnv m) => NodeId -> LogIndex -> Bool -> m (NodeId, RequestVoteResponse)
--createRequestVoteResponse' target lastLogIndex' vote = do
--  term' <- view term
--  myNodeId' <- view myNodeId
--  (target,) <$> createRequestVoteResponse term' lastLogIndex' myNodeId' target vote


handle :: RequestVote -> JT.Raft ()
handle rv = do
  s <- get
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  let rve = RequestVoteEnv
              (JT._term s)
              (JT._votedFor s)
              (JT._lazyVote s)
              (JT._currentLeader s)
              (JT._ignoreLeader s)
              (Log.hasQueryResult Log.MaxIndex mv)
              (Log.hasQueryResult Log.LastLogTerm mv)
  (rvo, l) <- runReaderT (runWriterT (handleRequestVote rv)) rve
  mapM_ debug l
  case rvo of
    NoAction -> return ()
    UpdateLazyVote stateUpdate -> JT.lazyVote .= Just stateUpdate
    ReplyToRPCSender{..} -> enqueueRequest $ Sender.BroadcastRVR _targetNode _lastLogIndex _vote
