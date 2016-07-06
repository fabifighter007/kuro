{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.AppendEntries
  (handle
  ,createAppendEntriesResponse)
where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.State (get)
import Control.Monad.Writer.Strict
import Data.Map (Map)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Map as Map
import qualified Data.Set as Set

import Juno.Consensus.Handle.Types
import Juno.Consensus.Handle.AppendEntriesResponse (updateCommitProofMap)
import qualified Juno.Types.Sender as Sender
import Juno.Runtime.Sender (createAppendEntriesResponse')
import Juno.Runtime.Timer (resetElectionTimer)
import Juno.Util.Util
import qualified Juno.Types as JT
import Juno.Types.Log

data AppendEntriesEnv = AppendEntriesEnv {
-- Old Constructors
    _term             :: Term
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _logEntryAtPrevIdx :: Maybe LogEntry
-- New Constructors
  , _quorumSize       :: Int
  }
makeLenses ''AppendEntriesEnv

data AppendEntriesOut = AppendEntriesOut {
      _newLeaderAction :: CheckForNewLeaderOut
    , _result :: AppendEntriesResult
}

data CheckForNewLeaderOut =
  LeaderUnchanged |
  NewLeaderConfirmed {
      _stateRsUpdateTerm  :: Term
    , _stateIgnoreLeader  :: Bool
    , _stateCurrentLeader :: NodeId
    , _stateRole          :: Role
    }

data AppendEntriesResult =
    Ignore |
    SendUnconvincedResponse {
      _responseLeaderId :: NodeId } |
    ValidLeaderAndTerm {
        _responseLeaderId :: NodeId
      , _validReponse :: ValidResponse }

-- TODO: we need a Noop version as well
data ValidResponse =
    SendFailureResponse |
    Commit {
        _replay :: Map (NodeId, Signature) (Maybe CommandResult)
      , _newEntries :: ReplicateLogEntries } |
    DoNothing

-- THREAD: SERVER MAIN. updates state
handleAppendEntries :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m) => AppendEntries -> m AppendEntriesOut
handleAppendEntries ae@AppendEntries{..} = do
  tell ["received appendEntries: " ++ show _prevLogIndex ]
  nlo <- checkForNewLeader ae
  (currentLeader',ignoreLeader',currentTerm' ) :: (Maybe NodeId,Bool,Term) <-
                case nlo of
                  LeaderUnchanged -> (,,) <$> view currentLeader <*> view ignoreLeader <*> view term
                  NewLeaderConfirmed{..} -> return (Just _stateCurrentLeader,_stateIgnoreLeader,_stateRsUpdateTerm)
  case currentLeader' of
    Just leader' | not ignoreLeader' && leader' == _leaderId && _aeTerm == currentTerm' -> do
      plmatch <- prevLogEntryMatches _prevLogIndex _prevLogTerm
      if not plmatch
        then return $ AppendEntriesOut nlo $ ValidLeaderAndTerm _leaderId SendFailureResponse
        else AppendEntriesOut nlo . ValidLeaderAndTerm _leaderId <$> appendLogEntries _prevLogIndex _aeEntries
          {-|
          if (not (Seq.null _aeEntries))
            -- only broadcast when there are new entries
            -- this has the downside that recovering nodes won't update
            -- their commit index until new entries come along
            -- not sure if this is okay or not
            -- committed entries by definition have already been externalized
            -- so if a particular node missed it, there were already 2f+1 nodes
            -- that didn't
            then sendAllAppendEntriesResponse
            else sendAppendEntriesResponse _leaderId True True
          --}
    _ | not ignoreLeader' && _aeTerm >= currentTerm' -> do -- see TODO about setTerm
      tell ["sending unconvinced response for AE received from "
           ++ show (JT.unAlias $ _alias $ _digNodeId $ _pDig $ _aeProvenance)
           ++ " for " ++ show (_aeTerm, _prevLogIndex)
           ++ " with " ++ show (Seq.length $ _aeEntries)
           ++ " entries; my term is " ++ show currentTerm']
      return $ AppendEntriesOut nlo $ SendUnconvincedResponse _leaderId
    _ -> return $ AppendEntriesOut nlo Ignore

checkForNewLeader :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m) => AppendEntries -> m CheckForNewLeaderOut
checkForNewLeader AppendEntries{..} = do
  term' <- view term
  currentLeader' <- view currentLeader
  if (_aeTerm == term' && currentLeader' == Just _leaderId) || _aeTerm < term' || Set.size _aeQuorumVotes == 0
  then return LeaderUnchanged
  else do
     tell ["New leader identified: " ++ show _leaderId]
     votesValid <- confirmElection _leaderId _aeTerm _aeQuorumVotes
     tell ["New leader votes are valid: " ++ show votesValid]
     if votesValid
     then return $ NewLeaderConfirmed
          _aeTerm
          False
          _leaderId
          Follower
     else return LeaderUnchanged

confirmElection :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m) => NodeId -> Term -> Set RequestVoteResponse -> m Bool
confirmElection leader' term' votes = do
  quorumSize' <- view quorumSize
  tell ["confirming election of a new leader"]
  if Set.size votes >= quorumSize'
    then return $ all (validateVote leader' term') votes
    else return False

validateVote :: NodeId -> Term -> RequestVoteResponse -> Bool
validateVote leader' term' RequestVoteResponse{..} = _rvrCandidateId == leader' && _rvrTerm == term'


prevLogEntryMatches :: MonadReader AppendEntriesEnv m => LogIndex -> Term -> m Bool
prevLogEntryMatches pli plt = do
  mOurReplicatedLogEntry <- view logEntryAtPrevIdx
  case mOurReplicatedLogEntry of
    -- if we don't have the entry, only return true if pli is startIndex
    Nothing    -> return (pli == startIndex)
    -- if we do have the entry, return true if the terms match
    Just LogEntry{..} -> return (_leTerm == plt)

appendLogEntries :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m)
                 => LogIndex -> Seq LogEntry -> m ValidResponse
appendLogEntries pli newEs
  | Seq.null newEs = return DoNothing
  | otherwise = case JT.toReplicateLogEntries pli newEs of
      Left err -> do
          tell ["Failure to Append Logs: " ++ err]
          return SendFailureResponse
      Right rle -> do
        replay <- return $
          foldl (\m LogEntry{_leCommand = c@Command{..}} ->
                  Map.insert (_cmdClientId, getCmdSigOrInvariantError "appendLogEntries" c) Nothing m)
          Map.empty newEs
        tell ["replicated LogEntry(s): " ++ (show $ _rleMinLogIdx rle) ++ " through " ++ (show $ _rleMaxLogIdx rle)]
        return $ Commit replay rle

applyNewLeader :: CheckForNewLeaderOut -> JT.Raft ()
applyNewLeader LeaderUnchanged = return ()
applyNewLeader NewLeaderConfirmed{..} = do
  setTerm _stateRsUpdateTerm
  JT.ignoreLeader .= _stateIgnoreLeader
  setCurrentLeader $ Just _stateCurrentLeader
  setRole _stateRole

logHashChange :: JT.Raft ()
logHashChange = do
  mLastHash <- accessLogs $ lastLogHash
  logMetric $ JT.MetricHash mLastHash

handle :: AppendEntries -> JT.Raft ()
handle ae = do
  r <- ask
  s <- get
  -- This `when` fixes a funky bug. If the leader receives an AE from itself it will reset its election timer (which can kill the leader).
  -- Ignoring this is safe because if we have an out of touch leader they will step down after 2x maxElectionTimeouts if it receives no valid AER
  -- TODO: change this behavior to be if it hasn't heard from a quorum in 2x maxElectionTimeouts
  when (JT._nodeRole s /= Leader) $ do
    logAtAEsLastLogIdx <- accessLogs $ lookupEntry $ _prevLogIndex ae
    let ape = AppendEntriesEnv
                (JT._term s)
                (JT._currentLeader s)
                (JT._ignoreLeader s)
                (logAtAEsLastLogIdx)
                (JT._quorumSize r)
    (AppendEntriesOut{..}, l) <- runReaderT (runWriterT (handleAppendEntries ae)) ape
    ci <- accessLogs $ viewLogState commitIndex
    unless (ci == _prevLogIndex ae && length l == 1) $ mapM_ debug l
    applyNewLeader _newLeaderAction
    case _result of
      Ignore -> do
        debug $ "Ignoring AE from "
              ++ show (JT.unAlias $ _alias $ _digNodeId $ _pDig $ _aeProvenance ae )
              ++ " for " ++ show (_prevLogIndex $ ae)
              ++ " with " ++ show (Seq.length $ _aeEntries ae) ++ " entries."
        return ()
      SendUnconvincedResponse{..} -> enqueueRequest $ Sender.SingleAER _responseLeaderId False False
      ValidLeaderAndTerm{..} -> do
        JT.lazyVote .= Nothing
        case _validReponse of
          SendFailureResponse -> enqueueRequest $ Sender.SingleAER _responseLeaderId False True
          (Commit rMap rle) -> do
            accessLogs $ updateLogs $ ULReplicate rle
            logHashChange
            JT.replayMap %= Map.union rMap
            myEvidence <- createAppendEntriesResponse True True
            JT.commitProof %= updateCommitProofMap myEvidence
            -- TODO: we can be smarter here and fill in the details the AER needs about the logs without needing to hit that thread
            enqueueRequest Sender.BroadcastAER
          DoNothing -> enqueueRequest Sender.BroadcastAER
        -- This NEEDS to be last, otherwise we can have an election fire when we are are transmitting proof/accessing the logs
        -- It's rare but under load and given enough time, this will happen.
        resetElectionTimer

createAppendEntriesResponse :: Bool -> Bool -> JT.Raft AppendEntriesResponse
createAppendEntriesResponse success convinced = do
  ct <- use JT.term
  myNodeId' <- JT.viewConfig JT.nodeId
  es <- getLogState
  case createAppendEntriesResponse' success convinced ct myNodeId'
           (maxIndex' es) (lastLogHash' es) of
    AER' aer -> return aer
    _ -> error "deep invariant error: crtl-f for createAppendEntriesResponse"
