
module Kadena.Runtime.Role
  ( becomeFollower
  ) where

import Kadena.Runtime.Timer
import Kadena.Types
import Kadena.Util.Util

becomeFollower :: Consensus ()
becomeFollower = do
  debug "becoming follower"
  setRole Follower
  resetElectionTimer
