module Hasql.Pool (
  -- * Pool
  Pool,
  acquire,
  acquireDynamically,
  release,
  use,

  -- * Errors
  UsageError (..),
) where

import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Pool.Prelude
import Hasql.Session (Session)
import Hasql.Session qualified as Session

-- | Pool of connections to DB.
data Pool = Pool
  { poolFetchConnectionSettings :: IO Connection.Settings
  -- ^ Connection settings.
  , poolAcquisitionTimeout :: Maybe Int
  -- ^ Acquisition timeout, in microseconds.
  , poolConnectionQueue :: TQueue Connection
  -- ^ Avail connections.
  , poolCapacity :: TVar Int
  -- ^ Remaining capacity.
  -- The pool size limits the sum of poolCapacity, the length
  -- of poolConnectionQueue and the number of in-flight
  -- connections.
  , poolReuse :: TVar (TVar Bool)
  -- ^ Whether to return a connection to the pool.
  , queryCount :: TVar Int
  -- ^ Count of queries executed
  }

-- | A simple logging utility
logger :: String -> IO ()
logger msg = do
  now <- getZonedTime
  putStrLn $ show now <> " - " <> msg

{- | Create a connection-pool.

 No connections actually get established by this function. It is delegated
 to 'use'.
-}
acquire ::
  -- | Pool size.
  Int ->
  -- | Connection acquisition timeout in microseconds.
  Maybe Int ->
  -- | Connection settings.
  Connection.Settings ->
  IO Pool
acquire poolSize timeout connectionSettings =
  acquireDynamically poolSize timeout (pure connectionSettings)

{- | Create a connection-pool.

 In difference to 'acquire' new settings get fetched each time a connection
 is created. This may be useful for some security models.

 No connections actually get established by this function. It is delegated
 to 'use'.
-}
acquireDynamically ::
  -- | Pool size.
  Int ->
  -- | Connection acquisition timeout in microseconds.
  Maybe Int ->
  -- | Action fetching connection settings.
  IO Connection.Settings ->
  IO Pool
acquireDynamically poolSize timeout fetchConnectionSettings = do
  Pool fetchConnectionSettings timeout
    <$> newTQueueIO
    <*> newTVarIO poolSize
    <*> (newTVarIO =<< newTVarIO True)
    <*> newTVarIO 0

{- | Release all the idle connections in the pool, and mark the in-use connections
 to be released after use. Any connections acquired after the call will be
 freshly established.

 The pool remains usable after this action.
 So you can use this function to reset the connections in the pool.
 Naturally, you can also use it to release the resources.
-}
release :: Pool -> IO ()
release Pool{..} =
  join . atomically $ do
    prevReuse <- readTVar poolReuse
    writeTVar prevReuse False
    newReuse <- newTVar True
    writeTVar poolReuse newReuse
    conns <- flushTQueue poolConnectionQueue
    modifyTVar' poolCapacity (+ (length conns))
    return $ forM_ conns Connection.release

{- | Use a connection from the pool to run a session and return the connection
 to the pool, when finished.

 Session failing with a 'Session.ClientError' gets interpreted as a loss of
 connection. In such case the connection does not get returned to the pool
 and a slot gets freed up for a new connection to be established the next
 time one is needed. The error still gets returned from this function.
-}
use :: Pool -> Session.Session a -> IO (Either UsageError a)
use Pool{..} sess = do
  timeout <- case poolAcquisitionTimeout of
    Just delta -> do
      delay <- registerDelay delta
      return $ readTVar delay
    Nothing ->
      return $ return False
  join . atomically $ do
    reuseVar <- readTVar poolReuse
    connectionPoolEmpty <- isEmptyTQueue poolConnectionQueue
    cap <- readTVar poolCapacity
    let logState :: String -> IO ()
        logState msg = logger $ msg <> " - Connection pool empty: " <> show connectionPoolEmpty <> " - Available pool capacity: " <> show cap
    asum
      [ fmap (logState "Using existing connection" >>) $ readTQueue poolConnectionQueue <&> onConn reuseVar
      , fmap (logState "Attempting to create new connection" >>) do
          capVal <- readTVar poolCapacity
          if capVal > 0
            then do
              writeTVar poolCapacity $! pred capVal
              return $ onNewConn reuseVar
            else retry
      , fmap (logState "Using existing connection" >>) do
          timedOut <- timeout
          if timedOut
            then return . return . Left $ AcquisitionTimeoutUsageError
            else retry
      ]
 where
  onNewConn reuseVar = do
    settings <- poolFetchConnectionSettings
    connRes <- Connection.acquire settings
    case connRes of
      Left connErr -> do
        atomically $ modifyTVar' poolCapacity succ
        return $ Left $ ConnectionUsageError connErr
      Right conn -> onConn reuseVar conn
  onConn reuseVar conn = do
    count <- atomically $ do
      modifyTVar' queryCount succ
      readTVar queryCount
    logger $ "Query count is: " <> show count
    catch (do
      sessRes <- Session.run sess conn
      case sessRes of
        Left err -> case err of
          Session.QueryError _ _ (Session.ClientError _) -> do
            logger $ "QueryError: Increasing pool capacity - " <> displayException err
            atomically $ modifyTVar' poolCapacity succ
            return $ Left $ SessionUsageError err
          _ -> do
            logger $ "Unknown error: Returning connection - " <> displayException err
            returnConn
            return $ Left $ SessionUsageError err
        Right res -> do
          logger "Query completed successfully: Returning connection"
          returnConn
          return $ Right res)
      (\(err :: SomeException ) -> do
        logger $ "Exception: Returning capacity to pool - " <> displayException err
        atomically $ modifyTVar' poolCapacity succ
        throw err)
   where
    returnConn =
      join . atomically $ do
        reuse <- readTVar reuseVar
        if reuse
          then fmap (logger "Returning connection to pool" >>) $ writeTQueue poolConnectionQueue conn $> return ()
          else do
            modifyTVar' poolCapacity succ
            return $ fmap (logger "Releasing connection" >>) Connection.release conn

-- | Union over all errors that 'use' can result in.
data UsageError
  = -- | Attempt to establish a connection failed.
    ConnectionUsageError Connection.ConnectionError
  | -- | Session execution failed.
    SessionUsageError Session.QueryError
  | -- | Timeout acquiring a connection.
    AcquisitionTimeoutUsageError
  deriving (Show, Eq)

instance Exception UsageError
