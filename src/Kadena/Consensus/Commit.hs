{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Consensus.Commit
  (applyLogEntries
  ,makeCommandResponse
  ,makeCommandResponse')
where

import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Int (Int64)
import Data.Thyme.Clock (UTCTime)

import qualified Data.Map.Strict as Map
import Data.Foldable (toList)
import Data.Maybe (fromJust)

import Kadena.Types hiding (valid)
import Kadena.Util.Util
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log


applyLogEntries :: LogEntries -> Consensus ()
applyLogEntries les@(LogEntries leToApply) = do
  now <- view (rs.getTimestamp) >>= liftIO
  results <- mapM (applyCommand now) (Map.elems leToApply)
  r <- use nodeRole
  commitIndex' <- return $ fromJust $ Log.lesMaxIndex les
  logMetric $ MetricAppliedIndex commitIndex'
  if not (null results)
    then if r == Leader
        then do
          enqueueRequest $! Sender.SendCommandResults $! toList results
          debug $ "Applied and Responded to " ++ show (length results) ++ " CMD(s)"
        else debug $ "Applied " ++ show (length results) ++ " CMD(s)"
    else debug "Applied log entries but did not send results?"

logApplyLatency :: Command -> Consensus ()
logApplyLatency (Command _ _ _ _ provenance) = case provenance of
  NewMsg -> return ()
  ReceivedMsg _digest _orig mReceivedAt -> case mReceivedAt of
    Just (ReceivedAt arrived) -> do
      now <- view (rs.getTimestamp) >>= liftIO
      logMetric $ MetricApplyLatency $ fromIntegral $ interval arrived now
    Nothing -> return ()

applyCommand :: UTCTime -> LogEntry -> Consensus (NodeId, CommandResponse)
applyCommand tEnd le = do
  let cmd = _leCommand le
  apply <- view (rs.applyLogEntry)
  logApplyLatency cmd
  result <- liftIO $ apply le
  updateCmdStatusMap cmd result tEnd -- shared with the API and to query state
  replayMap %= Map.insert (_cmdClientId cmd, getCmdSigOrInvariantError "applyCommand" cmd) (Just result)
  (_cmdClientId cmd,) <$> makeCommandResponse tEnd cmd result

updateCmdStatusMap :: Command -> CommandResult -> UTCTime -> Consensus ()
updateCmdStatusMap cmd cmdResult tEnd = do
  rid <- return $ _cmdRequestId cmd
  mvarMap <- view (rs.cmdStatusMap)
  updateMapFn <- view (rs.updateCmdMap)
  lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
    Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
    Just (ReceivedAt tStart) -> interval tStart tEnd
  liftIO $ void $ updateMapFn mvarMap rid (CmdApplied cmdResult lat)

makeCommandResponse :: UTCTime -> Command -> CommandResult -> Consensus CommandResponse
makeCommandResponse tEnd cmd result = do
  nid <- viewConfig nodeId
  mlid <- use currentLeader
  lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
    Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
    Just (ReceivedAt tStart) -> interval tStart tEnd
  return $ makeCommandResponse' nid mlid cmd result lat

makeCommandResponse' :: NodeId -> Maybe NodeId -> Command -> CommandResult -> Int64 -> CommandResponse
makeCommandResponse' nid mlid Command{..} result lat = CommandResponse
             result
             (maybe nid id mlid)
             nid
             _cmdRequestId
             lat
             NewMsg


-- TODO: replicate metrics integration in Evidence
--logCommitChange :: LogIndex -> LogIndex -> Consensus ()
--logCommitChange before after
--  | after > before = do
--      logMetric $ MetricCommitIndex after
--      mLastTime <- use lastCommitTime
--      now <- view (rs.getTimestamp) >>= liftIO
--      case mLastTime of
--        Nothing -> return ()
--        Just lastTime ->
--          let duration = interval lastTime now
--              (LogIndex numCommits) = after - before
--              period = fromIntegral duration / fromIntegral numCommits
--          in logMetric $ MetricCommitPeriod period
--      lastCommitTime ?= now
--  | otherwise = return ()
--
--updateCommitIndex' :: Consensus Bool
--updateCommitIndex' = do
--  proof <- use commitProof
--  -- We don't need a quorum of AER's, but quorum-1 because we check against our own logs (thus assumes +1 at the start)
--  -- TODO: test this idea out
--  --qsize <- view quorumSize >>= \n -> return $ n - 1
--  qsize <- view quorumSize >>= \n -> return $ n - 1
--
--  evidence <- return $! reverse $ sortOn _aerIndex $ Map.elems proof
--
--  mv <- queryLogs $ Set.fromList $ (Log.GetCommitIndex):(Log.GetMaxIndex):((\aer -> Log.GetSomeEntry $ _aerIndex aer) <$> evidence)
--  ci <- return $ Log.hasQueryResult Log.CommitIndex mv
--  maxLogIndex <- return $ Log.hasQueryResult Log.MaxIndex mv
--
--  case checkCommitProof qsize mv maxLogIndex evidence of
--    Left 0 -> do
--      debug $ "Commit Proof Checked: no new evidence " ++ show ci
--      return False
--    Left n -> if maxLogIndex > fromIntegral ci
--              then do
--                debug $ "Not enough evidence to commit yet, need " ++ show (qsize - n) ++ " more"
--                return False
--              else do
--                debug $ "Commit Proof Checked: stead state with MaxLogIndex " ++ show maxLogIndex ++ " == CommitIndex " ++ show ci
--                return False
--    Right qci -> if qci > ci
--                then do
--                  updateLogs $ ULCommitIdx $ UpdateCommitIndex qci
--                  logCommitChange ci qci
--                  commitProof %= Map.filter (\a -> qci < _aerIndex a)
--                  debug $ "Commit index is now: " ++ show qci
--                  return True
--                else do
--                  debug $ "Commit index is " ++ show qci ++ " with evidence for " ++ show ci
--                  return False
--
--checkCommitProof :: Int -> Map Log.AtomicQuery Log.QueryResult  -> LogIndex -> [AppendEntriesResponse] -> Either Int LogIndex
--checkCommitProof qsize mv maxLogIdx evidence = go 0 evidence
--  where
--    go n [] = Left n
--    go n (ev:evs) = if _aerIndex ev > maxLogIdx
--                    then go n evs
--                    else if Just (_aerHash ev) == (_leHash <$> Log.hasQueryResult (Log.SomeEntry (_aerIndex ev)) mv)
--                         then if (n+1) >= qsize
--                              then Right $ _aerIndex ev
--                              else go (n+1) evs
--                         else go n evs
