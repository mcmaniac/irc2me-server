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
  , sendQuit
  , sendNick
  ) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import qualified Data.Map as M
import           Data.Map (Map)
import qualified Data.ByteString as BS
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import           Data.Attoparsec
import           Data.Time

import Network
import Network.IRC.ByteString.Parser

import System.IO

import IRC.Codes
import IRC.Connection
import IRC.Debug
import IRC.Types
import IRC.TLS

--------------------------------------------------------------------------------
-- Connection management

connect
  :: Server
  -> TLSSettings
  -> User
  -> IO (Maybe Connection)
connect srv tls_set usr = do

  -- create debugging output chan for connection
  debug_out <- newTChanIO

  -- see implementation of connect' below (-> Handling incoming messages)
  connect' srv tls_set usr M.empty debug_out

-- | Try to reestablish an old (closed) connection
reconnect :: Connection -> IO (Maybe Connection)
reconnect con = do

  -- reuse server, user and debugging chan
  let usr       = con_user con
      srv       = con_server con
      chans     = con_channels con
      tls_set   = con_tls_settings con
      debug_out = con_debug_output con

  -- see implementation of connect' below (-> Handling incoming messages)
  connect' srv tls_set usr chans debug_out

-- | Send \"QUIT\" to server and close connection
closeConnection :: Connection -> IO Connection
closeConnection con = do
  --sendQuit con quitmsg
  sendBye con
  hClose (con_handle con)
  return $ con { con_is_open = False }

isOpenConnection :: Connection -> Bool
isOpenConnection = con_is_open


--------------------------------------------------------------------------------
-- Sending & receiving

receive :: Connection -> IO (Either ByteString IRCMsg)
receive con = handleExceptions $ do
  bs <- tlsGetLine con
  case toIRCMsg bs of
    Done _ msg -> return $ Right msg
    Partial f  -> case f "" of
                    Done _ msg -> return $ Right msg
                    _          -> return $ Left $ impossibleParseError bs
    _          -> return $ Left $ impossibleParseError bs
 where
  handleExceptions = handle (\(e :: IOException) -> onExc e)
                   . handle (\(e :: BlockedIndefinitelyOnSTM) -> onExc e)
   where
    onExc e = do _ <- closeConnection con
                 return $ Left $
                   "Exception (receive): " `BS.append` B8.pack (show e)
                                           `BS.append` " (connection closed)"
  impossibleParseError bs =
    "Error (receive): Impossible parse: \"" `BS.append` bs `BS.append` "\""

send :: Connection -> IRCMsg -> IO ()
send con msg = handleExceptions $ do
  tlsSend con $ fromIRCMsg msg
 where
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
  :: Server
  -> TLSSettings
  -> User
  -> Map Channel (Maybe Key)
  -> TChan String
  -> IO (Maybe Connection)
connect' srv tls_set usr channels debug_out = handleExceptions $ do

  -- acquire IRC connection
  h <- connectTo (srv_host srv) (srv_port srv)
  hSetBuffering h LineBuffering
  hSetBinaryMode h True

  -- prepare message chan
  msg_chan <- newTChanIO

  -- connection is established at this point
  let con = Connection usr (usr_nick usr)
                       srv channels M.empty
                       h True tls_set Nothing
                       debug_out msg_chan

  -- check TLS settings

  when (tls_set == NoTLS) $ do
    sendUser con
    sendNick con (con_nick_cur con)

  when (tls_set == STARTTLS || tls_set == OptionalSTARTTLS) $ do
    logI con "connect" "Sending STARTTLS"
    hPutStrLn (con_handle con) "STARTTLS"

  con' <- if (tls_set == TLS)
    then do
      logI con "connect" "Starting TLS handshake"
      con' <- establishTLS con
      sendUser con'
      sendNick con' (con_nick_cur con)
      return con'
    else return con

  let is_authed = tls_set `elem` [NoTLS, TLS]

  -- send username to IRC server
  mcon <- waitForOK con' (usr_nick_alt usr) is_authed

  maybe (return ()) `flip` mcon $ \con'' ->
    mapM_ (uncurry $ sendJoin con'') $ M.toList channels

  return mcon

 where
  handleExceptions = handle $ \(e :: IOException) -> do
    hPutStrLn stderr $ "IOException on connect: " ++ show e
    return Nothing

  waitForOK con alt_nicks is_authed = do
    mmsg <- receive con
    case mmsg of

      -- check for authentication errors
      Right msg@(msgCmd -> cmd)

        -- everything OK, we're done:
        | cmd == "001" -> return $ Just con

        -- "STARTTLS OK" reply
        | cmd == "670" &&
          (tls_set == STARTTLS || tls_set == OptionalSTARTTLS) -> do

          con' <- establishTLS con

          sendUser con'
          sendNick con' (con_nick_cur con)

          waitForOK con' alt_nicks True

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
              waitForOK con' rst is_authed

            [] -> do
              -- no alternative nicks!
              logE con "connect"
                       "Nickname collision: \
                       \Try to supply a list of alternative nicknames. \
                       \(connection closed)"
              sendQuit con Nothing
              Just `fmap` closeConnection con

        | cmd == "NOTICE" -> do

           let txt = msgTrail msg

           logI con "connect" $ "NOTICE: " ++ show txt
           waitForOK con alt_nicks is_authed

      -- unknown message (e.g. NOTICE) TODO: handle MOTD & other
      Right msg -> do
        logI con "connect" (init (B8.unpack (fromIRCMsg msg)))

        -- FIXME: workaround for authentication after a failed STARTTLS attempt
        if is_authed then
          waitForOK con alt_nicks is_authed
         else if tls_set == OptionalSTARTTLS then do
          -- STARTTLS failed, authenticate plaintext:
          sendUser con
          sendNick con (con_nick_cur con)
          waitForOK con alt_nicks True
         else do
          sendQuit con Nothing
          con' <- closeConnection con
          return $ Just con'

      -- something went wrong
      Left  err -> do logE con "connect" (B8.unpack err)
                      if isOpenConnection con
                        then waitForOK con alt_nicks is_authed
                        else return $ Just con

  isError bs err = bs == (B8.pack err)

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
          then closeConnection con
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

        closeConnection con

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

  isCode bs code = bs == (B8.pack code)
