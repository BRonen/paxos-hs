module Paxos
  ( app
  ) where

import qualified Data.Text.Lazy as T
import qualified Data.ByteString.Lazy.UTF8 as BLU

import Web.Scotty (ActionM, jsonData, get, post, html, text, status, pathParam, scotty, liftIO)
import Network.HTTP.Types.Status (notImplemented501, ok200, unauthorized401, conflict409, imATeapot418)
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Aeson (FromJSON, ToJSON, encode)
import GHC.Generics (Generic)
import Network.HTTP (postRequestWithBody, rspBody, rspCode, simpleHTTP)
import Network.HTTP.Base (ResponseCode)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, modifyTVar')
import GHC.Conc (atomically)
import Data.List.Split (splitOn)

data Node = Node {
  nodeId :: Int,
  addr :: String,
  proposer :: Maybe Proposer,
  acceptor :: Maybe Acceptor,
  learner :: Maybe Learner
  }
  deriving (Show)

data Proposal = Proposal {
  proposalId :: Int,
  proposalValue :: Maybe String
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data Proposer = Proposer { proposerId :: Int }
  deriving (Show)

data Acceptor = Acceptor {
  lastProposalId :: Int,
  acceptedProposal :: Maybe Proposal
  }
  deriving (Show, Eq)

data Learner = Learner {
  commitedProposal :: Maybe Proposal
  }
  deriving (Show, Eq)

initialProposer :: Proposer
initialProposer = Proposer {
  proposerId = 0 -- TODO: implement monotonic counter
  }

initialAcceptor :: Acceptor
initialAcceptor = Acceptor {
  lastProposalId = 0,
  acceptedProposal = Nothing
  }

initialLearner :: Learner
initialLearner = Learner {
  commitedProposal = Nothing
  }

initialnodes :: [Node]
initialnodes = [
  Node {
    nodeId = 1,
    addr = "http://0.0.0.0:4000",
    proposer = Just initialProposer,
    acceptor = Nothing,
    learner = Nothing
    },
  Node {
    nodeId = 2,
    addr = "http://0.0.0.0:4001",
    proposer = Nothing,
    acceptor = Just initialAcceptor,
    learner = Nothing
    },
  Node {
    nodeId = 3,
    addr = "http://0.0.0.0:4002",
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor,
    learner = Nothing
    },
  Node {
    nodeId = 4,
    addr = "http://0.0.0.0:4003",
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor,
    learner = Nothing
    },
  Node {
    nodeId = 5,
    addr = "http://0.0.0.0:4004",
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor,
    learner = Just initialLearner
    }
  ]

getNodes :: Int -> (Maybe Node, [Node])
getNodes selfId = (
  find (
    \(Node { nodeId = nodeId' }) -> selfId == nodeId'
    ) initialnodes,
  filter (
    \(Node { nodeId = nodeId' }) -> selfId /= nodeId'
    ) initialnodes
  )

getPort :: Node -> Int
getPort (Node { addr = addr' }) = read $ (splitOn ":" addr') !! 2

updateAcceptorLastId :: Int -> Node -> Node
updateAcceptorLastId newId node'@(Node { acceptor=(Just acceptor') }) =
  node' {
    acceptor = Just $ acceptor' {
      lastProposalId = newId
      }
    }
updateAcceptorLastId _ n = n

updateAcceptorProposal :: Proposal -> Node -> Node
updateAcceptorProposal newProposal node'@(Node { acceptor=(Just acceptor') }) =
  node' {
    acceptor = Just $ acceptor' {
      acceptedProposal = Just newProposal
      }
    }
updateAcceptorProposal _ n = n

updateLearnerProposal :: Proposal -> Node -> Node
updateLearnerProposal newProposal node'@(Node { learner=(Just learner') }) =
  node' {
    learner = Just $ learner' {
      commitedProposal = Just newProposal
      }
    }
updateLearnerProposal _ n = n

createProposal :: Maybe String -> IO Proposal
createProposal value = do
  timestamp <- (round . (* 1000)) <$> getPOSIXTime
  pure $ Proposal { proposalId = timestamp, proposalValue = value }

setupPaxos :: Int -> IO (Either String (Node, [Node]))
setupPaxos selfId = do
  case getNodes selfId of
    (Nothing, _) -> pure $ Left "Invalid id"
    (Just self, nodes) -> pure $ Right (self, nodes)

sendPrepare :: Proposal -> Node -> IO (Either String ResponseCode)
sendPrepare proposal node@(Node { addr = addr' }) = do
  print $ "preparing: " <> show proposal
  print $ "to: " <> show node
  print $ addr' <> "/acceptor/prepare"
  response <- simpleHTTP $ postRequestWithBody (addr' <> "/acceptor/prepare") "application/json" $ BLU.toString $ encode proposal
  case response of
    Right res -> pure $ Right $ rspCode res
    Left err -> do
      print err
      pure $ Left $ show err

sendCommit :: Proposal -> Node -> IO (Either String ResponseCode)
sendCommit proposal node@(Node { addr = addr' }) = do
  print $ "commiting: " <> show proposal
  print $ "to: " <> show node
  response <- simpleHTTP $ postRequestWithBody (addr' <> "/acceptor/commit") "application/json" $ BLU.toString $ encode proposal
  case response of
    Right res -> pure $ Right $ rspCode res
    Left err -> do
      print err
      pure $ Left $ show err

sendLearner :: Proposal -> Node -> IO (Either String ResponseCode)
sendLearner proposal node@(Node { addr = addr' }) = do
  response <- simpleHTTP $ postRequestWithBody (addr' <> "/learner") "application/json" $ BLU.toString $ encode proposal
  case response of
    Right res -> pure $ Right $ rspCode res
    Left err -> do
      print err
      pure $ Left $ show err

postProposal :: TVar Node -> [Node] -> ActionM ()
postProposal stateTM acceptors = do
  value :: Maybe String <- jsonData
  proposal <- liftIO $ createProposal value
  self <- liftIO . atomically $ readTVar stateTM
  case self of
    Node { proposer=(Just proposer') } -> do
      liftIO . print $ "proposer: " <> show proposer'
      responses <- liftIO $ sequence $ map (sendPrepare proposal) acceptors
      liftIO . print $ "responses: " <> show responses
      let majority = 1 + ((length acceptors) `div` 2)
      let successes = length $ filter (== Right (2, 0, 0)) responses
      if majority > successes
        then do
          status conflict409 
          text "Error while preparing"
        else do
          responses' <- liftIO $ sequence $ map (sendCommit proposal) acceptors
          let successes' = length $ filter (== Right (2, 0, 0)) responses'
          if majority > successes'
            then do
              status conflict409
              text "Error while commiting"
            else status ok200
    _ -> status unauthorized401

postPrepare :: TVar Node -> ActionM ()
postPrepare stateTM = do
  proposal :: Proposal <- jsonData
  liftIO . print $ "prepare received: " <> show proposal
  self' <- liftIO . atomically $ readTVar stateTM
  liftIO . print $ "prepare state: " <> show self'
  case self' of
    Node { acceptor=(Just acceptor') } -> do
      if lastProposalId acceptor' >= proposalId proposal
        then do
          status conflict409
          text "Error while being prepared"
        else do
          liftIO . atomically $ modifyTVar' stateTM $ updateAcceptorLastId $ proposalId proposal
          self <- liftIO . atomically $ readTVar stateTM
          liftIO $ print $ "prepare state: " <> show self
          -- TODO: drop timestamp and use a distributed monotonic counter
          -- text $ T.pack $ show $ lastProposalId acceptor'
          status ok200
    _ -> status unauthorized401

postCommit :: TVar Node -> [Node] -> ActionM ()
postCommit stateTM learners = do
  proposal :: Proposal <- jsonData
  liftIO $ print $ "commit received: " <> show proposal
  self' <- liftIO . atomically $ readTVar stateTM
  liftIO $ print $ "commit state: " <> show self'
  case self' of
    Node { acceptor=(Just acceptor') } -> do
      if lastProposalId acceptor' /= proposalId proposal
        then do
          status conflict409
          text "Error while being commited"
        else do
          liftIO $ sequence $ map (sendLearner proposal) learners
          liftIO . atomically $ modifyTVar' stateTM $ updateAcceptorProposal proposal
          self <- liftIO . atomically $ readTVar stateTM
          liftIO $ print $ "commit state: " <> show self
          status ok200
    _ -> status unauthorized401

getProposal :: TVar Node -> ActionM ()
getProposal stateTM = do
  self' <- liftIO . atomically $ readTVar stateTM
  case self' of
    Node { acceptor=(Just acceptor') } -> do
      text $ T.pack $ show $ acceptedProposal acceptor'
    _ -> status unauthorized401

postLearner :: TVar Node -> ActionM ()
postLearner stateTM = do
  proposal :: Proposal <- jsonData
  liftIO $ print $ "learn received: " <> show proposal
  self' <- liftIO . atomically $ readTVar stateTM
  liftIO $ print $ "learn state: " <> show self'
  case self' of
    Node { learner=(Just learner') } -> do
      liftIO . atomically $ modifyTVar' stateTM $ updateLearnerProposal proposal
      status ok200
    _ -> status unauthorized401

getLearner :: TVar Node -> ActionM ()
getLearner stateTM = do
  self' <- liftIO . atomically $ readTVar stateTM
  case self' of
    Node { learner=(Just learner') } -> do
      text $ T.pack $ show $ commitedProposal learner'
    _ -> status unauthorized401

app :: Int -> IO ()
app selfId = do
  paxos <- setupPaxos selfId
  case paxos of
    Right (self, nodes) -> do
      let acceptors = filter (\(Node { acceptor=acceptor' }) -> Nothing /= acceptor') nodes
      let learners = filter (\(Node { learner=learner' }) -> Nothing /= learner') nodes
      state :: TVar Node <- newTVarIO self
      scotty (getPort self) $ do
        post "/proposer" $ postProposal state acceptors
        post "/acceptor/prepare" $ postPrepare state
        post "/acceptor/commit" $ postCommit state learners
        get "/acceptor/debug" $ getProposal state
        post "/learner" $ postLearner state
        get "/learner" $ getLearner state
        post "/" $ do
          status imATeapot418
          text "Hello World"
    Left err -> print err
