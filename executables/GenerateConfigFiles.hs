{-# LANGUAGE BangPatterns #-}

module Main (main) where

import Control.Arrow
import Crypto.Random
import Data.Ratio
import Crypto.Ed25519.Pure
import Text.Read
import Data.Thyme.Clock
import System.IO
import System.FilePath
import System.Environment
import qualified Data.Yaml as Y

import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Juno.Types

nodes :: [NodeID]
nodes = iterate (\n@(NodeID h p _ _) -> n {_port = p + 1
                                          , _fullAddr = "tcp://" ++ h ++ ":" ++ show (p+1)
                                          , _alias = Alias $ "node" ++ show (p+1-10000)})
                    (NodeID "127.0.0.1" 10000 "tcp://127.0.0.1:10000" $ Alias "node0")

makeKeys :: CryptoRandomGen g => Int -> g -> [(PrivateKey,PublicKey)]
makeKeys 0 _ = []
makeKeys n g = case generateKeyPair g of
  Left err -> error $ show err
  Right (p,priv,g') -> (p,priv) : makeKeys (n-1) g'

keyMaps :: [(PrivateKey,PublicKey)] -> (Map NodeID PrivateKey, Map NodeID PublicKey)
keyMaps ls = (Map.fromList $ zip nodes (fst <$> ls), Map.fromList $ zip nodes (snd <$> ls))

awsNodes :: [String] -> [NodeID]
awsNodes = fmap (\h -> (NodeID h 10000 ("tcp://" ++ h ++ ":10000") $ Alias ("tcp://" ++ h ++ ":10000")))

awsKeyMaps :: [NodeID] -> [(PrivateKey, PublicKey)] -> (Map NodeID PrivateKey, Map NodeID PublicKey)
awsKeyMaps nodes' ls = (Map.fromList $ zip nodes' (fst <$> ls), Map.fromList $ zip nodes' (snd <$> ls))

main :: IO ()
main = do
  runAws <- getArgs
  case runAws of
    [] -> mainLocal
    [v,clustersFile,clientsFile] | v == "--aws" -> mainAws clustersFile clientsFile
    err -> putStrLn $ "Invalid args, wanted `` or `--aws path-to-cluster-ip-file path-to-client-ip-file` but got: " ++ show err

mainAws :: FilePath -> FilePath -> IO ()
mainAws clustersFile clientsFile = do
  !clusters <- readFile clustersFile >>= return . lines
  !clients <- readFile clientsFile >>= return . lines
  g <- newGenIO :: IO SystemRandom
  clusterIds <- return $ awsNodes clusters
  clusterKeys <- return $ makeKeys (length clusters) g
  clusterKeyMaps <- return $ awsKeyMaps clusterIds clusterKeys
  g' <- newGenIO :: IO SystemRandom
  clientIds <- return $ awsNodes clients
  clientKeys <- return $ makeKeys (length clients) g'
  clientKeyMaps <- return $ awsKeyMaps clientIds clientKeys
  clusterConfs <- return (createClusterConfig True clusterKeyMaps (snd clientKeyMaps) <$> clusterIds)
  clientConfs <- return (createClientConfig True (snd clusterKeyMaps) clientKeyMaps <$> clientIds)
  mapM_ (\c' -> Y.encodeFile ("aws-conf" </> (_host $ _nodeId c') ++ "-cluster-aws.yaml") c') clusterConfs
  mapM_ (\c' -> Y.encodeFile ("aws-conf" </> (_host $ _nodeId c') ++ "-client-aws.yaml") c') clientConfs

mainLocal :: IO ()
mainLocal = do
  putStrLn "Number of cluster nodes?"
  hFlush stdout
  mn <- fmap readMaybe getLine
  putStrLn "Number of client nodes?"
  hFlush stdout
  cn <- fmap readMaybe getLine
  putStrLn "Enable logging for Followers (True/False)?"
  hFlush stdout
  debugFollower <- fmap readMaybe getLine
  case (mn,cn,debugFollower) of
    (Just n,Just c,Just df)-> do
      g <- newGenIO :: IO SystemRandom
      keyMaps' <- return $! keyMaps $ makeKeys (n+c) g
      clientIds <- return $ take c $ drop n nodes
      let isAClient nid _ = Set.member nid (Set.fromList clientIds)
      let isNotAClient nid _ = not $ Set.member nid (Set.fromList clientIds)
      clusterKeyMaps <- return $ (Map.filterWithKey isNotAClient *** Map.filterWithKey isNotAClient) keyMaps'
      clientKeyMaps <- return $ (Map.filterWithKey isAClient *** Map.filterWithKey isAClient) keyMaps'
      clusterConfs <- return (createClusterConfig df clusterKeyMaps (snd clientKeyMaps) <$> take n nodes)
      clientConfs <- return (createClientConfig df (snd clusterKeyMaps) clientKeyMaps <$> clientIds)
      mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-cluster.yaml") c') clusterConfs
      mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-client.yaml") c') clientConfs
    _ -> putStrLn "Failed to read either input into a number, please try again"

createClusterConfig :: Bool -> (Map NodeID PrivateKey, Map NodeID PublicKey) -> Map NodeID PublicKey -> NodeID -> Config
createClusterConfig debugFollower (privMap, pubMap) clientPubMap nid = Config
  { _otherNodes           = Set.delete nid $ Map.keysSet pubMap
  , _nodeId               = nid
  , _publicKeys           = pubMap
  , _clientPublicKeys     = Map.union pubMap clientPubMap -- NOTE: [2016 04 26] all nodes are client (support API signing)
  , _myPrivateKey         = privMap Map.! nid
  , _myPublicKey          = pubMap Map.! nid
  , _myEncryptionKey      = EncryptionKey $ exportPublic $ pubMap Map.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1500000              -- seems like a while...
  , _batchTimeDelta       = fromSeconds' (1%100) -- default to 10ms
  , _enableDebug          = True
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = not debugFollower
  , _apiPort              = 8000
  }

createClientConfig :: Bool -> Map NodeID PublicKey -> (Map NodeID PrivateKey, Map NodeID PublicKey) -> NodeID -> Config
createClientConfig debugFollower clusterPubMap (privMap, pubMap) nid = Config
  { _otherNodes           = Map.keysSet clusterPubMap
  , _nodeId               = nid
  , _publicKeys           = clusterPubMap
  , _clientPublicKeys     = pubMap
  , _myPrivateKey         = privMap Map.! nid
  , _myPublicKey          = pubMap Map.! nid
  , _myEncryptionKey      = EncryptionKey $ exportPublic $ pubMap Map.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1500000
  , _batchTimeDelta       = fromSeconds' (1%100) -- default to 10ms
  , _enableDebug          = False
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = not debugFollower
  , _apiPort              = 8000
  }
