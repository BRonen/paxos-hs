module App
  ( app
  ) where

import qualified Data.Text.Lazy as T
import qualified Data.ByteString.Lazy.UTF8 as BLU

import Web.Scotty (ActionM, jsonData, get, post, html, pathParam, scotty, liftIO)
import Options.Generic (getRecord)
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Aeson (FromJSON, ToJSON, encode)
import GHC.Generics (Generic)
import Network.HTTP (postRequestWithBody, rspBody, simpleHTTP)
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

initialProposer :: Proposer
initialProposer = Proposer {
  proposerId = 10
  }

initialAcceptor :: Acceptor
initialAcceptor = Acceptor {
  lastProposalId = 0,
  acceptedProposal = Nothing
  }

initialnodes :: [Node]
initialnodes = [
  Node {
    nodeId = 0,
    port = 4000,
    proposer = Just initialProposer,
    acceptor = Nothing
    },
  Node {
    nodeId = 1,
    port = 4001,
    proposer = Nothing,
    acceptor = Just initialAcceptor
    },
  Node {
    nodeId = 2,
    port = 4002,
    proposer = Just initialProposer,
    acceptor = Just initialAcceptor
    }
  ]

getNodeId :: IO Int
getNodeId = getRecord "Paxos-hs" :: IO Int

getNodes :: Int -> (Maybe Node, [Node])
getNodes selfId = (
  find (\(Node { nodeId = nodeId' }) -> selfId == nodeId') initialnodes,
  filter (\(Node { nodeId = nodeId' }) -> selfId /= nodeId') initialnodes
  )

updateAcceptorLastId :: Int -> Node -> Node
updateAcceptorLastId newId node'@(Node { acceptor=(Just acceptor) }) =
  node' {
    acceptor = Just $ acceptor {
      lastProposalId = newId
      }
    }
updateAcceptorLastId _ n = n

{- 
createProposal :: Maybe String -> IO Proposal
createProposal value = do
  timestamp <- (round . (* 1000)) <$> getPOSIXTime
  pure $ Proposal { proposalId = timestamp, proposalValue = value }
 -}

setupPaxos :: IO (Either String (Node, [Node]))
setupPaxos = do
  selfId <- getNodeId
  case getNodes selfId of
    (Nothing, _) -> pure $ Left "Invalid id"
    (Just self, nodes) -> pure $ Right (self, nodes)

{- sendProposal :: Proposal -> [Node] -> IO ()
sendProposal proposal _ = do
  let req = postRequestWithBody "http://0.0.0.0:4000" "application/json" $ BLU.toString $ encode proposal
  res <- simpleHTTP req
  case res of
    Right a -> print $ rspBody a
    Left err -> error $ show err -}

getProposal :: TVar Node -> [Node] -> ActionM ()
getProposal stateTM _ = do
  self <- liftIO . atomically $ readTVar stateTM
  case self of
    Node { proposer=(Just proposer') } -> do
      html $ "<h1>" <> (T.pack $ show $ proposerId proposer') <> "</h1>"
    _ -> html "<h1>not a proposer</h1>"

postPrepare :: TVar Node -> ActionM ()
postPrepare stateTM = do
  proposal :: Proposal <- jsonData
  _ <- liftIO $ print proposal
  self' <- liftIO . atomically $ readTVar stateTM
  _ <- liftIO $ print self'
  case self' of
    Node { acceptor=(Just acceptor') } -> do
      if lastProposalId acceptor' >= proposalId proposal
        then html $ "<h1>already received a higher id</h1>"
        else do
          liftIO . atomically $ modifyTVar' stateTM $ updateAcceptorLastId $ proposalId proposal
          self <- liftIO . atomically $ readTVar stateTM
          _ <- liftIO $ print self
          html $ "<h1>" <> (T.pack $ show $ lastProposalId acceptor') <> "</h1>"
    _ -> html "<h1>not a acceptor</h1>"

app :: IO ()
app = do
  paxos <- setupPaxos
  case paxos of
    Right (self, nodes) -> do
      state <- newTVarIO self :: IO (TVar Node)
      scotty (port self) $ do
        get "/proposer" $ getProposal state nodes
        post "/acceptor/prepare" $ postPrepare state
    Left err -> print err
