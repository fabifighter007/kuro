{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Config
  ( Config(..), otherNodes, nodeId, electionTimeoutRange, heartbeatTimeout
  , enableDebug, publicKeys, clientPublicKeys, myPrivateKey, clientTimeoutLimit
  , myPublicKey, batchTimeDelta, dontDebugFollower, apiPort
  , logSqlitePath, enableAwsIntegration,entity
  , KeySet(..), ksClient, ksCluster
  , EntityInfo(..),entName
  ) where

import Control.Monad (mzero)
import Control.Lens hiding (Index, (|>))
import Data.Map (Map)
import Data.Set (Set)
import Text.Read (readMaybe)
import qualified Data.Text as Text
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import Data.Aeson (genericParseJSON,genericToJSON,parseJSON,toJSON,ToJSON,FromJSON,Value(..))
import Data.Aeson.Types (defaultOptions,Options(..))
import GHC.Generics hiding (from)

import Kadena.Types.Base


data EntityInfo = EntityInfo {
      _entName :: String
} deriving (Eq,Show,Generic)
$(makeLenses ''EntityInfo)
instance ToJSON EntityInfo where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 4 }
instance FromJSON EntityInfo where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 4 }

data Config = Config
  { _otherNodes           :: !(Set NodeId)
  , _nodeId               :: !NodeId
  , _publicKeys           :: !(Map NodeId PublicKey)
  , _clientPublicKeys     :: !(Map NodeId PublicKey)
  , _myPrivateKey         :: !PrivateKey
  , _myPublicKey          :: !PublicKey
  , _electionTimeoutRange :: !(Int,Int)
  , _heartbeatTimeout     :: !Int
  , _batchTimeDelta       :: !NominalDiffTime
  , _enableDebug          :: !Bool
  , _clientTimeoutLimit   :: !Int
  , _dontDebugFollower    :: !Bool
  , _apiPort              :: !Int
  , _logSqlitePath        :: !FilePath
  , _enableAwsIntegration :: !Bool
  , _entity               :: EntityInfo
  }
  deriving (Show, Generic)
makeLenses ''Config

instance ToJSON NominalDiffTime where
  toJSON = toJSON . show . toSeconds'
instance FromJSON NominalDiffTime where
  parseJSON (String s) = case readMaybe $ Text.unpack s of
    Just s' -> return $ fromSeconds' s'
    Nothing -> mzero
  parseJSON _ = mzero
instance ToJSON Config where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON Config where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 1 }

data KeySet = KeySet
  { _ksCluster :: !(Map NodeId PublicKey)
  , _ksClient  :: !(Map NodeId PublicKey)
  } deriving (Show)
makeLenses ''KeySet