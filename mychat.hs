import qualified Data.Map as Map
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent
import Control.Exception
import Control.Monad
import Text.Printf
import System.IO
import Data.List
import Network
--XRecordWildCards
type ClientName = String

data Client = Client
  { clientName     :: ClientName
  , clientHandle   :: Handle
  , clientKicked   :: TVar (Maybe String)
  , clientSendChan :: TChan Message
  }

data Message = Notice String 
             | Tell ClientName String
             | Broadcast ClientName String
             | Command String

newClient :: ClientName -> Handle -> STM Client
newClient name handle = do
  c <- newTChan
  k <- newTVar Nothing
  return Client { clientName     = name
                , clientHandle   = handle
                , clientKicked   = k
                , clientSendChan = c
                }

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg =
  writeTChan clientSendChan msg

data Server = Server
  { clients :: TVar (Map.Map ClientName Client)
  }

newServer :: IO Server
newServer = do 
  c <- newTVarIO Map.empty --newTVarIO :: a -> IO (TVar a)
  return Server {clients = c }

broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do 
  clientmap <- readTVar clients
  mapM_ (\client -> sendMessage client msg) (Map.elems clientmap) 

checkAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server{..} name handle = atomically $ do 
  clientmap <- readTVar clients
  if Map.member name clientmap 
    then return Nothing
    else do client <- newClient name handle 
            writeTVar clients $ Map.insert name client clientmap
            broadcast server  $ Notice (name ++ " has connected")
            return (Just client)

removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} name = atomically $ do
  modifyTVar' clients $ Map.delete name 
  broadcast server $ Notice (name ++ " has disconnected")

talk :: Handle -> Server -> IO ()
talk handle server@Server{..} = do
  hSetNewlineMode handle universalNewlineMode
  hSetBuffering handle LineBuffering
  hPutStrLn handle "Haskell Chat. /help for help"
  readName
 where
  readName = do
    hPutStrLn handle "What is your name?"
    name <- hGetLine handle
    if null name
      then readName
      else mask $ \restore -> do 
             ok <- checkAddClient server name handle
             case ok of
               Nothing -> restore $ do 
                  hPrintf handle
                     "The name %s is in use, please choose another\n" name
                  readName
               Just client ->
                  restore (runClient server client) 
                      `finally` removeClient server name

runClient :: Server -> Client -> IO ()
runClient serv@Server{..} client@Client{..} = do
  race server receive
  return ()
 where
  receive = forever $ do
    msg <- hGetLine clientHandle
    atomically $ sendMessage client (Command msg)

  server = join $ atomically $ do
    k <- readTVar clientKicked
    case k of
      Just reason -> return $
        hPutStrLn clientHandle $ "You have been kicked: " ++ reason
      Nothing -> do
        msg <- readTChan clientSendChan
        return $ do
            continue <- handleMessage serv client msg
            when continue $ server

handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message =
  case message of
     Notice msg         -> output $ "*** " ++ msg
     Tell name msg      -> output $ "*" ++ name ++ "*: " ++ msg
     Broadcast name msg -> output $ "<" ++ name ++ ">: " ++ msg
     Command msg ->
       case words msg of
           "/kick" : who : reason -> do
               atomically $ kick server client who (unwords reason)
               return True
           "/tell" : who : what -> do
               atomically $ tell server  who $ Tell clientName (unwords what)
               return True
           ["/help"] -> do
               hPutStrLn clientHandle $ "Command:\n/kick who reason - Disconnects user name.\n/tell name message - Sends message to the user name.\n/users name reason - list of online users\n/quit - Disconnect yourself."
               return True
           ["/quit"] ->
               return False
           ["/users"] -> do
               atomically $ user server client clientName 
               return True
           ('/':_):_ -> do
               hPutStrLn clientHandle $ "Unrecognized command: " ++ msg
               return True
           _ -> do
               atomically $ broadcast server $ Broadcast clientName msg
               return True
 where
   output s = do hPutStrLn clientHandle s; return True

tell :: Server -> ClientName -> Message -> STM()
tell Server{..} name msg = do
  clientmap <- readTVar clients
  mapM_ (\client -> sendMessage client msg) (Map.lookup name clientmap)  

kick server@Server{..} client@Client{..} name msg = do
  clientmap <- readTVar clients
  k <- readTVar clientKicked
  case k of
    Nothing -> do
      mapM_ (\Client{..} -> writeTVar clientKicked (Just msg)) (Map.lookup name clientmap)
    Just _ -> mapM_ (\Client{..} -> writeTVar clientKicked Nothing) (Map.lookup name clientmap)

user :: Server -> Client -> String -> STM()
user server@Server{..} client@Client{..} name = do
  clientmap <- readTVar clients
  mapM_ (\Client{..} -> tell server name $ Notice clientName) (Map.elems clientmap)

main :: IO ()
main = withSocketsDo $ do
  server <- newServer
  sock <- listenOn $ PortNumber $ fromIntegral port
  printf "Listening on port %d\n" port
  forever $ do
      (handle, host, port) <- accept sock
      printf "Accepted connection from %s: %s\n" host (show port)
      forkFinally (talk handle server) (\_ -> hClose handle)

port :: Int
port = 44444 

-- newTVar :: a -> STM (TVar a)
-- newTVarIO :: a -> IO (TVar a)
-- readTVar :: TVar a -> STM a
-- writeTVar :: TVar a -> a -> STM ()
-- modifyTVar :: TVar a -> (a -> a) -> STM ()
-- retry :: STM a
-- Map.delete :: Ord k => k -> Map k a -> Map k a
-- Map.elems :: Map k a -> [a]
-- 
-- universalNewlineMode :: NewlineMode -  Map '\r\n' into '\n' on input, and '\n' to the native newline represetnation on output.
-- This mode can be used on any platform, and works with text files using any newline convention. The downside is that readFile >>= writeFile might yield a different file.
-- 
-- hSetNewlineMode :: Handle -> NewlineMode -> IO () Set the NewlineMode on the specified Handle. All buffered data is flushed first.
-- Swallow carriage returns sent by telnet clients
-- 
-- mask :: ((forall a. IO a -> IO a) -> IO b) -> IO b Executes an IO computation with asynchronous exceptions masked.
-- That is, any thread which attempts to raise an exception in the current thread with throwTo will be blocked until asynchronous exceptions are unmasked again.
--
-- http://hackage.haskell.org/package/base-4.8.2.0/docs/Control-Exception-Base.html

-- when Monad a => Bool -> a () -> a ()
-- newTVar :: a -> STM (TVar a)
-- newTVarIO :: a -> IO (TVar a)
-- readTVar :: TVar a -> STM a
-- writeTVar :: TVar a -> a -> STM ()
-- modifyTVar :: TVar a -> (a -> a) -> STM ()
-- retry :: STM a
-- Map.delete :: Ord k => k -> Map k a -> Map k a
-- Map.elems :: Map k a -> [a]
-- 
-- universalNewlineMode :: NewlineMode -  Map '\r\n' into '\n' on input, and '\n' to the native newline represetnation on output.
-- This mode can be used on any platform, and works with text files using any newline convention. The downside is that readFile >>= writeFile might yield a different file.
-- 
-- hSetNewlineMode :: Handle -> NewlineMode -> IO () Set the NewlineMode on the specified Handle. All buffered data is flushed first.
-- Swallow carriage returns sent by telnet clients
-- 
-- mask :: ((forall a. IO a -> IO a) -> IO b) -> IO b Executes an IO computation with asynchronous exceptions masked.
-- That is, any thread which attempts to raise an exception in the current thread with throwTo will be blocked until asynchronous exceptions are unmasked again.
--
-- http://hackage.haskell.org/package/base-4.8.2.0/docs/Control-Exception-Base.html

-- when Monad a => Bool -> a () -> a ()
