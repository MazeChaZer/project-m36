{-# LANGUAGE DeriveAnyClass, DeriveGeneric, ScopedTypeVariables #-}
module ProjectM36.Client
       (ConnectionInfo(..),
       Connection(..),
       Port,
       Hostname,
       DatabaseName,
       ConnectionError,
       connectProjectM36,
       close,
       closeRemote_,
       executeRelationalExpr,
       executeDatabaseContextExpr,
       executeDatabaseContextIOExpr,       
       executeGraphExpr,
       executeSchemaExpr,
       executeTransGraphRelationalExpr,
       commit,
       rollback,
       typeForRelationalExpr,
       inclusionDependencies,
       planForDatabaseContextExpr,
       processPersistence,
       currentSchemaName,
       SchemaName,
       HeadName,
       setCurrentSchemaName,
       transactionGraphAsRelation,
       relationVariablesAsRelation,
       headName,
       remoteDBLookupName,
       defaultServerPort,
       headTransactionId,
       defaultDatabaseName,
       defaultRemoteConnectionInfo,
       defaultHeadName,
       PersistenceStrategy(..),
       RelationalExpr,
       RelationalExprBase(..),
       DatabaseContextExpr(..),
       Attribute(..),
       attributesFromList,
       createNodeId,
       createSessionAtCommit,
       createSessionAtHead,
       closeSession,
       addClientNode,
       callTestTimeout_,
       RelationCardinality(..),
       TransactionGraphOperator(..),
       transactionGraph_,
       disconnectedTransaction_,
       TransGraphRelationalExpr,
       TransactionIdLookup(..),
       TransactionIdHeadBacktrack(..),
       NodeId(..),
       Atom(..),
       Session,
       SessionId,
       NotificationCallback,
       emptyNotificationCallback,
       EvaluatedNotification(..),
       atomTypesAsRelation,
       AttributeExpr,
       inclusionDependencyForKey,
       AttributeExprBase(..),
       TypeConstructor(..),
       TypeConstructorDef(..),
       DataConstructorDef(..),
       AttributeNames(..),
       RelVarName,
       IncDepName,
       InclusionDependency(..),
       AttributeName,
       RequestTimeoutException(..),
       RemoteProcessDiedException(..),
       AtomType(..)) where
import ProjectM36.Base hiding (inclusionDependencies) --defined in this module as well
import qualified ProjectM36.Base as B
import ProjectM36.Error
import ProjectM36.StaticOptimizer.DatabaseContextExpression
import ProjectM36.Key
import qualified ProjectM36.IsomorphicSchema as Schema
import Control.Monad.State
import qualified ProjectM36.RelationalExpression as RE
import qualified ProjectM36.RelationalExpressionState as RES
import ProjectM36.InclusionDependencyValidation
import qualified ProjectM36.DatabaseContextExpression as DCE
import ProjectM36.DatabaseContextState
import ProjectM36.DatabaseContext (basicDatabaseContext)
import qualified ProjectM36.DatabaseContext as DC
import ProjectM36.TransactionGraph
import qualified ProjectM36.Transaction as Trans
import ProjectM36.TransactionGraph.Persist
import ProjectM36.Attribute hiding (atomTypes)
import ProjectM36.TransGraphRelationalExpression (TransGraphRelationalExpr, evalTransGraphRelationalExpr)
import ProjectM36.Persist (DiskSync(..))
import ProjectM36.Notifications
import ProjectM36.Server.RemoteCallTypes
import qualified ProjectM36.DisconnectedTransaction as Discon
import ProjectM36.Relation (typesAsRelation)
import ProjectM36.AtomFunctionBody (initScriptSession, ScriptSession)
import qualified ProjectM36.Relation as R
import Network.Transport (Transport(closeTransport))
import Network.Transport.TCP (createTransport, defaultTCPParameters, encodeEndPointAddress)
import Control.Distributed.Process.Node (newLocalNode, initRemoteTable, runProcess, LocalNode, forkProcess, closeLocalNode)
import Control.Distributed.Process.Extras.Internal.Types (whereisRemote)
import Control.Distributed.Process.ManagedProcess.Client (call, safeCall)
import Control.Distributed.Process (NodeId(..), reconnect)

import Data.UUID.V4 (nextRandom)
import Control.Concurrent.STM
import Data.Word
import Control.Distributed.Process (ProcessId, Process, receiveWait, send, match)
import Control.Exception (IOException, handle, AsyncException, throwIO, fromException, Exception)
import Control.Concurrent.MVar
import qualified Data.Map as M
import Control.Distributed.Process.Serializable (Serializable)
import qualified STMContainers.Map as STMMap
import qualified STMContainers.Set as STMSet
import qualified ProjectM36.Session as Sess
import ProjectM36.Session
import ProjectM36.Sessions
import ListT
import Data.Binary (Binary)
import GHC.Generics (Generic)
import Control.DeepSeq (force)
import System.IO

type Hostname = String

type Port = Word16

type DatabaseName = String

-- | The type for notifications callbacks in the client. When a registered notification fires due to a changed relational expression evaluation, the server propagates the notifications to the clients in the form of the callback.
type NotificationCallback = NotificationName -> EvaluatedNotification -> IO ()

-- | The empty notification callback ignores all callbacks.
emptyNotificationCallback :: NotificationCallback
emptyNotificationCallback _ _ = pure ()

type GhcPkgPath = String

data RemoteProcessDiedException = RemoteProcessDiedException
                                  deriving (Show, Eq)
                                           
instance Exception RemoteProcessDiedException                                          
  
data RequestTimeoutException = RequestTimeoutException
                             deriving (Show, Eq)

instance Exception RequestTimeoutException

-- | Construct a 'ConnectionInfo' to describe how to make the 'Connection'.
data ConnectionInfo = InProcessConnectionInfo PersistenceStrategy NotificationCallback [GhcPkgPath]|
                      RemoteProcessConnectionInfo DatabaseName NodeId NotificationCallback
                      
type EvaluatedNotifications = M.Map NotificationName EvaluatedNotification

-- | Used for callbacks from the server when monitored changes have been made.
data NotificationMessage = NotificationMessage EvaluatedNotifications
                           deriving (Binary, Eq, Show, Generic)

-- | When a notification is fired, the 'reportExpr' is evaluated in the commit's context, so that is returned along with the original notification.
data EvaluatedNotification = EvaluatedNotification {
  notification :: Notification,
  reportRelation :: Either RelationalError Relation
  }
                           deriving(Binary, Eq, Show, Generic)
                      
createNodeId :: Hostname -> Port -> NodeId                      
createNodeId host port = NodeId $ encodeEndPointAddress host (show port) 1
                      
defaultServerPort :: Port
defaultServerPort = 6543

defaultDatabaseName :: DatabaseName
defaultDatabaseName = "base"

defaultHeadName :: HeadName
defaultHeadName = "master"

defaultRemoteConnectionInfo :: ConnectionInfo
defaultRemoteConnectionInfo = RemoteProcessConnectionInfo defaultDatabaseName (createNodeId "127.0.0.1" defaultServerPort) emptyNotificationCallback 

-- | The 'Connection' represents either local or remote access to a database. All operations flow through the connection.
type ClientNodes = STMSet.Set ProcessId

-- internal structure specific to in-process connections
data InProcessConnectionConf = InProcessConnectionConf {
  ipPersistenceStrategy :: PersistenceStrategy, 
  ipClientNodes :: ClientNodes, 
  ipSessions :: Sessions, 
  ipTransactionGraph :: TVar TransactionGraph,
  ipScriptSession :: Maybe ScriptSession,
  ipLocalNode :: LocalNode,
  ipTransport :: Transport -- we hold onto this so that we can close it gracefully
  }

data RemoteProcessConnectionConf = RemoteProcessConnectionConf {
  rLocalNode :: LocalNode, 
  rProcessId :: ProcessId, --remote processId
  rTransport :: Transport-- the TCP socket transport
  }
  
data Connection = InProcessConnection InProcessConnectionConf |
                  RemoteProcessConnection RemoteProcessConnectionConf
                  
-- | There are several reasons why a connection can fail.
data ConnectionError = SetupDatabaseDirectoryError PersistenceError |
                       IOExceptionError IOException |
                       NoSuchDatabaseByNameError DatabaseName |
                       LoginError 
                       deriving (Show, Eq, Generic)
                  
remoteDBLookupName :: DatabaseName -> String    
remoteDBLookupName = (++) "db-" 

createLocalNode :: IO (LocalNode, Transport)
createLocalNode = do
  eLocalTransport <- createTransport "127.0.0.1" "0" defaultTCPParameters
  case eLocalTransport of
    Left err -> error ("failed to create transport: " ++ show err)
    Right localTransport -> do
      localNode <- newLocalNode localTransport initRemoteTable 
      pure (localNode, localTransport)
    
notificationListener :: NotificationCallback -> Process ()    
notificationListener callback = do
  --pid <- getSelfPid
  --liftIO $ putStrLn $ "LISTENER THREAD START " ++ show pid
  _ <- forever $ do  
    receiveWait [
      match (\(NotificationMessage eNots) -> do
            --say $ "NOTIFICATION: " ++ show eNots
            -- when notifications are thrown, they are not adjusted for the current schema which could be problematic, but we don't have access to the current session here
            liftIO $ mapM_ (uncurry callback) (M.toList eNots)
            )
      ]
  --say "LISTENER THREAD EXIT"
  pure ()
  
startNotificationListener :: LocalNode -> NotificationCallback -> IO (ProcessId)
startNotificationListener localNode callback = forkProcess localNode (notificationListener callback)
  
createScriptSession :: [String] -> IO (Maybe ScriptSession)  
createScriptSession ghcPkgPaths = do
  eScriptSession <- initScriptSession ghcPkgPaths
  case eScriptSession of
    Left err -> hPutStrLn stderr ("Failed to load scripting engine- scripting disabled: " ++ (show err)) >> pure Nothing --not a fatal error, but the scripting feature must be disabled
    Right s -> pure (Just s)

-- | To create a 'Connection' to a remote or local database, create a connectionInfo and call 'connectProjectM36'.
connectProjectM36 :: ConnectionInfo -> IO (Either ConnectionError Connection)
--create a new in-memory database/transaction graph
connectProjectM36 (InProcessConnectionInfo strat notificationCallback ghcPkgPaths) = do
  freshId <- nextRandom
  let bootstrapContext = basicDatabaseContext 
      freshGraph = bootstrapTransactionGraph freshId bootstrapContext
  case strat of
    --create date examples graph for now- probably should be empty context in the future
    NoPersistence -> do
        graphTvar <- newTVarIO freshGraph
        clientNodes <- STMSet.newIO
        sessions <- STMMap.newIO
        (localNode, transport) <- createLocalNode
        notificationPid <- startNotificationListener localNode notificationCallback
        mScriptSession <- createScriptSession ghcPkgPaths
        let conn = InProcessConnection (InProcessConnectionConf {
                                           ipPersistenceStrategy =strat, 
                                           ipClientNodes = clientNodes, 
                                           ipSessions = sessions, 
                                           ipTransactionGraph = graphTvar, 
                                           ipScriptSession = mScriptSession,
                                           ipLocalNode = localNode,
                                           ipTransport = transport })
        addClientNode conn notificationPid
        pure (Right conn)
    MinimalPersistence dbdir -> connectPersistentProjectM36 strat NoDiskSync dbdir freshGraph notificationCallback ghcPkgPaths
    CrashSafePersistence dbdir -> connectPersistentProjectM36 strat FsyncDiskSync dbdir freshGraph notificationCallback ghcPkgPaths
        
connectProjectM36 (RemoteProcessConnectionInfo databaseName serverNodeId notificationCallback) = do
  connStatus <- newEmptyMVar
  (localNode, transport) <- createLocalNode
  let dbName = remoteDBLookupName databaseName
  --putStrLn $ "Connecting to " ++ show serverNodeId ++ " " ++ dbName
  notificationListenerPid <- startNotificationListener localNode notificationCallback
  runProcess localNode $ do
    --even a failed connection retains an open socket!
    mServerProcessId <- whereisRemote serverNodeId dbName
    case mServerProcessId of
      Nothing -> liftIO $ putMVar connStatus $ Left (NoSuchDatabaseByNameError databaseName)
      Just serverProcessId -> do
        loginConfirmation <- safeLogin (Login notificationListenerPid) serverProcessId
        if not loginConfirmation then
          liftIO $ putMVar connStatus (Left LoginError)
          else do
          liftIO $ putMVar connStatus (Right $ RemoteProcessConnection (RemoteProcessConnectionConf {rLocalNode = localNode, rProcessId = serverProcessId, rTransport = transport}))
  status <- takeMVar connStatus
  pure status

connectPersistentProjectM36 :: PersistenceStrategy ->
                               DiskSync ->
                               FilePath -> 
                               TransactionGraph ->
                               NotificationCallback ->
                               [GhcPkgPath] -> 
                               IO (Either ConnectionError Connection)      
connectPersistentProjectM36 strat sync dbdir freshGraph notificationCallback ghcPkgPaths = do
  err <- setupDatabaseDir sync dbdir freshGraph 
  case err of
    Just err' -> return $ Left (SetupDatabaseDirectoryError err')
    Nothing -> do 
      graph <- transactionGraphLoad dbdir emptyTransactionGraph
      case graph of
        Left err' -> return $ Left (SetupDatabaseDirectoryError err')
        Right graph' -> do
          tvarGraph <- newTVarIO graph'
          sessions <- STMMap.newIO
          clientNodes <- STMSet.newIO
          mScriptSession <- createScriptSession ghcPkgPaths
          (localNode, transport) <- createLocalNode
          let conn = InProcessConnection (InProcessConnectionConf {
                                             ipPersistenceStrategy = strat,
                                             ipClientNodes = clientNodes,
                                             ipSessions = sessions,
                                             ipTransactionGraph = tvarGraph,
                                             ipScriptSession = mScriptSession,
                                             ipLocalNode = localNode,
                                             ipTransport = transport
                                             })

          notificationPid <- startNotificationListener localNode notificationCallback 
          addClientNode conn notificationPid
          pure (Right conn)
          
-- | Create a new session at the transaction id and return the session's Id.
createSessionAtCommit :: TransactionId -> Connection -> IO (Either RelationalError SessionId)
createSessionAtCommit commitId conn@(InProcessConnection _) = do
   newSessionId <- nextRandom
   atomically $ do
      createSessionAtCommit_ commitId newSessionId conn
createSessionAtCommit uuid conn@(RemoteProcessConnection _) = remoteCall conn (CreateSessionAtCommit uuid)

createSessionAtCommit_ :: TransactionId -> SessionId -> Connection -> STM (Either RelationalError SessionId)
createSessionAtCommit_ commitId newSessionId (InProcessConnection conf) = do
    let sessions = ipSessions conf
        graphTvar = ipTransactionGraph conf
    graph <- readTVar graphTvar
    case transactionForId commitId graph of
        Left err -> pure (Left err)
        Right transaction -> do
            let freshDiscon = DisconnectedTransaction commitId (Trans.schemas transaction) 
            keyDuplication <- STMMap.lookup newSessionId sessions
            case keyDuplication of
                Just _ -> pure $ Left (SessionIdInUseError newSessionId)
                Nothing -> do
                   STMMap.insert (Session freshDiscon defaultSchemaName) newSessionId sessions
                   pure $ Right newSessionId
createSessionAtCommit_ _ _ (RemoteProcessConnection _) = error "createSessionAtCommit_ called on remote connection"
  
-- | Call 'createSessionAtHead' with a transaction graph's head's name to create a new session pinned to that head. This function returns a 'SessionId' which can be used in other function calls to reference the point in the transaction graph.
createSessionAtHead :: HeadName -> Connection -> IO (Either RelationalError SessionId)
createSessionAtHead headn conn@(InProcessConnection conf) = do
    let graphTvar = ipTransactionGraph conf
    newSessionId <- nextRandom
    atomically $ do
        graph <- readTVar graphTvar
        case transactionForHead headn graph of
            Nothing -> pure $ Left (NoSuchHeadNameError headn)
            Just trans -> createSessionAtCommit_ (transactionId trans) newSessionId conn
createSessionAtHead headn conn@(RemoteProcessConnection _) = remoteCall conn (CreateSessionAtHead headn)

-- | Used internally for server connections to keep track of remote nodes for the purpose of sending notifications later.
addClientNode :: Connection -> ProcessId -> IO ()
addClientNode (RemoteProcessConnection _) _ = error "addClientNode called on remote connection"
addClientNode (InProcessConnection conf) newProcessId = atomically (STMSet.insert newProcessId (ipClientNodes conf))

-- | Discards a session, eliminating any uncommitted changes present in the session.
closeSession :: SessionId -> Connection -> IO ()
closeSession sessionId (InProcessConnection conf) = do
    atomically $ STMMap.delete sessionId (ipSessions conf)
closeSession sessionId conn@(RemoteProcessConnection _) = remoteCall conn (CloseSession sessionId)       
-- | 'close' cleans up the database access connection. Note that sessions persist even after the connection is closed.              
close :: Connection -> IO ()
close (InProcessConnection conf) = do
  atomically $ do
    let sessions = ipSessions conf
    traverse_ (\(k,_) -> STMMap.delete k sessions) (STMMap.stream sessions)
    pure ()
  closeLocalNode (ipLocalNode conf)
  closeTransport (ipTransport conf)

close conn@(RemoteProcessConnection conf) = do
  _ <- (remoteCall conn Logout) :: IO Bool
  --putStrLn ("closing " ++ show (localNodeId (rLocalNode conf)))

  closeLocalNode (rLocalNode conf)
  closeTransport (rTransport conf)

--used only by the server EntryPoints
closeRemote_ :: Connection -> IO ()
closeRemote_ (InProcessConnection _) = error "invalid call of closeRemote_ on InProcessConnection"
closeRemote_ (RemoteProcessConnection conf) = runProcess (rLocalNode conf) (reconnect (rProcessId conf))

  --we need to actually close the localNode's connection to the remote
--within the database server, we must catch and handle all exception lest they take down the database process- this handling might be different for other use-cases
--exceptions should generally *NOT* be thrown from any Project:M36 code paths, but third-party code such as AtomFunction scripts could conceivably throw undefined, etc.

excMaybe :: IO (Maybe RelationalError) -> IO (Maybe RelationalError)
excMaybe m = handle handler m
  where
    handler exc | Just (_ :: AsyncException) <- fromException exc = throwIO exc
                | otherwise = pure (Just (UnhandledExceptionError (show exc)))
                    
excEither :: IO (Either RelationalError a) -> IO (Either RelationalError a)
excEither m = handle handler m
  where
    handler exc | Just (_ :: AsyncException) <- fromException exc = throwIO exc
                | otherwise = pure (Left (UnhandledExceptionError (show exc)))
      
runProcessResult :: LocalNode -> Process a -> IO a      
runProcessResult localNode proc = do
  ret <- newEmptyMVar
  runProcess localNode $ do
    val <- proc
    liftIO $ putMVar ret val
  takeMVar ret

safeLogin :: Login -> ProcessId -> Process (Bool)
safeLogin login procId = do 
  ret <- call procId login
  case ret of
    Left (_ :: ServerError) -> pure False
    Right val -> pure val

remoteCall :: (Serializable a, Serializable b) => Connection -> a -> IO b
remoteCall (InProcessConnection _ ) _ = error "remoteCall called on local connection"
remoteCall (RemoteProcessConnection conf) arg = runProcessResult localNode $ do
  ret <- safeCall serverProcessId arg
  case ret of
    Left err -> error ("server died: " ++ show err)
    Right ret' -> case ret' of
                       Left RequestTimeoutError -> liftIO (throwIO RequestTimeoutException)
                       Left (ProcessDiedError _) -> liftIO (throwIO RemoteProcessDiedException)
                       Right val -> pure val
  where
    localNode = rLocalNode conf
    serverProcessId = rProcessId conf

sessionForSessionId :: SessionId -> Sessions -> STM (Either RelationalError Session)
sessionForSessionId sessionId sessions = do
  maybeSession <- STMMap.lookup sessionId sessions
  pure $ maybe (Left $ NoSuchSessionError sessionId) Right maybeSession
  
schemaForSessionId :: Session -> STM (Either RelationalError Schema)  
schemaForSessionId session = do
  let sname = schemaName session
  if sname == defaultSchemaName then
    pure (Right (Schema [])) -- the main schema includes no transformations (but neither do empty schemas :/ )
    else
    case M.lookup sname (subschemas session) of
      Nothing -> pure (Left (SubschemaNameNotInUseError sname))
      Just schema -> pure (Right schema)
  
sessionAndSchema :: SessionId -> Sessions -> STM (Either RelationalError (Session, Schema))
sessionAndSchema sessionId sessions = do
  eSession <- sessionForSessionId sessionId sessions
  case eSession of
    Left err -> pure (Left err)
    Right session -> do  
      eSchema <- schemaForSessionId session
      case eSchema of
        Left err -> pure (Left err)
        Right schema -> pure (Right (session, schema))
  
currentSchemaName :: SessionId -> Connection -> IO (Maybe SchemaName)
currentSchemaName sessionId (InProcessConnection conf) = atomically $ do
  let sessions = ipSessions conf
  eSession <- sessionForSessionId sessionId sessions
  case eSession of
    Left _ -> pure Nothing
    Right session -> pure (Just (Sess.schemaName session))
currentSchemaName sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveCurrentSchemaName sessionId)

setCurrentSchemaName :: SessionId -> Connection -> SchemaName -> IO (Maybe RelationalError)
setCurrentSchemaName sessionId (InProcessConnection conf) sname = atomically $ do
  let sessions = ipSessions conf
  eSession <- sessionForSessionId sessionId sessions
  case eSession of
    Left _ -> pure Nothing
    Right session -> case Sess.setSchemaName sname session of
      Left err -> pure (Just err)
      Right newSession -> STMMap.insert newSession sessionId sessions >> pure Nothing
setCurrentSchemaName sessionId conn@(RemoteProcessConnection _) sname = remoteCall conn (ExecuteSetCurrentSchema sessionId sname)

-- | Execute a relational expression in the context of the session and connection. Relational expressions are queries and therefore cannot alter the database.
executeRelationalExpr :: SessionId -> Connection -> RelationalExpr -> IO (Either RelationalError Relation)
executeRelationalExpr sessionId (InProcessConnection conf) expr = excEither $ atomically $ do
  let sessions = ipSessions conf
  eSession <- sessionAndSchema sessionId sessions
  case eSession of
    Left err -> pure $ Left err
    Right (session, schema) -> do
      let expr' = if schemaName session /= defaultSchemaName then
                    Schema.processRelationalExprInSchema schema expr
                  else
                    Right expr
      case expr' of
        Left err -> pure (Left err)
        Right expr'' -> case evalState (RE.evalRelationalExpr expr'') (RES.mkRelationalExprState (Sess.concreteDatabaseContext session)) of
          Left err -> pure (Left err)
          Right rel -> pure (force (Right rel)) -- this is necessary so that any undefined/error exceptions are spit out here 
executeRelationalExpr sessionId conn@(RemoteProcessConnection _) relExpr = remoteCall conn (ExecuteRelationalExpr sessionId relExpr)

-- | Execute a database context expression in the context of the session and connection. Database expressions modify the current session's disconnected transaction but cannot modify the transaction graph.
executeDatabaseContextExpr :: SessionId -> Connection -> DatabaseContextExpr -> IO (Maybe RelationalError)
executeDatabaseContextExpr sessionId (InProcessConnection conf) expr = excMaybe $ atomically $ do
  let sessions = ipSessions conf
  eSession <- sessionAndSchema sessionId sessions
  case eSession of
    Left err -> pure $ Just err
    Right (session, schema) -> do
      let expr' = if schemaName session == defaultSchemaName then
                    Right expr
                  else
                    Schema.processDatabaseContextExprInSchema schema expr
      case expr' of 
        Left err -> pure (Just err)
        Right expr'' -> case runState (DCE.evalDatabaseContextExpr expr'') (defaultDatabaseContextEvalState (Sess.concreteDatabaseContext session)) of
          (Just err,_) -> return $ Just err
          (Nothing, evaldState) -> do
            let newDiscon = DisconnectedTransaction (Sess.parentId session) newSchemas
                newSubschemas = Schema.processDatabaseContextExprSchemasUpdate (Sess.subschemas session) expr
                newSchemas = Schemas (dbcontext evaldState) newSubschemas
                newSession = Session newDiscon (Sess.schemaName session)
            STMMap.insert newSession sessionId sessions
            pure Nothing
      
executeDatabaseContextExpr sessionId conn@(RemoteProcessConnection _) dbExpr = remoteCall conn (ExecuteDatabaseContextExpr sessionId dbExpr)

-- | Execute a database context IO-monad-based expression for the given session and connection. `DatabaseContextIOExpr` modify the DatabaseContext but cannot be purely implemented.
--this is almost completely identical to executeDatabaseContextExpr above
executeDatabaseContextIOExpr :: SessionId -> Connection -> DatabaseContextIOExpr -> IO (Maybe RelationalError)
executeDatabaseContextIOExpr sessionId (InProcessConnection conf) expr = excMaybe $ do
  let sessions = ipSessions conf
      scriptSession = ipScriptSession conf
  eSession <- atomically $ sessionForSessionId sessionId sessions --potentially race condition due to interleaved IO?
  case eSession of
    Left err -> pure $ Just err
    Right session -> do
      res <- DCE.evalDatabaseContextIOExpr scriptSession (Sess.concreteDatabaseContext session) expr
      case res of
        Left err -> pure (Just err)
        Right context' -> do
          let newDiscon = DisconnectedTransaction (Sess.parentId session) newSchemas
              newSchemas = Schemas context' (Sess.subschemas session)
              newSession = Session newDiscon (Sess.schemaName session)
          atomically $ STMMap.insert newSession sessionId sessions
          pure Nothing
executeDatabaseContextIOExpr sessionId conn@(RemoteProcessConnection _) dbExpr = remoteCall conn (ExecuteDatabaseContextIOExpr sessionId dbExpr)
         
executeGraphExprSTM_ :: TransactionId -> SessionId -> Sessions -> TransactionGraphOperator -> TVar TransactionGraph -> STM (Either RelationalError TransactionGraph)
executeGraphExprSTM_ freshId sessionId sessions graphExpr graphTvar = do
  graph <- readTVar graphTvar
  eSession <- sessionForSessionId sessionId sessions
  case eSession of
      Left err -> pure $ Left err
      Right session -> case evalGraphOp freshId (Sess.disconnectedTransaction session) graph graphExpr of
        Left err -> pure $ Left err
        Right (discon', graph') -> do
          writeTVar graphTvar graph'
          let newSession = Session discon' (Sess.schemaName session)
          STMMap.insert newSession sessionId sessions
          pure $ Right graph'
  
-- process notifications for commits
executeCommitExprSTM_ :: DatabaseContext -> DatabaseContext -> ClientNodes -> STM (EvaluatedNotifications, ClientNodes)
executeCommitExprSTM_ oldContext newContext nodes = do
  let nots = notifications oldContext
      fireNots = notificationChanges nots oldContext newContext 
      evaldNots = M.map mkEvaldNot fireNots
      mkEvaldNot notif = EvaluatedNotification { notification = notif, reportRelation = evalState (RE.evalRelationalExpr (reportExpr notif)) (RES.mkRelationalExprState oldContext) }
  pure (evaldNots, nodes)
                

-- | Execute a transaction graph expression in the context of the session and connection. Transaction graph operators modify the transaction graph state.
executeGraphExpr :: SessionId -> Connection -> TransactionGraphOperator -> IO (Maybe RelationalError)
executeGraphExpr sessionId (InProcessConnection conf) graphExpr = excMaybe $ do
  let strat = ipPersistenceStrategy conf
      clientNodes = ipClientNodes conf
      sessions = ipSessions conf
      graphTvar = ipTransactionGraph conf
  freshId <- nextRandom
  manip <- atomically $ do
    eSession <- sessionForSessionId sessionId sessions
    oldGraph <- readTVar graphTvar
    case eSession of
      Left err -> pure (Left err)
      Right session -> do
        eGraph <- executeGraphExprSTM_ freshId sessionId sessions graphExpr graphTvar
        case eGraph of
          Left err -> pure (Left err)
          Right newGraph -> do
            if graphExpr == Commit then
              case transactionForId (Sess.parentId session) oldGraph of
                Left err -> pure $ Left err
                Right previousTrans -> do
                  (evaldNots, nodes) <- executeCommitExprSTM_ (Trans.concreteDatabaseContext previousTrans) (Sess.concreteDatabaseContext session) clientNodes
                  nodesToNotify <- toList (STMSet.stream nodes)                  
                  pure $ Right (evaldNots, nodesToNotify, newGraph)
            else
              pure $ Right (M.empty, [], newGraph)
  case manip of 
    Left err -> return $ Just err
    Right (notsToFire, nodesToNotify, newGraph) -> do
      --update filesystem database, if necessary
      --this should really grab a lock at the beginning of the method to be threadsafe
      processPersistence strat newGraph
      sendNotifications nodesToNotify (ipLocalNode conf) notsToFire
      return Nothing
executeGraphExpr sessionId conn@(RemoteProcessConnection _) graphExpr = remoteCall conn (ExecuteGraphExpr sessionId graphExpr)

{-
commitSTM_ :: UUID -> SessionId -> Sessions -> TVar TransactionGraph -> STM (Maybe RelationalError)
commitSTM_ freshUUID sessionId sessions graph = do
  mErr <- executeGraphExprSTM_ freshUUID sessionId sessions Commit graph
  pure $ case mErr of
    Left err -> Just err
    Right _ -> Nothing
-}

-- | A trans-graph expression is a relational query executed against the entirety of a transaction graph.
executeTransGraphRelationalExpr :: SessionId -> Connection -> TransGraphRelationalExpr -> IO (Either RelationalError Relation)
executeTransGraphRelationalExpr _ (InProcessConnection conf) tgraphExpr = excEither . atomically $ do
  let graphTvar = ipTransactionGraph conf
  graph <- readTVar graphTvar
  case evalTransGraphRelationalExpr tgraphExpr graph of
    Left err -> pure (Left err)
    Right relExpr -> case evalState (RE.evalRelationalExpr relExpr) (RES.mkRelationalExprState DC.empty) of
      Left err -> pure (Left err)
      Right rel -> pure (force (Right rel))
executeTransGraphRelationalExpr sessionId conn@(RemoteProcessConnection _) tgraphExpr = remoteCall conn (ExecuteTransGraphRelationalExpr sessionId tgraphExpr)  

executeSchemaExpr :: SessionId -> Connection -> Schema.SchemaExpr -> IO (Maybe RelationalError)
executeSchemaExpr sessionId (InProcessConnection conf) schemaExpr = atomically $ do
  let sessions = ipSessions conf
  eSession <- sessionAndSchema sessionId sessions  
  case eSession of
    Left err -> pure (Just err)
    Right (session, _) -> do
      let subschemas' = subschemas session
      case runState (Schema.evalSchemaExpr schemaExpr subschemas') (defaultDatabaseContextEvalState (Sess.concreteDatabaseContext session))  of
        (Left err, _) -> pure (Just err)
        (Right newSubschemas, evaldState) -> do
          --hm- maybe we should start using lenses
          let discon = Sess.disconnectedTransaction session 
              newSchemas = Schemas (dbcontext evaldState) newSubschemas
              newSession = Session (DisconnectedTransaction (Discon.parentId discon) newSchemas) (Sess.schemaName session)
          STMMap.insert newSession sessionId sessions
          pure Nothing
executeSchemaExpr sessionId conn@(RemoteProcessConnection _) schemaExpr = remoteCall conn (ExecuteSchemaExpr sessionId schemaExpr)          

-- | After modifying a session, 'commit' the transaction to the transaction graph at the head which the session is referencing. This will also trigger checks for any notifications which need to be propagated.
commit :: SessionId -> Connection -> IO (Maybe RelationalError)
commit sessionId conn@(InProcessConnection _) = executeGraphExpr sessionId conn Commit
commit sessionId conn@(RemoteProcessConnection _) = remoteCall conn (ExecuteGraphExpr sessionId Commit)
  
sendNotifications :: [ProcessId] -> LocalNode -> EvaluatedNotifications -> IO ()
sendNotifications pids localNode nots = mapM_ sendNots pids
  where
    sendNots remoteClientPid = do
      when (not (M.null nots)) $ runProcess localNode $ send remoteClientPid (NotificationMessage nots)
          
-- | Discard any changes made in the current session. This resets the disconnected transaction to reference the original database context of the parent transaction and is a very cheap operation.
rollback :: SessionId -> Connection -> IO (Maybe RelationalError)
rollback sessionId conn@(InProcessConnection _) = executeGraphExpr sessionId conn Rollback      
rollback sessionId conn@(RemoteProcessConnection _) = remoteCall conn (ExecuteGraphExpr sessionId Rollback)

processPersistence :: PersistenceStrategy -> TransactionGraph -> IO ()
processPersistence NoPersistence _ = return ()
processPersistence (MinimalPersistence dbdir) graph = transactionGraphPersist NoDiskSync dbdir graph
processPersistence (CrashSafePersistence dbdir) graph = transactionGraphPersist FsyncDiskSync dbdir graph

-- | Return a relation whose type would match that of the relational expression if it were executed. This is useful for checking types and validating a relational expression's types.
typeForRelationalExpr :: SessionId -> Connection -> RelationalExpr -> IO (Either RelationalError Relation)
typeForRelationalExpr sessionId conn@(InProcessConnection _) relExpr = atomically $ typeForRelationalExprSTM sessionId conn relExpr
typeForRelationalExpr sessionId conn@(RemoteProcessConnection _) relExpr = remoteCall conn (ExecuteTypeForRelationalExpr sessionId relExpr)
    
typeForRelationalExprSTM :: SessionId -> Connection -> RelationalExpr -> STM (Either RelationalError Relation)    
typeForRelationalExprSTM sessionId (InProcessConnection conf) relExpr = do
  let sessions = ipSessions conf
  eSession <- sessionAndSchema sessionId sessions
  case eSession of
    Left err -> pure $ Left err
    Right (session, schema) -> do
      let processed = if schemaName session == defaultSchemaName then
                       Right relExpr
                     else
                       Schema.processRelationalExprInSchema schema relExpr
      case processed of
        Left err -> pure (Left err)
        Right relExpr' -> pure $ evalState (RE.typeForRelationalExpr relExpr') (RES.mkRelationalExprState (Sess.concreteDatabaseContext session))
    
typeForRelationalExprSTM _ _ _ = error "typeForRelationalExprSTM called on non-local connection"

-- | Return a 'Map' of the database's constraints at the context of the session and connection.
inclusionDependencies :: SessionId -> Connection -> IO (Either RelationalError InclusionDependencies)
inclusionDependencies sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
  atomically $ do
    eSession <- sessionAndSchema sessionId sessions
    case eSession of
      Left err -> pure $ Left err 
      Right (session, schema) -> do
            let context' = Sess.concreteDatabaseContext session
            if schemaName session == defaultSchemaName then
              pure $ Right (B.inclusionDependencies context')
              else
              pure (Schema.inclusionDependenciesInSchema schema (B.inclusionDependencies context'))

inclusionDependencies sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveInclusionDependencies sessionId)

-- | Return an optimized database expression which is logically equivalent to the input database expression. This function can be used to determine which expression will actually be evaluated.
planForDatabaseContextExpr :: SessionId -> Connection -> DatabaseContextExpr -> IO (Either RelationalError DatabaseContextExpr)  
planForDatabaseContextExpr sessionId (InProcessConnection conf) dbExpr = do
  let sessions = ipSessions conf
  atomically $ do
    eSession <- sessionAndSchema sessionId sessions
    case eSession of
      Left err -> pure $ Left err 
      Right (session, _) -> if schemaName session == defaultSchemaName then
                                   pure $ evalState (applyStaticDatabaseOptimization dbExpr) (defaultDatabaseContextEvalState (Sess.concreteDatabaseContext session))
                                 else -- don't show any optimization because the current optimization infrastructure relies on access to the base context- this probably underscores the need for each schema to have its own DatabaseContext, even if it is generated on-the-fly
                                   pure (Right dbExpr)

planForDatabaseContextExpr sessionId conn@(RemoteProcessConnection _) dbExpr = remoteCall conn (RetrievePlanForDatabaseContextExpr sessionId dbExpr)
             
-- | Return a relation which represents the current state of the global transaction graph. The attributes are 
-- * current- boolean attribute representing whether or not the current session references this transaction
-- * head- text attribute which is a non-empty 'HeadName' iff the transaction references a head.
-- * id- id attribute of the transaction
-- * parents- a relation-valued attribute which contains a relation of transaction ids which are parent transaction to the transaction
transactionGraphAsRelation :: SessionId -> Connection -> IO (Either RelationalError Relation)
transactionGraphAsRelation sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
      tvar = ipTransactionGraph conf
  atomically $ do
    eSession <- sessionForSessionId sessionId sessions
    case eSession of
      Left err -> pure $ Left err
      Right session -> do
        graph <- readTVar tvar
        pure $ graphAsRelation (Sess.disconnectedTransaction session) graph
    
transactionGraphAsRelation sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveTransactionGraph sessionId) 

relationVariablesAsRelation :: SessionId -> Connection -> IO (Either RelationalError Relation)
relationVariablesAsRelation sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
  atomically $ do
    eSession <- sessionAndSchema sessionId sessions
    case eSession of
      Left err -> pure (Left err)
      Right (session, schema) -> do
        let context' = Sess.concreteDatabaseContext session
        if Sess.schemaName session == defaultSchemaName then
          pure $ R.relationVariablesAsRelation (relationVariables context')
          else
          case Schema.relationVariablesInSchema schema context' of
            Left err -> pure (Left err)
            Right relvars -> pure $ R.relationVariablesAsRelation relvars
      
relationVariablesAsRelation sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveRelationVariableSummary sessionId)      

-- | Returns the transaction id for the connection's disconnected transaction committed parent transaction.  
headTransactionId :: SessionId -> Connection -> IO (Maybe TransactionId)
headTransactionId sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf  
  atomically $ do
    eSession <- sessionForSessionId sessionId sessions
    case eSession of
      Left _ -> pure Nothing
      Right session -> pure $ Just (Sess.parentId session)
headTransactionId sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveHeadTransactionId sessionId)
    
headNameSTM_ :: SessionId -> Sessions -> TVar TransactionGraph -> STM (Maybe HeadName)  
headNameSTM_ sessionId sessions graphTvar = do
    graph <- readTVar graphTvar
    eSession <- sessionForSessionId sessionId sessions
    case eSession of
      Left _ -> pure $ Nothing
      Right session -> pure $ case transactionForId (Sess.parentId session) graph of
        Left _ -> Nothing
        Right parentTrans -> headNameForTransaction parentTrans graph
  
-- | Returns Just the name of the head of the current disconnected transaction or Nothing.    
headName :: SessionId -> Connection -> IO (Maybe HeadName)
headName sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
      graphTvar = ipTransactionGraph conf
  atomically (headNameSTM_ sessionId sessions graphTvar)
headName sessionId conn@(RemoteProcessConnection _) = remoteCall conn (ExecuteHeadName sessionId)

atomTypesAsRelation :: SessionId -> Connection -> IO (Either RelationalError Relation)
atomTypesAsRelation sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
  atomically $ do
    eSession <- sessionForSessionId sessionId sessions
    case eSession of
      Left err -> pure (Left err)
      Right session -> do
        case typesAsRelation (typeConstructorMapping (Sess.concreteDatabaseContext session)) of
          Left err -> pure (Left err)
          Right rel -> pure (Right rel)
atomTypesAsRelation sessionId conn@(RemoteProcessConnection _) = remoteCall conn (RetrieveAtomTypesAsRelation sessionId)
        
--used only for testing- we expect this to throw an exception
callTestTimeout_ :: SessionId -> Connection -> IO Bool
callTestTimeout_ _ (InProcessConnection _) = error "bad testing call"
callTestTimeout_ sessionId conn@(RemoteProcessConnection _) = remoteCall conn (TestTimeout sessionId)

--used in tests only
transactionGraph_ :: Connection -> IO TransactionGraph
transactionGraph_ (InProcessConnection conf) = atomically $ readTVar (ipTransactionGraph conf)
transactionGraph_ _ = error "remote connection used"

--used in tests only
disconnectedTransaction_ :: SessionId -> Connection -> IO DisconnectedTransaction
disconnectedTransaction_ sessionId (InProcessConnection conf) = do
  let sessions = ipSessions conf
  mSession <- atomically $ do
    STMMap.lookup sessionId sessions
  case mSession of
    Nothing -> error "No such session"
    Just (Sess.Session discon _) -> pure discon
disconnectedTransaction_ _ _= error "remote connection used"

--includes standard constraint validator
defaultDatabaseContextEvalState :: DatabaseContext -> DatabaseContextEvalState
defaultDatabaseContextEvalState context = DatabaseContextEvalState {
  dbcontext = context,
  constraintValidator = checkConstraints
  }