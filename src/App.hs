module App
  ( app
  ) where

import qualified Data.Text.Lazy as T
import qualified Data.ByteString.Lazy.UTF8 as BLU

import Web.Scotty (ActionM, jsonData, get, post, html, text, status, pathParam, scotty, liftIO)
import Network.HTTP.Types.Status (notImplemented501, ok200, unauthorized401, conflict409)
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Aeson (FromJSON, ToJSON, encode)
import GHC.Generics (Generic)
import Network.HTTP (postRequestWithBody, rspBody, rspCode, simpleHTTP)
import Network.HTTP.Base (ResponseCode)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, modifyTVar')
import GHC.Conc (atomically)

data Node = Node {
  nodeId :: Int,
  port :: Int,
  proposer :: Maybe Proposer,
  acceptor :: Maybe Acceptor
  }
  deriving (Show)

data Proposal = Proposal {
  proposalId :: Int,
  proposalValue :: Maybe String
  }
  deriving (Show, Generic, FromJSON, ToJSON)

data Proposer = Proposer { proposerId :: Int }
  deriving (Show)

data Acceptor = Acceptor {
  lastProposalId :: Int,
  acceptedProposal :: Maybe Proposal
  }
  deriving (Show)

data Learner = Learner {
  commitedProposal :: Maybe Proposal
  }
  deriving (Show)

initialProposer :: Proposer
initialProposer = Proposer {
  proposerId = 0 -- TODO: implement monotonic accumulator
  }

initialAcceptor :: Acceptor
initialAcceptor = Acceptor {
  lastProposalId = 0,
  acceptedProposal = Nothing
  }

initialnodes :: [Node]
initialnodes = [
  Node {
    nodeId = 1,
    port = 4000,
    proposer = Just initialProposer,
    acceptor = Nothing
    },
  Node {
    nodeId = 2,
    port = 4001,
    proposer = Nothing,
    acceptor = Just initialAcceptor
    },
  Node {
    nodeId = 3,
    port = 4002,
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor
    },
  Node {
    nodeId = 4,
    port = 4003,
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor
    },
  Node {
    nodeId = 5,
    port = 4004,
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor
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

updateAcceptorLastId :: Int -> Node -> Node
updateAcceptorLastId newId node'@(Node { acceptor=(Just acceptor') }) =
  node' {
    acceptor = Just $ acceptor' {
      lastProposalId = newId
      }
    }
updateAcceptorLastId _ n = n

updateAcceptorProposal :: Maybe Proposal -> Node -> Node
updateAcceptorProposal newProposal node'@(Node { acceptor=(Just acceptor') }) =
  node' {
    acceptor = Just $ acceptor' {
      acceptedProposal = newProposal
      }
    }
updateAcceptorProposal _ n = n

createProposal :: Maybe String -> IO Proposal
createProposal value = do
  timestamp <- (round . (* 1000)) <$> getPOSIXTime
  pure $ Proposal { proposalId = timestamp, proposalValue = value }

setupPaxos :: Int -> IO (Either String (Node, [Node]))
setupPaxos selfId = do
  case getNodes selfId of
    (Nothing, _) -> pure $ Left "Invalid id"
    (Just self, nodes) -> pure $ Right (self, nodes)

sendProposal :: Proposal -> Node -> IO (Either String ResponseCode)
sendProposal proposal node@(Node { port = port' }) = do
  print $ "sending: " <> show proposal
  print $ "to: " <> show node
  let req = postRequestWithBody ("http://0.0.0.0:" <> show port' <> "/acceptor/prepare") "application/json" $ BLU.toString $ encode proposal
  response <- simpleHTTP req
  case response of
    Right res -> pure $ Right $ rspCode res
    Left err -> pure $ Left $ show err

postProposal :: TVar Node -> [Node] -> ActionM ()
postProposal stateTM nodes = do
  value :: Maybe String <- jsonData
  proposal <- liftIO $ createProposal value
  self <- liftIO . atomically $ readTVar stateTM
  case self of
    Node { proposer=(Just proposer') } -> do
      liftIO . print $ "proposer: " <> show proposer'
      responses <- liftIO $ sequence $ map (sendProposal proposal) nodes
      liftIO . print $ "responses: " <> show responses
      let majority = 1 + ((length nodes) `div` 2)
      let successes = length $ filter (== Right (2, 0, 0)) responses
      if majority > successes
        then status conflict409 
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
        then status conflict409
        else do
          liftIO . atomically $ modifyTVar' stateTM $ updateAcceptorLastId $ proposalId proposal
          self <- liftIO . atomically $ readTVar stateTM
          _ <- liftIO $ print $ "prepare state: " <> show self
          -- TODO: drop timestamp and use a distributed monotonic accumulator
          -- text $ T.pack $ show $ lastProposalId acceptor'
          status ok200
    _ -> status unauthorized401

postCommit :: TVar Node -> ActionM ()
postCommit stateTM = do
  proposal :: Proposal <- jsonData
  liftIO $ print $ "commit received: " <> show proposal
  self' <- liftIO . atomically $ readTVar stateTM
  liftIO $ print $ "commit state: " <> show self'
  case self' of
    Node { acceptor=(Just acceptor') } -> do
      if lastProposalId acceptor' >= proposalId proposal
        then status conflict409
        else do
          liftIO . atomically $ modifyTVar' stateTM $ updateAcceptorLastId $ proposalId proposal
          self <- liftIO . atomically $ readTVar stateTM
          _ <- liftIO $ print $ "commit state: " <> show self
          -- TODO: drop timestamp and use a distributed monotonic accumulator
          -- text $ T.pack $ show $ lastProposalId acceptor'
          status ok200
    _ -> status unauthorized401

app :: Int -> IO ()
app selfId = do
  paxos <- setupPaxos selfId
  case paxos of
    Right (self, nodes) -> do
      state <- newTVarIO self :: IO (TVar Node)
      scotty (port self) $ do
        post "/proposer" $ postProposal state nodes
        post "/acceptor/prepare" $ postPrepare state
        post "/acceptor/commit" $ postCommit state
        post "/" $ html "<marquee>Hello world</marquee>"
    Left err -> print err
