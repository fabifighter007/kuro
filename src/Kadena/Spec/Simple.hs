{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Spec.Simple
  ( runServer
  , runClient
  , RequestId
  , CommandStatus
  ) where

import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,updateAction,updateFreq)
import Control.Concurrent
import qualified Control.Concurrent.Chan.Unagi as Unagi
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

import Data.Monoid ((<>))
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.Clock (UTCTime, getCurrentTime)
import Data.Thyme.LocalTime
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map as Map
import qualified Data.Map.Strict as MS
import qualified Data.Set as Set
import qualified Data.Yaml as Y

import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (BufferMode(..),stdout,stderr,hSetBuffering)
import System.Log.FastLogger
import System.Random

import Kadena.Consensus.Server
import Kadena.Consensus.Client
import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Spec hiding (timeCache)
import Kadena.Types.Message.CMD
import Kadena.Types.Metric
import Kadena.Types.Dispatch
import Kadena.Util.Util (awsDashVar,pubConsensusFromState)
import Kadena.Messaging.ZMQ
import Kadena.Monitoring.Server (startMonitoring)
import Kadena.Runtime.Api.ApiServer
import qualified Kadena.Runtime.MessageReceiver as RENV
import Kadena.Command.CommandLayer
import Kadena.Command.Types

data Options = Options
  {  optConfigFile :: FilePath
   , optApiPort :: Int
   , optDisablePersistence :: Bool
  } deriving Show

defaultOptions :: Options
defaultOptions = Options { optConfigFile = "", optApiPort = -1, optDisablePersistence = False}

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['c']
           ["config"]
           (ReqArg (\fp opts -> opts { optConfigFile = fp }) "CONF_FILE")
           "Configuration File"
  , Option ['p']
           ["apiPort"]
           (ReqArg (\p opts -> opts { optApiPort = read p }) "API_PORT")
           "Api Port"
  , Option ['d']
           ["disablePersistence"]
           (OptArg (\_ opts -> opts { optDisablePersistence = True }) "DISABLE_PERSISTENCE" )
            "Disable Persistence"
  ]

getConfig :: IO Config
getConfig = do
  argv <- getArgs
  case getOpt Permute options argv of
    (o,_,[]) -> do
      opts <- return $ foldl (flip id) defaultOptions o
      conf <- Y.decodeFileEither $ optConfigFile opts
      case conf of
        Left err -> putStrLn (Y.prettyPrintParseException err) >> exitFailure
        Right conf' -> return $ conf'
          { _apiPort = if optApiPort opts == -1 then conf' ^. apiPort else optApiPort opts
          , _logSqlitePath = if optDisablePersistence opts then "" else conf' ^. logSqlitePath
          }
    (_,_,errs)     -> mapM_ putStrLn errs >> exitFailure

showDebug :: TimedFastLogger -> String -> IO ()
showDebug fs m = fs (\t -> toLogStr t <> " " <> toLogStr (BSC.pack m) <> "\n")

noDebug :: String -> IO ()
noDebug _ = return ()

timeCache :: TimeZone -> IO UTCTime -> IO (IO FormattedTime)
timeCache tz tc = mkAutoUpdate defaultUpdateSettings
  { updateAction = do
      t' <- tc
      (ZonedTime (LocalTime d t) _) <- return $ view zonedTime (tz,t')
      return $ BSC.pack $ showGregorian d ++ "T" ++ take 12 (show t)
  , updateFreq = 1000}

utcTimeCache :: IO (IO UTCTime)
utcTimeCache = mkAutoUpdate defaultUpdateSettings
  { updateAction = getCurrentTime
  , updateFreq = 1000}

initSysLog :: IO UTCTime -> IO TimedFastLogger
initSysLog tc = do
  tz <- getCurrentTimeZone
  fst <$> newTimedFastLogger (join $ timeCache tz tc) (LogStdout defaultBufSize)

simpleConsensusSpec :: ApplyFn
               -> (String -> IO ())
               -> (Metric -> IO ())
               -> MVar (MS.Map RequestId AppliedCommand)
               -> ConsensusSpec
simpleConsensusSpec applyFn debugFn pubMetricFn appliedCmdMap = ConsensusSpec
    {

      _applyLogEntry   = applyFn

    , _debugPrint      = debugFn

    , _publishMetric   = pubMetricFn

    , _getTimestamp = liftIO getCurrentTime

    , _random = liftIO . randomRIO

    , _enqueueApplied = (\a -> modifyMVar_ appliedCmdMap
                               (\m -> return $! MS.insert (_acRequestId a) a m))

    }

simpleReceiverEnv :: Dispatch
                  -> Config
                  -> (String -> IO ())
                  -> MVar String
                  -> RENV.ReceiverEnv
simpleReceiverEnv dispatch conf debugFn restartTurbo' = RENV.ReceiverEnv
  dispatch
  (KeySet (view publicKeys conf) (view clientPublicKeys conf))
  debugFn
  restartTurbo'


setLineBuffering :: IO ()
setLineBuffering = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

resetAwsEnv :: Bool -> IO ()
resetAwsEnv awsEnabled = do
  awsDashVar awsEnabled "Role" "Startup"
  awsDashVar awsEnabled "Term" "Startup"
  awsDashVar awsEnabled "AppliedIndex" "Startup"
  awsDashVar awsEnabled "CommitIndex" "Startup"

runClient :: (Command -> IO CommandResult) -> IO (RequestId, [CommandEntry]) -> CommandMVarMap -> MVar Bool -> IO ()
runClient _applyFn getEntries cmdStatusMap' disableTimeouts = do
  setLineBuffering
  rconf <- getConfig
  resetAwsEnv (rconf ^. enableAwsIntegration)
  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if rconf ^. enableDebug then showDebug fs else noDebug
  pubMetric <- startMonitoring rconf
  dispatch <- initDispatch
  me <- return $ rconf ^. nodeId
  oNodes <- return $ Set.toList $ Set.delete me $ Set.union (rconf ^. otherNodes) (Map.keysSet $ rconf ^. clientPublicKeys)
  runMsgServer dispatch me oNodes debugFn -- ZMQ
  -- STUBs mocking
  (_, stubGetApiCommands) <- Unagi.newChan
  let raftSpec = undefined {- simpleConsensusSpec
                   (const (return $ CommandResult ""))
                   debugFn
                   (liftIO . pubMetric)
                   updateCmdMapFn
                   cmdStatusMap'
                   stubGetApiCommands -}
  restartTurbo <- newEmptyMVar
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn restartTurbo
  runConsensusClient receiverEnv getEntries cmdStatusMap' rconf raftSpec disableTimeouts utcTimeCache'


runServer :: IO ()
runServer = do
  setLineBuffering
  (toApplied, fromApplied) <- Unagi.newChan
  mAppliedMap <- newMVar MS.empty
  rconf <- getConfig
  (applyFn,_) <- initCommandLayer (CommandConfig (_entity rconf))
  resetAwsEnv (rconf ^. enableAwsIntegration)
  me <- return $ rconf ^. nodeId
  oNodes <- return $ Set.toList $ Set.delete me $ Set.union (rconf ^. otherNodes) (Map.keysSet $ rconf ^. clientPublicKeys)
  dispatch <- initDispatch

  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if rconf ^. enableDebug then showDebug fs else noDebug

  -- each node has its own snap monitoring server
  pubMetric <- startMonitoring rconf
  runMsgServer dispatch me oNodes debugFn -- ZMQ
  let raftSpec = simpleConsensusSpec
                   (liftIO . applyFn)
                   debugFn
                   (liftIO . pubMetric)
                   mAppliedMap

  restartTurbo <- newEmptyMVar
  receiverEnv <- return $ simpleReceiverEnv dispatch rconf debugFn restartTurbo
  timerTarget' <- newEmptyMVar
  rstate <- return $ initialConsensusState timerTarget'
  mPubConsensus' <- newMVar (pubConsensusFromState rstate)
  void $ CL.fork $ runApiServer dispatch rconf debugFn mAppliedMap (_apiPort rconf) mPubConsensus'
  runPrimedConsensusServer receiverEnv rconf raftSpec rstate utcTimeCache' mPubConsensus'