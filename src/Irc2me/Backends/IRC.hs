{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}

module Irc2me.Backends.IRC
  ( runIrcBackend
  ) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Trans.Maybe

import Data.Int

import System.IO

-- time
import Data.Time.Clock.POSIX

-- irc-bytestring
import Network.IRC.ByteString.Parser as IRC

-- containers
import qualified Data.Map as Map

-- hdbc
import Database.HDBC

-- lens
import Control.Lens
import Data.Text.Lens

-- local
import Control.Concurrent.Event
import Irc2me.Events.Types

import Irc2me.Frontend.Messages        as M hiding (_networkId)
-- import Irc2me.Frontend.Messages.Helper as M

import Irc2me.Database.Query            as DB
import Irc2me.Database.Tables.Accounts  as DB
import Irc2me.Database.Tables.Networks  as DB

import Irc2me.Backends.IRC.Helper
import Irc2me.Backends.IRC.Connection as C

runIrcBackend
  :: (MonadIO m, MonadEventW m AccountEvent)
  => m Bool
runIrcBackend = do
  mcs <- runExceptT $ reconnectAll Map.empty
  case mcs of
    Right _cs -> do -- TODO
      --_  <- liftIO $ forkIO $ runEventTRW eq $
        --manageIrcConnections cs
      return True
    Left err -> do
      liftIO $ hPutStrLn stderr $
        "[IRC] Failed to start backend, reason: " ++ show err
      return False

--------------------------------------------------------------------------------
-- Starting up

reconnectAll
  :: (MonadIO m, MonadError SqlError m, MonadEventW m AccountEvent)
  => IrcConnections
  -> m ()
reconnectAll con = withCon con $ do

  eq <- getEventQueue

  accs <- runQuery selectAccounts
  for accs $ \accid -> do

    let log' s = liftIO . putStrLn $ "[" ++ show (_accountId accid) ++ "] " ++ s

    servers <- runQuery $ selectServersToReconnect accid
    for servers $ \(netid, server) -> do

      -- lookup network to see if we're already connected
      mbc <- preuse $ at accid . _Just . at netid
      case mbc of

        -- network already connected
        Just _ -> return ()

        -- reconnect network
        Nothing -> do

          -- query network identity from DB
          ident <- require $ runQuery $ selectNetworkIdentity accid netid

          -- connect to IRC and raise events for all incoming messages
          mc'  <- liftIO $ ircConnect server ident $
                             raiseChatMessageEvent eq accid netid

          case mc' of
            Just c -> do

              log' $ "Connected to "
                ++ (server ^. serverHost . _Just . _Text)
                ++ ":"
                ++ show (server ^. serverPort . non 0)
                ++ " ("
                ++ (if server ^. serverUseTLS . non False then "using TLS" else "plaintext")
                ++ ")"

              -- store new broadcast
              --at accid . non' _Empty . at netid ?= bc

              -- notify event handler of new connection
              lift $ lift $ raiseEvent $ AccountEvent accid $
                NewIrcConnectionEvent netid c

            Nothing -> do
              log' $ "Failed to connect to Network " ++ show (_networkId netid)
 where
  for :: Monad m => [a] -> (a -> MaybeT m ()) -> m ()
  for   l m = do
    _ <- runMaybeT $ forM_ l (\a -> m a `mplus` return ())
    return ()

  require m = maybe mzero return =<< m
  withCon c = evalStateT `flip` c

--------------------------------------------------------------------------------
-- IRC message evaluation & network state

raiseChatMessageEvent :: EventQueue WO AccountEvent -> AccountID -> NetworkID -> (UTCTime, IRCMsg) -> IO ()
raiseChatMessageEvent eq aid nid (t,msg) =
  writeEventIO eq $ AccountEvent aid $ ChatMessageEvent nid cm
 where

  epoch :: Int64
  epoch = floor $ utcTimeToPOSIXSeconds t * 1000

  cm = msg ^. chatMessage &~ do

    -- add timestamp
    messageTimestamp .= Just epoch


{-
evalIRCMsg :: NetworkState -> (UTCTime, IRCMsg) -> IO (Maybe ServerMessage)
evalIRCMsg ns (t,msg)

  | Just _ty  <- cm ^. messageType -- known type
  , [to']     <- params            -- one recipient

  = do ident <- getNetworkIdentitiy ns

       -- build broadcast message
       return $ Just $ serverMessage $ network &~ do

         -- figure out where messages goes to
         if ident ^. identityNick == Just to' then
           networkMessages .= [ cm ]
          else
           networkChannels .=
             [ emptyChannel &~ do
                 channelName     .= Just to'
                 channelMessages .= [ cm ]
             ]

  | otherwise
  = do -- broadcast everything else as 'private' network message:
       return $ Just $ serverMessage $ network &~ do
         networkMessages .= [ cm ]
-}

{-
  -- ServerMessage default 'template'
  serverMessage nw = emptyServerMessage & serverNetworks .~ [ nw ]

  -- network template
  network = emptyNetwork &~ do

    M.networkId .= Just (ns ^. nsNetworkID . DB.networkId & fromIntegral)
-}
