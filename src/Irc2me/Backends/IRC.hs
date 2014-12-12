{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}

module Irc2me.Backends.IRC
  ( runIrcBackend, runIrcBackend'
  ) where

import Control.Concurrent

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Trans.Maybe

import System.IO

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
import Irc2me.Events

import Irc2me.Frontend.Messages        as M hiding (_networkId)
import Irc2me.Frontend.Messages.Helper as M

import Irc2me.Database.Query            as DB
import Irc2me.Database.Tables.Accounts  as DB
import Irc2me.Database.Tables.Networks  as DB

import Irc2me.Backends.IRC.Helper
import Irc2me.Backends.IRC.NetworkState
import Irc2me.Backends.IRC.Broadcast as BC
import Irc2me.Backends.IRC.Events

runIrcBackend :: MonadIO m => EventT mode AccountEvent  m Bool
runIrcBackend = do
  eq <- getEventQueue
  runIrcBackend' eq

runIrcBackend' :: MonadIO m => EventQueue WO AccountEvent -> m Bool
runIrcBackend' eq = do
  mcs <- runExceptT $ reconnectAll Map.empty
  case mcs of
    Right cs -> do
      _  <- liftIO $ forkIO $ runEventTRW eq $
        manageIrcConnections cs
      return True
    Left err -> do
      liftIO $ hPutStrLn stderr $
        "[IRC] Failed to start backend, reason: " ++ show err
      return False

--------------------------------------------------------------------------------
-- Starting up

reconnectAll
  :: (MonadIO m, MonadError SqlError m)
  => IrcConnections
  -> m IrcConnections
reconnectAll con = withCon con $ do

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

          -- init network state
          networkState <- newNetworkState accid netid ident
          let converter = evalIRCMsg networkState

          -- start broadcasting
          mbc'  <- liftIO $ startIrcBroadcast server ident converter
          case mbc' of
            Just bc -> do

              log' $ "Connected to "
                ++ (server ^. serverHost . _Just . _Text)
                ++ ":"
                ++ show (server ^. serverPort . non 0)
                ++ " ("
                ++ (if server ^. serverUseTLS . non False then "using TLS" else "plaintext")
                ++ ")"

              -- store new broadcast
              at accid . non' _Empty . at netid ?= bc

            Nothing -> do
              log' $ "Failed to connect to Network " ++ show (_networkId netid)

 where
  for :: Monad m => [a] -> (a -> MaybeT m ()) -> m ()
  for   l m = do
    _ <- runMaybeT $ forM_ l (\a -> m a `mplus` return ())
    return ()

  require m = maybe mzero return =<< m
  withCon c = execStateT `flip` c

--------------------------------------------------------------------------------
-- IRC message evaluation & network state

evalIRCMsg :: NetworkState -> (UTCTime, IRCMsg) -> IO (Maybe ServerMessage)
evalIRCMsg ns (t,msg)

  | "PRIVMSG" <- IRC.msgCmd msg
  , [to]      <- IRC.msgParams msg & map (^. encoded)

  = do ident <- getNetworkIdentitiy ns
       return $ Just $ serverMessage $ network &~ do
         if ident ^. identityNick == Just to then
           networkMessages .= [ cm ]
          else
           networkChannels .=
             [ emptyChannel &~ do
                 channelName     .= Just to
                 channelMessages .= [ cm ]
             ]

  | otherwise
  = return Nothing

 where

  (cm,params) = msg ^. chatMessage

  -- ServerMessage default 'template'
  serverMessage nw = emptyServerMessage & serverNetworks .~ [ nw ]

  -- network template
  network = emptyNetwork &~ do

    M.networkId .= Just (ns ^. nsNetworkID . DB.networkId & fromIntegral)
