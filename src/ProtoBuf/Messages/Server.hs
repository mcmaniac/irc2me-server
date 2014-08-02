{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Module for server to client messages
module ProtoBuf.Messages.Server where

import Control.Lens.TH
import Control.Lens.Operators
import Data.Text (Text)
import Data.ProtocolBuffers

import GHC.Generics (Generic)

import ProtoBuf.Helper
import ProtoBuf.Instances ()
import ProtoBuf.Messages.IRC
import ProtoBuf.Messages.Network

data PB_ResponseCode
  = PB_ResponseOK
  | PB_ResponseError
  deriving (Eq, Enum, Show)

data PB_ServerMessage = PB_ServerMessage
  { -- response messages
    _response_code     :: Optional 10 (Enumeration PB_ResponseCode)
  , _response_msg      :: Optional 15 (Value Text)

    -- networks
  , _network_list      :: Repeated 20 (Message PB_Network)

    -- IRC messages
  , _irc_msg           :: Optional 30 (Message PB_IrcMessage)
  }
  deriving (Show, Generic)

instance Encode PB_ServerMessage
instance Decode PB_ServerMessage

makeLenses ''PB_ServerMessage

--------------------------------------------------------------------------------
-- Standard messages

emptyServerMessage :: PB_ServerMessage
emptyServerMessage = PB_ServerMessage
  (putField Nothing)
  (putField Nothing)
  (putField [])
  (putField Nothing)

responseOkMessage :: PB_ServerMessage
responseOkMessage = emptyServerMessage
  & response_code .~~ Just PB_ResponseOK

responseErrorMessage :: Maybe Text -> PB_ServerMessage
responseErrorMessage errormsg = emptyServerMessage
  & response_code .~~ Just PB_ResponseError
  & response_msg  .~~ errormsg
