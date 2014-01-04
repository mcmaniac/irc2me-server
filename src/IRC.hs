{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Handle IRC connections, send and respond to incoming messages
module IRC
  ( -- * Connection management
    connect, reconnect
  , closeConnection, isOpenConnection
    -- ** Debugging
  , logE, logW, logI
  , getDebugOutput
    -- * Messages
  , send, receive
    -- ** Incoming messages
  , handleIncoming
  , getIncomingMessage
    -- ** Specific messages
  , sendPing, sendPong
  , sendPrivMsg
  , sendJoin
  , sendPart
  , sendNick
  ) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import qualified Data.Map as M
import           Data.Map (Map)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import           Data.Attoparsec
import           Data.Time

import           Network
import qualified Network.TLS as TLS
import           Network.IRC.ByteString.Parser

import System.IO

import IRC.Codes
import IRC.Connection
import IRC.Types
import IRC.TLS

--------------------------------------------------------------------------------
-- Debugging

logC :: Connection -> String -> IO ()
logC con s = do
  atomically $ writeTChan (con_debug_output con) s

logE, logW, logI :: Connection -> String -> String -> IO ()

logE con where_ what =
  logC con $ "Error (" ++ where_ ++ "): " ++ what

logW con where_ what =
  logC con $ "Warning (" ++ where_ ++ "): " ++ what

logI con where_ what =
  logC con $ "Info (" ++ where_ ++ "): " ++ what

getDebugOutput :: Connection -> IO (Maybe String)
getDebugOutput con = handleExceptions $ do
  s <- atomically $ readTChan (con_debug_output con)
  return $ Just s
 where
  handleExceptions = handle (\(_ :: BlockedIndefinitelyOnSTM) -> return Nothing)

--------------------------------------------------------------------------------
-- Connection management

connect
  :: User -> Server -> [(Channel, Maybe Key)] -> IO (Maybe Connection)
connect usr srv channels = do

  -- create debugging output chan for connection
  debug_out <- newTChanIO

  -- see implementation of connect' below (-> Handling incoming messages)
  connect' usr srv (M.fromList channels) debug_out

-- | Try to reestablish an old (closed) connection
reconnect :: Connection -> IO (Maybe Connection)
reconnect con = do

  -- reuse server, user and debugging chan
  let usr       = con_user con
      srv       = con_server con
      chans     = con_channels con
      debug_out = con_debug_output con

  -- see implementation of connect' below (-> Handling incoming messages)
  connect' usr srv chans debug_out

-- | Send \"QUIT\" to server and close connection
closeConnection :: Connection -> Maybe ByteString -> IO ()
closeConnection con quitmsg = do
  sendQuit con quitmsg
  hClose (con_handle con)

isOpenConnection :: Connection -> IO Bool
isOpenConnection con = do
  hIsOpen (con_handle con)

--------------------------------------------------------------------------------
-- Sending & receiving

receive :: Connection -> IO (Either ByteString IRCMsg)
receive con = handleExceptions $ do
  bs <- case con_tls_context con of
          Nothing   -> BS.hGetLine (con_handle con)
          Just ctxt -> tlsGetLine ctxt
  case toIRCMsg bs of
    Done _ msg -> return $ Right msg
    Partial f  -> case f "" of
                    Done _ msg -> return $ Right msg
                    _          -> return $ Left $ impossibleParseError bs
    _          -> return $ Left $ impossibleParseError bs
 where
  handleExceptions = handle $ \(e :: IOException) -> do
                              hClose (con_handle con)
                              return $ Left $
                                 "Exception (receive): "
                                 `BS.append` B8.pack (show e)
                                 `BS.append` " (connection closed)"
  impossibleParseError bs =
    "Error (receive): Impossible parse: \"" `BS.append` bs `BS.append` "\""
  tlsGetLine ctxt = TLS.recvData ctxt -- FIXME

send :: Connection -> IRCMsg -> IO ()
send con msg = handleExceptions $ do
  case con_tls_context con of
    Nothing   -> BS.hPutStr (con_handle con) bs
    Just ctxt -> TLS.sendData ctxt (BL.fromStrict bs)
 where
  bs = fromIRCMsg msg
  handleExceptions =
    handle (\(_ :: IOException) ->
             logE con "send" "Is the connection open?")

--------------------------------------------------------------------------------
-- Specific messages

sendNick :: Connection -> ByteString -> IO ()
sendNick con nick = do
  send con userNickMsg
 where
  userNickMsg = ircMsg "NICK" [ nick ] ""

sendUser :: Connection -> IO ()
sendUser con = do
  send con userMsg
 where
  usr     = con_user con
  userMsg = ircMsg "USER" [ usr_name usr
                          , "*", "*"
                          , usr_realname usr ] ""

sendPing :: Connection -> IO ()
sendPing con = send con $ ircMsg "PING" [] ""

sendPong :: Connection -> IO ()
sendPong con = send con $ ircMsg "PONG" [] ""

sendJoin :: Connection -> Channel -> Maybe Key -> IO Connection
sendJoin con chan mpw = do

  -- send JOIN request to server
  send con $ ircMsg "JOIN" (chan : maybe [] return mpw) ""

  -- Add channel + key to channels map and return new connection:
  return $ con { con_channels = M.insert chan mpw (con_channels con) }

sendPrivMsg
  :: Connection
  -> ByteString       -- ^ Target (user/channel)
  -> ByteString       -- ^ Text
  -> IO ()
sendPrivMsg con to txt = send con $ ircMsg "PRIVMSG" [to] txt

sendPart :: Connection -> Channel -> IO ()
sendPart con channel = send con $ ircMsg "PART" [channel] ""

-- | Send "QUIT" command and closes connection to server. Do not re-use this
-- connection!
sendQuit :: Connection -> Maybe ByteString -> IO ()
sendQuit con mquitmsg = do
  send con quitMsg
 where
  quitMsg = ircMsg "QUIT" (maybe [] return mquitmsg) ""

--------------------------------------------------------------------------------
-- Handeling incoming messages

getIncomingMessage :: Connection -> IO (Maybe (UTCTime, Message))
getIncomingMessage con = handleExceptions $
  Just `fmap` atomically (readTChan (con_messages con))
 where
  handleExceptions = handle (\(_ :: BlockedIndefinitelyOnSTM) -> return Nothing)

connect'
  :: User
  -> Server
  -> Map Channel (Maybe Key)
  -> TChan String
  -> IO (Maybe Connection)
connect' usr srv channels debug_out = handleExceptions $ do

  -- acquire IRC connection
  h <- connectTo (srv_host srv) (srv_port srv)
  hSetBuffering h LineBuffering
  hSetBinaryMode h True

  -- prepare message chan
  msg_chan <- newTChanIO

  -- connection is established at this point
  let connection = Connection usr (usr_nick usr)
                              srv channels M.empty
                              h Nothing
                              debug_out msg_chan

  -- try to establish TLS encryption
  con <- startTLS connection

  -- send username to IRC server
  sendUser con
  sendNick con (con_nick_cur con)
  mcon <- waitForOK con (usr_nick_alt usr)

  maybe (return ()) `flip` mcon $ \con' ->
    mapM_ (uncurry $ sendJoin con') $ M.toList channels

  return mcon

 where
  handleExceptions = handle $ \(_ :: IOException) -> return Nothing

  waitForOK con alt_nicks = do
    mmsg <- receive con
    case mmsg of

      -- check for authentication errors
      Right msg@(msgCmd -> cmd)

        -- everything OK, we're done:
        | cmd == "001" -> return $ Just con

        -- pick different nickname:
        | cmd `isError` err_NICKCOLLISION ||
          cmd `isError` err_NICKNAMEINUSE ->

          case alt_nicks of
            (alt:rst) -> do
              logI con "connect" $ "Nickname changed to \""
                                   ++ B8.unpack alt ++ "\"."
              -- use alternative nick names:
              let con' = con { con_nick_cur = alt }
              sendNick con' alt
              waitForOK con' rst

            [] -> do
              -- no alternative nicks!
              logE con "connect"
                       "Nickname collision: \
                       \Try to supply a list of alternative nicknames. \
                       \(connection closed)"
              closeConnection con Nothing
              return Nothing

        | cmd == "NOTICE" -> do

           let txt = msgTrail msg

           logI con "connect" $ "NOTICE: " ++ show txt
           waitForOK con alt_nicks

      -- unknown message (e.g. NOTICE) TODO: handle MOTD & other
      Right msg -> do
        logI con "connect" (init (B8.unpack (fromIRCMsg msg)))
        waitForOK con alt_nicks

      -- something went wrong
      Left  err -> do logE con "connect" (B8.unpack err)
                      open <- isOpenConnection con
                      if open
                        then waitForOK con alt_nicks
                        else return $ Just con

  isError bs err = bs == (B8.pack $ show err)

-- | Handle incoming messages, change connection details if necessary
handleIncoming :: Connection -> IO Connection
handleIncoming con = do

  mmsg <- receive con

  handleExceptions mmsg $ case mmsg of

    -- parsing error
    Left err -> do
      logE con "handleIncoming" $ B8.unpack err
      return con

    Right msg@(msgCmd -> cmd)

      --
      -- Commands
      --

      -- ping/pong game
      | cmd == "PING" -> do
        sendPong con
        return con

      -- join channels
      | cmd == "JOIN" -> do

        let (trail:_)       = B8.words $ msgTrail msg
            channels        = B8.split ',' trail
            Just (Left who) = msgPrefix msg

        forM_ channels $ \chan ->
          addMessage con $
            JoinMsg chan (if isCurrentUser con who then Nothing else Just who)

        -- check if we joined a channel or if somebody else joined
        if isCurrentUser con who
          then return $ addChannels con channels
          else return $ addUser con who channels

      | cmd == "PART" -> do

        let Just (Left who@UserInfo { userNick }) = msgPrefix msg
            (chan:_) = msgParams msg

        -- send part message
        addMessage con $
          PartMsg chan (if isCurrentUser con who then Nothing else Just who)

        if isCurrentUser con who
          then return $ leaveChannel con chan
          else return $ removeUser con chan userNick

      | cmd == "QUIT" -> do

        let Just (Left who@UserInfo { userNick }) = msgPrefix msg
            comment = msgTrail msg
            chans = getChannelsWithUser con userNick

        -- send part message
        addMessage con $
          QuitMsg chans (if isCurrentUser con who then Nothing else Just who)
                        (if BS.null comment       then Nothing else Just comment)

        if isCurrentUser con who
          then do
            hClose (con_handle con)
            return con
          else return $ userQuit con chans userNick

      | cmd == "KICK" -> do

        let (chan:who:_) = msgParams msg
            comment      = msgTrail msg

        -- send kick message
        addMessage con $
          KickMsg chan (if isCurrentNick con who then Nothing else Just who)
                       (if BS.null comment       then Nothing else Just comment)

        if isCurrentNick con who
          then return $ leaveChannel con chan
          else return $ removeUser con chan who

      | cmd == "KILL" -> do

        hClose (con_handle con)
        return con

      -- private messages
      | cmd == "PRIVMSG" -> do

        let (to:_)    = msgParams msg
            Just from = msgPrefix msg
            txt       = msgTrail msg
        
        addMessage con $ PrivMsg from to txt
        return con

      -- notice messages
      | cmd == "NOTICE" -> do

        let (to:_)    = msgParams msg
            Just from = msgPrefix msg
            txt       = msgTrail msg
        
        addMessage con $ NoticeMsg from to txt
        return con

      -- nick changes
      | cmd == "NICK" -> do

        let (new:_)         = msgParams msg
            Just (Left who) = msgPrefix msg

        addMessage con $
          NickMsg (if isCurrentUser con who then Nothing else Just who) new

        return $ changeNickname con who new

      --
      -- REPLIES
      --

      -- message of the day (MOTD)
      | cmd `isCode` rpl_MOTDSTART ||
        cmd `isCode` rpl_MOTD      -> do

        addMessage con $ MOTDMsg (msgTrail msg)

        return con

      -- topic reply
      | cmd `isCode` rpl_TOPIC -> do

        let chan  = head $ msgParams msg
            topic = msgTrail msg

        -- TODO: send TOPIC message
        logI con "handleIncoming" $
                 "TOPIC for " ++ B8.unpack chan ++ ": " ++ B8.unpack topic

        return $ setTopic con chan (Just topic)

      -- remove old topic (if any)
      | cmd `isCode` rpl_NOTOPIC -> do

        let chan = head $ msgParams msg

        -- TODO: send NOTOPIC message
        logI con "handleIncoming" $
                 "NOTOPIC for " ++ B8.unpack chan ++ "."

        return $ setTopic con chan Nothing

      -- channel names
      | cmd `isCode` rpl_NAMREPLY -> do

        let (_:_:chan:_)   = msgParams msg
            namesWithFlags = map getUserflag $ B8.words $ msgTrail msg

        logI con "handleIncoming" $
                 "NAMREPLY for " ++ B8.unpack chan ++ ": "
                 ++ show namesWithFlags

        return $ setChanNames con chan namesWithFlags

      -- end of channel names
      | cmd `isCode` rpl_ENDOFNAMES -> do

        return con -- do nothing

      --
      -- ERROR codes
      --

      -- nick name change failure
      | cmd `isCode` err_NICKCOLLISION ||
        cmd `isCode` err_NICKNAMEINUSE -> do

        addMessage con $ ErrorMsg (read $ B8.unpack cmd)
        return con

      -- catch all unknown messages
      | otherwise -> do
        logW con "handleIncoming" $
                 "Unknown message command: \""
                 ++ (init . init . B8.unpack $ fromIRCMsg msg) ++ "\""
        return con

 where

  handleExceptions mmsg =
    handle (\(_ :: PatternMatchFail) -> do
             logE con "handleIncoming" $
                      "Pattern match failure: " ++ show mmsg
             return con)

  isCode bs code = bs == (B8.pack $ show code)
